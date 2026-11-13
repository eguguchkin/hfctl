#!/usr/bin/env python3
# Назначение: `hfctl watch` — живой дашборд движка: ОДИН коллектор данных
#   (/stats, /metrics, host sysfs /sys, /proc, `podman logs -f`) и два
#   рендерера: TUI (curses, TTY) и plain-стрим строк (не-TTY: пайп/файл).
#   Режим выбирается sys.stdout.isatty(); env-входы (bash передаёт только
#   env, без argv): HFCTL_WATCH_PORT (def 11435), HFCTL_WATCH_INTERVAL
#   (def 2), HFCTL_WATCH_CONTAINER (def hipfire_hipfire_1),
#   HFCTL_WATCH_MODEL (def '-'); любое отсутствие — дефолт, не краш.
#
# Побочные эффекты: каждый тик — GET /stats + /metrics (по 3 с таймаут) и
#   чтение /sys, /proc (каждый тик независимо от доступности сервера);
#   TUI-режим — фоновый daemon-поток `podman logs -t --tail 200 -f`
#   (deque 500 строк; поток НИКОГДА не дёргает curses и HTTP); TUI рисует
#   в alt-экране, выход снимает экран (endwin). Файлов и стека не меняет.
#
# Ограничения/допущения: stdlib, синтаксис 3.8+; один процесс, HTTP/sysfs
#   только в главном потоке. «Сервер недоступен» определяется ТОЛЬКО по
#   /stats: TUI — блок «движок» = «недоступен», железо/память/логи живут;
#   plain — строка «сервер недоступен» раз в 30 с (первая сразу), полный
#   срез не печатается (стрим-режим завязан на /stats). Живые скорости —
#   Δсчётчики / Δt реального времени между УСПЕШНЫМИ чтениями /metrics;
#   отрицательный Δ (счётчики сброшены) → '-' на тике, база обновляется.
#   Sparkline — deque на скорость, maxlen = 60//interval (≥1), при смене
#   интервала maxlen пересчитывается, история НЕ пересоздаётся (deque
#   усекает с левого края). Глифы/рамки — Unicode при UTF-8-окружении,
#   ASCII-фолбэк при не-UTF-8 или TERM пустом/dumb; initscr-краш
#   (TERM неизвестен) → фолбэк в plain-режим, не краш. Ключи TUI: q/Q —
#   выход, +/- и =/_ — интервал (клавишами clamp 1..10; стартовое из bash
#   >10 уважается), p — пауза логов (вид заморожен, буферизация живёт).
#   Скрытый --selfcheck — assert-самопроверка без сервера и TTY (exit 0/1).
#
# @returns integer  # 0 — обычный выход (q / Ctrl-C / SIGTERM); 1 — selfcheck упал
import curses
import json
import locale
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from collections import deque
from glob import glob

PORT = 11435  # переопределяется env в Watch.__init__

GLYPHS_UTF = '▁▂▃▄▅▆▇█'
GLYPHS_ASCII = '. -:*#%@'

C_RED, C_YELLOW, C_GREEN = 1, 2, 3

METRICS_FIXTURE = (
    '# HELP hipfire_requests_total Total requests handled.\n'
    '# TYPE hipfire_requests_total counter\n'
    'hipfire_requests_total{method="post"} 42\n'
    'hipfire_prompt_tokens_total 1234\n'
    'hipfire_kv_pages_free 100\n'
    'hipfire_prefill_tokens_per_second_sum 1200\n'
    'hipfire_prefill_tokens_per_second_count 14\n'
    'hipfire_spec_tau_bucket{le="10"} 3\n'
    'hipfire_spec_tau_bucket{le="+Inf"} 7\n'
)


def env_int(name, default):
    # @param 1: string    # имя env-переменной
    # @param 2: integer   # дефолт при отсутствии/не-числе
    # @returns integer    # целое; кривое значение → дефолт (не краш)
    try:
        return int(os.environ.get(name, '') or default)
    except ValueError:
        return default


def choose_utf8(encoding=None, term=None):
    # @param 1: string # предпочит. кодировка (None → locale.getpreferredencoding)
    # @param 2: string # TERM (None → env); «TERM без UTF-8» (пустой/'dumb'/'posix')
    #   → ASCII-глифы
    # @returns bool     # True — Unicode-глифы и рамки
    if encoding is None:
        encoding = locale.getpreferredencoding(False) or ''
    if 'UTF-8' not in encoding.upper().replace('_', '-'):
        return False
    if term is None:
        term = os.environ.get('TERM', '')
    return (term or '').strip() not in ('', 'dumb', 'posix')


class Glyphs:
    # @type bool utf8  # Unicode-набор или ASCII-фолбэк
    def __init__(self, utf8):
        self.utf8 = utf8
        self.spark = GLYPHS_UTF if utf8 else GLYPHS_ASCII
        self.tl = '┌' if utf8 else '+'
        self.tr = '┐' if utf8 else '+'
        self.bl = '└' if utf8 else '+'
        self.br = '┘' if utf8 else '+'
        self.h = '─' if utf8 else '-'
        self.v = '│' if utf8 else '|'
        self.bar_full = '█' if utf8 else '#'
        self.bar_empty = '░' if utf8 else '.'
        self.dot = '●' if utf8 else 'o'
        self.deg = '°C' if utf8 else 'C'
        self.tau = 'τ' if utf8 else 'tau'


def _read(path):
    # @param 1: string  # путь файла
    # @returns string   # содержимое (strip); нет файла → None
    try:
        with open(path, 'r') as f:
            return f.read().strip()
    except OSError:
        return None


def _num(s):
    # @param 1: string  # строка числа ('' → None)
    # @returns float    # float; нечисло/None → None
    if s is None:
        return None
    try:
        return float(s)
    except ValueError:
        return None


def http_get(url, timeout=3.0):
    # @param 1: string  # URL
    # @returns string   # тело ответа; любой сбой — исключение (зовущий ловит)
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read().decode('utf-8', 'replace')


def parse_metrics(text):
    # @param 1: string  # тело /metrics (Prometheus-текст)
    # @returns dict     # name → float; строки '# …' и *_bucket{…} отброшены,
    #   labels {…} со сняты с имени (гистограммы _sum/_count остаются под
    #   своими именами)
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        name = parts[0]
        if '{' in name:
            name = name.split('{', 1)[0]
        if name.endswith('_bucket'):
            continue
        try:
            out[name] = float(parts[1])
        except ValueError:
            continue
    return out


GPU_SPEC = (
    # (поле, файл в hwmon*, делитель) — масштабы сверены вживу (che-FAEX1):
    # freq1_input = Гц (600000000 = 600 MHz); power1_input = мкВт (µW,
    # 5453000 = 5.5 W); vram/gtt — байты. gpu_busy_percent НЕ в hwmon-каталоге,
    # а в card*/device/ — читается отдельно (read_gpu).
    ('sclk_mhz', 'freq1_input', 1e6),
    ('power_w', 'power1_input', 1e6),
    ('vram_used', 'mem_info_vram_used', 1.0),
    ('gtt_used', 'mem_info_gtt_used', 1.0))


def read_gpu(base='/sys/class/drm'):
    # @param 1: string  # каталог с card* (def /sys/class/drm; --selfcheck —
    #   фейковое дерево)
    # @returns dict     # первая AMD-карта (vendor 0x1002): temp_c — max
    #   temp1_input/1000 (миллиградусы) по всем её hwmon; sclk_mhz —
    #   freq1_input/1e6 (Гц→MHz); power_w — power1_input/1e6 (мкВт→W);
    #   busy_pct — card*/device/gpu_busy_percent (НЕ в hwmon-каталоге);
    #   vram_used/gtt_used — байты; каждое отсутствующее поле — None
    #   (dict целиком None — карты/датчиков нет)
    for card in sorted(glob(base + '/card[0-9]*')):
        if _read(card + '/device/vendor') != '0x1002':
            continue
        gpu = {'temp_c': None, 'sclk_mhz': None, 'power_w': None,
               'busy_pct': None, 'vram_used': None, 'gtt_used': None}
        busy = _num(_read(card + '/device/gpu_busy_percent'))
        if busy is not None:
            gpu['busy_pct'] = busy
        temps = []
        for hw in sorted(glob(card + '/device/hwmon/hwmon*/')):
            t = _num(_read(hw + 'temp1_input'))
            if t is not None:
                temps.append(t)
            for key, fname, scale in GPU_SPEC:
                if gpu[key] is None:
                    v = _num(_read(hw + fname))
                    if v is not None:
                        gpu[key] = v / scale
        if temps:
            gpu['temp_c'] = max(temps) / 1000.0
        return gpu
    return None


def read_cpu_temp(base='/sys/class/hwmon'):
    # @param 1: string  # каталог с hwmon* (def /sys/class/hwmon)
    # @returns float|None  # Tctl °C — temp1_input/1000 (миллиградусы,
    #   1 знак) первого датчика k10temp; нет датчика/чтения → None
    for hw in sorted(glob(base + '/hwmon*')):
        if _read(hw + '/name') == 'k10temp':
            v = _num(_read(hw + '/temp1_input'))
            return round(v / 1000.0, 1) if v is not None else None
    return None


def read_mem():
    # @returns dict     # /proc/meminfo в GiB (1 знак): available_gib,
    #   total_gib, swap_used_gib, swap_total_gib; нет поля → None
    kib = {}
    try:
        with open('/proc/meminfo', 'r') as f:
            for line in f:
                key, _, rest = line.partition(':')
                parts = rest.split()
                if parts:
                    try:
                        kib[key.strip()] = int(parts[0])
                    except ValueError:
                        pass
    except OSError:
        pass
    gib = 1048576.0

    def g(key):
        v = kib.get(key)
        return None if v is None else round(v / gib, 1)

    st, sf = kib.get('SwapTotal'), kib.get('SwapFree')
    used = None
    if st is not None and sf is not None:
        used = round((st - sf) / gib, 1)
    return {'available_gib': g('MemAvailable'), 'total_gib': g('MemTotal'),
            'swap_used_gib': used, 'swap_total_gib': g('SwapTotal')}


class Deltas:
    """Живые скорости: Δсчётчики/Δt (реальное время между успешными
    чтениями /metrics); отрицательный Δ (сброс счётчиков) → None, база
    всё равно обновляется. reset() — после простоя сервера, чтобы после
    поднятия не было ложных дельт (перенос поведения bash-версии)."""

    # @type dict|None  prev_metrics   # метрики предыдущего успешного чтения
    # @type float|None  prev_time      # time.monotonic того же чтения
    # @type float|None  prev_served    # requests_served предыдущего тика
    def __init__(self):
        self.prev_metrics = None
        self.prev_time = None
        self.prev_served = None

    def reset(self):
        self.prev_metrics = None
        self.prev_time = None
        self.prev_served = None

    def update(self, snap):
        # @param 1: dict  # snap
        # @returns dict   # prefill/decode tok/s (None = '-'), served_delta ≥ 0
        out = {'prefill': None, 'decode': None, 'served_delta': 0}
        m = snap['metrics']
        if m is not None:
            now = time.monotonic()
            if self.prev_metrics is not None and self.prev_time is not None:
                dt = now - self.prev_time
                if dt > 0:
                    for key, counter in (('prefill', 'hipfire_prompt_tokens_total'),
                                         ('decode', 'hipfire_completion_tokens_total')):
                        cur = m.get(counter)
                        prev = self.prev_metrics.get(counter)
                        if cur is not None and prev is not None:
                            d = (cur - prev) / dt
                            out[key] = d if d >= 0 else None
            self.prev_metrics = m
            self.prev_time = now
        st = snap['stats']
        served = st.get('requests_served') if st else None
        if served is not None:
            if self.prev_served is not None and served > self.prev_served:
                out['served_delta'] = int(served - self.prev_served)
            self.prev_served = served
        return out


class LogStreamer(threading.Thread):
    """Фоновый стример `podman logs -t --tail 200 -f <container>`:
    stdout построчно → deque(500) (append thread-safe, lock не нужен).
    Поток НЕ дёргает curses и HTTP. podman/контейнер нет → err-строка,
    повторные попытки раз в ~1 с — повторное появление контейнера видно
    само. stop() завершает подпроцесс (daemon-поток, fd не дёргает)."""

    # @type string err      # '' | 'логи недоступно: …'
    # @type deque  buf      # последние 500 строк логов
    def __init__(self, container):
        super().__init__(daemon=True)
        self.container = container
        self.buf = deque(maxlen=500)
        self.err = ''
        self._proc = None
        self._stopped = False
        self._last_try = 0.0

    def _spawn_once(self):
        now = time.monotonic()
        if now - self._last_try < 1.0:
            return
        self._last_try = now
        try:
            proc = subprocess.Popen(
                ['podman', 'logs', '-t', '--tail', '200', '-f', self.container],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                text=True, errors='replace')
        except (FileNotFoundError, OSError):
            self.err = 'логи недоступны: podman не найден'
            return
        self.err = ''
        self._proc = proc
        for line in proc.stdout:
            self.buf.append(line.rstrip('\n'))
        self._proc = None
        rc = proc.returncode
        self.err = '' if rc == 0 else 'логи недоступны: podman rc=%s' % rc

    def stop(self):
        self._stopped = True
        self._kill_proc()

    def _kill_proc(self):
        p = self._proc
        if p is not None and p.poll() is None:
            try:
                p.terminate()
            except OSError:
                pass

    def run(self):
        try:
            while not self._stopped:
                self._spawn_once()
                if not self._stopped:
                    time.sleep(1)
        finally:
            self._kill_proc()


def sparkline(values, glyphs, width):
    # @param 1: list      # история значений (None — пропуск, тик не добавляется)
    # @param 2: string    # 8 глиф-ступеней (последняя — max)
    # @param 3: integer   # ширина в знаках (последние width значений)
    # @returns string     # autoscale к максимуму ряда (≥1); пустой ряд → ''
    vals = [v for v in values if v is not None]
    if not vals or width < 1:
        return ''
    mx = max(vals)
    if mx < 1:
        mx = 1.0
    tail = vals[-width:]
    return ''.join(glyphs[min(7, int(v / mx * 7.999))] for v in tail)


def fmt1(x):
    # @returns string  # 1 знак; None → '-'
    return '-' if x is None else '%.1f' % x


def fmti(x, q='?'):
    # @returns string  # целое; None → q (заглушка датчика/метрики)
    return q if x is None else str(int(x))


def fmt_c(x):
    # @returns string  # °C, 1 знак (Tctl: 35875 мК → 35.9C); None → '?'
    return '?' if x is None else '%.1f' % x


def fmt_uptime(s):
    # @param 1: float  # секунд аптайма
    # @returns string  # d/h/m (None → '-')
    if s is None:
        return '-'
    s = int(s)
    d, rem = divmod(s, 86400)
    h, rem = divmod(rem, 3600)
    m, sec = divmod(rem, 60)
    if d:
        return '%dd %dh %dm' % (d, h, m)
    if h:
        return '%dh %dm' % (h, m)
    return '%dm %ds' % (m, sec)


def avg_of(m, name):
    # @returns float  # sum/count гистограммы; нет данных/0 запросов → None
    if not m:
        return None
    s = m.get(name + '_sum')
    c = m.get(name + '_count')
    if s is None or c is None or c <= 0:
        return None
    return s / c


def fmt_plain(snap, d, ts):
    # @param 1: dict     # snap
    # @param 2: dict     # deltas {prefill, decode, served_delta}
    # @param 3: string   # метка времени HH:MM:SS
    # @returns string    # полный срез; порядок фиксирован (D2); без
    #   metrics → prefill/decode/кэш '-'; без датчика → '?'
    st = snap['stats'] or {}
    m = snap['metrics'] or {}
    parts = ['queue: %s' % fmti(st.get('queue_depth'), '-')]
    sv = fmti(st.get('requests_served'), '-')
    if d['served_delta'] > 0:
        sv += ' (+%d)' % d['served_delta']
    parts.append('served: %s' % sv)
    parts.append('cache: %s' % fmti(m.get('hipfire_cached_prompt_tokens_total'), '-'))
    fails = m.get('hipfire_requests_failed_total')
    if fails is not None and fails > 0:
        parts.append('errors: %d' % int(fails))
    retr = st.get('retries_attempted')
    if retr is not None and retr != 0:
        parts.append('retries: %d' % int(retr))
    parts.append('prefill: %s tok/s' % fmt1(d['prefill']))
    parts.append('decode: %s tok/s' % fmt1(d['decode']))
    mem = snap['mem']
    parts.append('mem: %s/%s GiB' % (fmt1(mem.get('available_gib')),
                                     fmt1(mem.get('total_gib'))))
    parts.append('swap: %s/%s GiB' % (fmt1(mem.get('swap_used_gib')),
                                      fmt1(mem.get('swap_total_gib'))))
    gp = snap['gpu'] or {}
    parts.append('gpu: %sC %sMHz %sW %s%%' % (
        fmti(gp.get('temp_c')), fmti(gp.get('sclk_mhz')),
        fmti(gp.get('power_w')), fmti(gp.get('busy_pct'))))
    parts.append('cpu: %sC' % fmt_c(snap['cpu_temp_c']))
    return ts + '  ' + ' │ '.join(parts)


PLAIN_SNAP = {
    'engine_ok': True,
    'stats': {'queue_depth': 0, 'requests_served': 123, 'retries_attempted': 1},
    'metrics': {'hipfire_cached_prompt_tokens_total': 4421.0,
                'hipfire_requests_failed_total': 2.0},
    'gpu': {'temp_c': 62.0, 'sclk_mhz': 1500.0, 'power_w': 18.0,
            'busy_pct': 87.0, 'vram_used': None, 'gtt_used': None},
    'cpu_temp_c': 54.0,
    'mem': {'available_gib': 45.2, 'total_gib': 60.4,
            'swap_used_gib': 0.2, 'swap_total_gib': 8.0},
}
PLAIN_D = {'prefill': 84.2, 'decode': 75.3, 'served_delta': 1}
PLAIN_FULL = ('12:00:00  queue: 0 │ served: 123 (+1) │ cache: 4421 │ '
              'errors: 2 │ retries: 1 │ prefill: 84.2 tok/s │ '
              'decode: 75.3 tok/s │ mem: 45.2/60.4 GiB │ swap: 0.2/8.0 GiB │ '
              'gpu: 62C 1500MHz 18W 87% │ cpu: 54.0C')
PLAIN_SNAP_MIN = {
    'engine_ok': True,
    'stats': {'queue_depth': 0, 'requests_served': 5, 'retries_attempted': None},
    'metrics': None,
    'gpu': None,
    'cpu_temp_c': None,
    'mem': {'available_gib': 12.0, 'total_gib': 60.0,
            'swap_used_gib': 0.0, 'swap_total_gib': 8.0},
}
PLAIN_D_MIN = {'prefill': None, 'decode': None, 'served_delta': 0}
PLAIN_MIN = ('12:00:00  queue: 0 │ served: 5 │ cache: - │ prefill: - tok/s │ '
             'decode: - tok/s │ mem: 12.0/60.0 GiB │ swap: 0.0/8.0 GiB │ '
             'gpu: ?C ?MHz ?W ?% │ cpu: ?C')


def status_bar_layout(W, interval, model, paused):
    # @param 1: integer  # ширина терминала в знаках
    # @returns (left, mid, right, x_mid, x_right)  # x_left фиксирован = 1
    #   (за «●»); модель усечена так, чтобы между ней и mid был гарантированный
    #   разрыв в 1 колонку (контракт: на 80 колонок ни наложений, ни касания);
    #   при узком W mid сдвигается влево от права (деградация, put() всё равно
    #   обрезает)
    prefix = 'hfctl watch │ модель '
    mid = 'интервал %d c' % interval
    right = 'логи: %s (p) │ q — выход' % ('пауза' if paused else 'live')
    right_x = max(0, W - len(right) - 1)
    mid_x = max(0, min(W // 2 - len(mid) // 2, right_x - len(mid) - 1))
    model_w = mid_x - len(prefix) - 2
    model = model[:model_w] if model_w > 0 else ''
    return prefix + model, mid, right, mid_x, right_x


def selfcheck():
    # @returns integer  # 0 — всё прошло; 1 — есть провалы (имена в stderr)
    fails = []
    total = 0

    def ck(name, cond):
        nonlocal total
        total += 1
        if not cond:
            fails.append(name)

    m = parse_metrics(METRICS_FIXTURE)
    ck('metrics counter', m.get('hipfire_prompt_tokens_total') == 1234.0)
    ck('metrics gauge', m.get('hipfire_kv_pages_free') == 100.0)
    ck('metrics labels stripped', m.get('hipfire_requests_total') == 42.0)
    ck('metrics _sum/_count kept',
       m.get('hipfire_prefill_tokens_per_second_sum') == 1200.0
       and m.get('hipfire_prefill_tokens_per_second_count') == 14.0)
    ck('metrics _bucket excluded', 'hipfire_spec_tau_bucket' not in m)
    ck('metrics # lines excluded', len(m) == 5)

    ck('plain full slice', fmt_plain(PLAIN_SNAP, PLAIN_D, '12:00:00') == PLAIN_FULL)
    ck('plain -/? substitutions',
       fmt_plain(PLAIN_SNAP_MIN, PLAIN_D_MIN, '12:00:00') == PLAIN_MIN)

    hist = [0.0, 2.5, 5.0, 10.0, 10.0, 2.5]
    ck('sparkline UTF-8', sparkline(hist, GLYPHS_UTF, 8) == '▁▂▄██▂')
    ck('sparkline ASCII', sparkline(hist, GLYPHS_ASCII, 8) == '. :@@ ')
    ck('sparkline empty', sparkline([], GLYPHS_UTF, 8) == '')

    ck('glyphs utf8', choose_utf8('UTF-8') is True)
    ck('glyphs ascii encoding', choose_utf8('ANSI_X3.4-1968') is False)
    ck('glyphs term dumb', choose_utf8('UTF-8', term='dumb') is False)
    ck('glyphs term empty', choose_utf8('UTF-8', term='') is False)

    # Масштабы датчиков (сверено вживу на che-FAEX1) — фейковые деревья /sys
    fake_hw = tempfile.mkdtemp(prefix='watch_tui_hw_')
    fake_drm = tempfile.mkdtemp(prefix='watch_tui_drm_')
    try:
        def w(path, s):
            with open(path, 'w') as f:
                f.write(s + '\n')
        hw0 = fake_hw + '/hwmon0'
        os.makedirs(hw0)
        w(hw0 + '/name', 'coretemp')  # не k10temp — поиск должен пройти мимо
        hw3 = fake_hw + '/hwmon3'
        os.makedirs(hw3)
        w(hw3 + '/name', 'k10temp')
        w(hw3 + '/temp1_input', '35875')  # миллиградусы → 35.9 °C
        ck('cpu Tctl 35875→35.9', read_cpu_temp(fake_hw) == 35.9)
        ck('cpu fmt 35.9/?', fmt_c(35.9) == '35.9' and fmt_c(None) == '?')

        card = fake_drm + '/card0'
        os.makedirs(card + '/device/hwmon/hwmon0')
        w(card + '/device/vendor', '0x1002')
        w(card + '/device/gpu_busy_percent', '0')  # НЕ в hwmon-каталоге
        hw = card + '/device/hwmon/hwmon0'
        w(hw + '/temp1_input', '54375')
        w(hw + '/freq1_input', '600000000')  # Гц → 600 MHz
        w(hw + '/power1_input', '5453000')   # мкВт → 5.453 W
        gpu = read_gpu(fake_drm)
        ck('gpu busy path card/device', gpu is not None and gpu['busy_pct'] == 0.0)
        ck('gpu sclk 600000000→600', gpu is not None and gpu['sclk_mhz'] == 600.0)
        ck('gpu power 5453000→5.453', gpu is not None and gpu['power_w'] == 5.453)
        ck('gpu temp mK→C 54.375', gpu is not None and gpu['temp_c'] == 54.375)
        card1 = fake_drm + '/card1'
        os.makedirs(card1 + '/device/hwmon/hwmon1')
        w(card1 + '/device/vendor', '0x8086')  # не AMD — карта не читается
        w(card1 + '/device/hwmon/hwmon1/temp1_input', '99999')
        ck('gpu non-AMD skip', read_gpu(fake_drm)['temp_c'] == 54.375)
    finally:
        shutil.rmtree(fake_hw)
        shutil.rmtree(fake_drm)

    left, mid, right, mid_x, right_x = status_bar_layout(
        80, 2, 'qwen3.8:flash-next-mq4-xts', False)
    # строгий '<': равенство 1+len(left)==mid_x — касание (хвост модели
    # прижат к «интервал»), на 80 кол у prod-моделей это был live-дефект
    ck('status bar 80 cols gap≥1',
       1 + len(left) < mid_x
       and mid_x + len(mid) <= right_x
       and right_x + len(right) <= 80)

    for name in fails:
        print('selfcheck FAIL: %s' % name, file=sys.stderr)
    print('selfcheck: %d/%d ok' % (total - len(fails), total))
    return 1 if fails else 0


def put(win, y, x, s, attr=0):
    # @param 1..4: window/integer/integer/string  # строка в точку окна
    # Побочные эффекты: addstr в win; обрезка по правому краю окна, точка
    #   за пределами — молча пропуск (никогда исключение — деградация
    #   узкого/низкого терминала без трейса)
    h, w = win.getmaxyx()
    if y < 0 or y >= h or x >= w or not s:
        return
    if x < 0:
        s = s[-x:]
        x = 0
    if x + len(s) > w:
        s = s[:w - x]
    if not s:
        return
    try:
        win.addstr(y, x, s, attr)
    except (curses.error, UnicodeEncodeError, ValueError):
        # curses.error — за краем окна; UnicodeEncodeError/ValueError —
        # строка не кодируется в локаль терминала (не-UTF-8): пропускаем,
        # не трейсим (деградация)
        pass


class Watch:
    """Состояние + цикл. TUI и plain используют один коллектор (collect)
    и один Deltas; различаются только рендер и период печати."""

    # @type integer port / interval  # TCP-порт; интервал тиков, с
    # @type string  model / container # модель из .env; имя контейнера
    # @type bool    utf8 / colors    # Unicode-глифы; цвета (has_colors)
    # @type Deltas  state            # база дельт
    # @type LogStreamer streamer     # поток логов (TUI-режим)
    # @type deque   spark_p / spark_d # история live prefill/decode
    # @type list    log_view         # «вид» логов (пауза — заморожен)
    # @type bool    paused / stop    # пауза логов; флаг выхода
    # @type integer|None signum      # сигнал, заставивший выйти (plain: «Выход Ctrl-C»)
    def __init__(self):
        self.port = env_int('HFCTL_WATCH_PORT', 11435)
        self.model = os.environ.get('HFCTL_WATCH_MODEL') or '-'
        self.interval = max(1, env_int('HFCTL_WATCH_INTERVAL', 2))
        self.container = os.environ.get('HFCTL_WATCH_CONTAINER') or 'hipfire_hipfire_1'
        self.utf8 = choose_utf8()
        self.glyphs = Glyphs(self.utf8)
        self.colors = False
        self.state = Deltas()
        self.streamer = LogStreamer(self.container)
        ml = max(1, 60 // self.interval)
        self.spark_p = deque(maxlen=ml)
        self.spark_d = deque(maxlen=ml)
        self.log_view = []
        self.paused = False
        self.stop = False
        self.signum = None

    def collect(self):
        # @returns dict  # snap: engine_ok (только по /stats), stats, metrics,
        #   gpu, cpu_temp_c, mem, kv_free/kv_total, uptime_s — sysfs и /proc
        #   читаются каждый тик независимо от доступности сервера
        snap = {'engine_ok': False, 'stats': None, 'metrics': None,
                'gpu': read_gpu(), 'cpu_temp_c': read_cpu_temp(),
                'mem': read_mem(), 'kv_free': None, 'kv_total': None,
                'uptime_s': None}
        try:
            snap['stats'] = json.loads(http_get('http://127.0.0.1:%d/stats' % self.port))
            snap['engine_ok'] = True
        except Exception:
            pass
        try:
            snap['metrics'] = parse_metrics(http_get('http://127.0.0.1:%d/metrics' % self.port))
        except Exception:
            pass
        m = snap['metrics']
        if m:
            snap['kv_free'] = m.get('hipfire_kv_pages_free')
            snap['kv_total'] = m.get('hipfire_kv_pages_total')
            snap['uptime_s'] = m.get('hipfire_uptime_seconds')
        return snap

    def push_spark(self, d):
        if d['prefill'] is not None:
            self.spark_p.append(d['prefill'])
        if d['decode'] is not None:
            self.spark_d.append(d['decode'])

    def set_interval(self, v):
        # Клавишами clamp 1..10; стартовое из bash >10 уважается (не
        # переписывается до первого нажатия). maxlen у deque неизменяем —
        # история переносится пересозданием (конструктор держит последние
        # ml значений = усекает с левого края, старые теряются), не «на
        # пустом»: ряд переживает смену интервала.
        self.interval = max(1, min(10, v))
        ml = max(1, 60 // self.interval)
        self.spark_p = deque(list(self.spark_p), maxlen=ml)
        self.spark_d = deque(list(self.spark_d), maxlen=ml)

    def attr(self, c):
        # @returns integer  # color_pair при has_colors, иначе 0 (без подсветки)
        if c and self.colors:
            return curses.color_pair(c)
        return 0

    def sleep_quanta_plain(self, secs):
        end = time.monotonic() + secs
        while not self.stop and time.monotonic() < end:
            time.sleep(min(0.1, max(0.0, end - time.monotonic())))

    def run_plain(self):
        # Строка БЕСУСЛОВНО раз в interval (первая сразу, t=0). Сервер
        # недоступен: «сервер недоступен» — первая сразу, дальше раз в 30 с,
        # без дублей; полный срез при недоступности не печатается; база
        # дельт сбрасывается (после поднятия — свежая строка, без ложных дельт).
        last_down = None
        while not self.stop:
            snap = self.collect()
            ts = time.strftime('%H:%M:%S')
            if snap['engine_ok']:
                d = self.state.update(snap)
                print(fmt_plain(snap, d, ts), flush=True)
            else:
                self.state.reset()
                now = time.monotonic()
                if last_down is None or now - last_down >= 30.0:
                    print('%s сервер недоступен (нет /stats на :%d); жду…'
                          % (ts, self.port), flush=True)
                    last_down = now
            self.sleep_quanta_plain(self.interval)

    # ── TUI ─────────────────────────────────────────────────────────────────
    def run_tui(self, win):
        win.nodelay(True)
        win.keypad(True)
        try:
            curses.noecho()
            curses.cbreak()  # non-canonical: клавиши по одной, не строкой
            win.clear()
            curses.curs_set(0)
        except curses.error:
            pass
        if curses.has_colors():
            try:
                curses.start_color()
                curses.use_default_colors()
                curses.init_pair(C_RED, curses.COLOR_RED, -1)
                curses.init_pair(C_YELLOW, curses.COLOR_YELLOW, -1)
                curses.init_pair(C_GREEN, curses.COLOR_GREEN, -1)
                self.colors = True
            except curses.error:
                pass
        self.streamer.start()
        try:
            while not self.stop:
                t0 = time.monotonic()
                cur = self.interval
                self.drain_keys(win)
                if self.stop:
                    break
                snap = self.collect()
                d = self.state.update(snap)
                self.push_spark(d)
                if not self.paused:
                    self.log_view = list(self.streamer.buf)
                H, W = win.getmaxyx()
                self.draw(win, W, H, snap, d)
                win.refresh()
                self.sleep_quanta(win, cur, t0)
        finally:
            self.streamer.stop()
            curses.endwin()

    def handle_key(self, ch):
        # q/Q — выход сразу; +/- (=_/_-): интервал от СЛЕДУЮЩЕГО тика;
        # p — пауза логов (вид обновляется на следующем тике)
        if ch in (ord('q'), ord('Q')):
            self.stop = True
        elif ch in (ord('+'), ord('=')):
            self.set_interval(self.interval + 1)
        elif ch in (ord('-'), ord('_')):
            self.set_interval(self.interval - 1)
        elif ch == ord('p'):
            self.paused = not self.paused

    def drain_keys(self, win):
        while True:
            ch = win.getch()
            if ch == -1:
                return
            self.handle_key(ch)
            if self.stop:
                return

    def sleep_quanta(self, win, secs, t0):
        end = t0 + secs
        while not self.stop and time.monotonic() < end:
            ch = win.getch()
            if ch != -1:
                self.handle_key(ch)
                if self.stop:
                    return
            time.sleep(0.1)

    def draw(self, win, W, H, snap, d):
        win.erase()
        g = self.glyphs
        put(win, 0, 0, g.dot, self.attr(C_GREEN if snap['engine_ok'] else C_RED))
        left, mid, right, mid_x, right_x = status_bar_layout(
            W, self.interval, self.model, self.paused)
        put(win, 0, 1, left)
        put(win, 0, mid_x, mid)
        put(win, 0, right_x, right)
        if H < 4 or W < 8:
            return
        # зона логов: min 6 (H≥24) / min 3 (H<24), (H−1)//4 снизу
        log_h = max(6 if H >= 24 else 3, (H - 1) // 4)
        log_top = H - log_h
        avail = log_top - 1
        if avail >= 8:
            bh, gap = (avail - 1) // 2, 1
        else:
            bh, gap = max(3, avail // 2), 0
        col_w = max(10, W // 2)
        x2 = W - col_w
        if avail >= 3:
            engine_rows = [('недоступен', '')] if not snap['engine_ok'] \
                else self.rows_engine(snap)
            self.block(win, 0, 1, col_w, bh, 'движок', engine_rows)
            self.block(win, x2, 1, col_w, bh, 'железо', self.rows_hardware(snap))
            y2 = 1 + bh + gap
            if y2 + bh - 1 <= log_top - 1:
                self.block(win, 0, y2, col_w, bh, 'скорость', self.rows_speed(snap, d, W))
                self.block(win, x2, y2, col_w, bh, 'память', self.rows_memory(snap, W))
        self.box(win, 0, log_top, W, log_h)
        put(win, log_top + 1, 2, 'логи')
        if self.log_view:
            lines = self.log_view[-max(0, log_h - 3):]
            for i, ln in enumerate(lines):
                yy = log_top + 2 + i
                if yy >= H - 1:
                    break
                put(win, yy, 2, ln)
        elif self.streamer.err:
            put(win, log_top + 2, 2, self.streamer.err)
        else:
            put(win, log_top + 2, 2, '(ждём логи…)')

    def box(self, win, x, y, w, h):
        g = self.glyphs
        if w < 3 or h < 2:
            return
        put(win, y, x, g.tl + g.h * (w - 2) + g.tr)
        put(win, y + h - 1, x, g.bl + g.h * (w - 2) + g.br)
        for i in range(1, h - 1):
            put(win, y + i, x, g.v)
            put(win, y + i, x + w - 1, g.v)

    def block(self, win, x, y, w, h, title, rows):
        # Заголовок внутри вверху; строки (label, value[, attr]) — сверху
        # вниз, не поместившиеся отбрасываются (деградация, не перенос).
        self.box(win, x, y, w, h)
        put(win, y + 1, x + 2, title, curses.A_BOLD)
        for i, row in enumerate(rows):
            yy = y + 2 + i
            if yy >= y + h - 1:
                break
            label, value = row[0], row[1]
            attr = row[2] if len(row) > 2 else 0
            put(win, yy, x + 2, label + ': ', attr)
            put(win, yy, x + 2 + len(label) + 2, value, attr)

    def rows_engine(self, snap):
        g = self.glyphs
        st = snap['stats'] or {}
        m = snap['metrics'] or {}
        rows = [('модель', self.model),
                ('uptime', fmt_uptime(snap['uptime_s'])),
                ('очередь', fmti(st.get('queue_depth'), '-')),
                ('обслужено', fmti(st.get('requests_served'), '-'))]
        fails = m.get('hipfire_requests_failed_total')
        if fails is not None and fails > 0:
            rows.append(('ошибки', str(int(fails)), self.attr(C_RED)))
        retr = st.get('retries_attempted')
        if retr is not None and retr != 0:
            rows.append(('ретраи', str(int(retr)), self.attr(C_RED)))
        rows.append((g.tau + ' avg', fmt1(avg_of(m, 'hipfire_spec_tau'))))
        rows.append(('кэш', fmti(m.get('hipfire_cached_prompt_tokens_total'), '-')))
        return rows

    def rows_hardware(self, snap):
        g = self.glyphs
        gp = snap['gpu'] or {}
        qd = (snap['stats'] or {}).get('queue_depth')
        busy = gp.get('busy_pct')
        busy_attr = 0
        if busy is not None and busy < 5 and qd is not None and qd > 0:
            # подозрение на зависание: подсветка (жёлтый/bold)
            busy_attr = self.attr(C_YELLOW) | curses.A_BOLD
        cpu = snap['cpu_temp_c']
        cpu_attr = self.attr(C_RED) if (cpu is not None and cpu > 80) else 0
        return [('sclk', fmti(gp.get('sclk_mhz')) + ' MHz'),
                ('busy', fmti(gp.get('busy_pct')) + '%', busy_attr),
                ('power', fmti(gp.get('power_w')) + ' W'),
                ('GPU temp', fmti(gp.get('temp_c')) + g.deg),
                ('Tctl', fmt_c(cpu) + g.deg, cpu_attr)]

    def rows_speed(self, snap, d, W):
        m = snap['metrics'] or {}
        width = max(4, W // 2 - 4)
        return [('live prefill', fmt1(d['prefill']) + ' tok/s'),
                ('live decode', fmt1(d['decode']) + ' tok/s'),
                ('avg prefill', fmt1(avg_of(m, 'hipfire_prefill_tokens_per_second'))),
                ('avg decode', fmt1(avg_of(m, 'hipfire_decode_tokens_per_second'))),
                ('spark prefill', sparkline(self.spark_p, self.glyphs.spark, width)),
                ('spark decode', sparkline(self.spark_d, self.glyphs.spark, width))]

    def rows_memory(self, snap, W):
        g = self.glyphs
        mem = snap['mem']
        avail, total = mem.get('available_gib'), mem.get('total_gib')
        width = min(24, max(6, W // 2 - 12))
        mem_attr = self.attr(C_RED) if (avail is not None and avail < 10) else 0
        if avail is None or total is None:
            mem_val = '?'
        else:
            n = max(0, min(width, int(avail / total * width)))
            mem_val = ' %s%s %s/%s GiB' % (g.bar_full * n, g.bar_empty * (width - n),
                                           fmt1(avail), fmt1(total))
        kv = ('%d/%d' % (int(snap['kv_free']), int(snap['kv_total']))
              if snap['kv_free'] is not None and snap['kv_total'] is not None else '-')
        return [('mem', mem_val, mem_attr),
                ('swap', '%s/%s GiB' % (fmt1(mem.get('swap_used_gib')),
                                        fmt1(mem.get('swap_total_gib')))),
                ('KV pages', kv)]


def main(argv):
    if argv and argv[0] == '--selfcheck':
        return selfcheck()
    w = Watch()

    def on_signal(signum, frame):
        w.stop = True
        w.signum = signum

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)
    term = os.environ.get('TERM', '')
    if sys.stdout.isatty() and term:
        try:
            win = curses.initscr()
        except (curses.error, OSError):
            win = None  # TERM неизвестен/кривой → фолбэк в plain, не краш
        if win is not None:
            w.run_tui(win)
            return 0
    w.run_plain()
    if w.signum is not None:
        print('Выход Ctrl-C', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
