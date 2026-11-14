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
#   TUI-режим — сид `podman logs -t --tail 50` (однократно, синхронно в
#   главном потоке ДО первой рамки, таймаут 10 с; D9: стартовые строки
#   видны сразу) + фоновый daemon-поток `podman logs -t --tail 1 -f`
#   (deque 500 строк, общий со сидом; поток НИКОГДА не дёргает curses и
#   HTTP); TUI рисует в alt-экране, выход снимает экран (endwin). Файлов
#   и стека не меняет.
#
# Ограничения/допущения: stdlib, синтаксис 3.8+; один процесс, HTTP/sysfs
#   только в главном потоке. «Сервер недоступен» определяется ТОЛЬКО по
#   /stats: TUI — блок «движок» = «недоступен», железо/память/логи живут;
#   plain — строка «сервер недоступен» раз в 30 с (первая сразу), полный
#   срез не печатается (стрим-режим завязан на /stats). Скорости ЧЕСТНЫЕ
#   (D8): движок обновляет счётчики токенов ТОЛЬКО в done-событии, live-
#   Δ/Δt в процессе НЕ существует — decode tok/s = `recent_tok_s` из
#   /stats (последний завершённый запрос; нет данных → '-'), prefill
#   tok/s = среднее гистограммы `hipfire_prefill_tokens_per_second`
#   (_sum/_count; нет образцов → '-'). Δсчётчики за тик — НЕ скорость,
#   только активность для sparkline (пики на завершении); отрицательный
#   Δ (счётчики сброшены) → тик пропускается, база обновляется.
#   Sparkline — deque на дельты за тик, maxlen = 60//interval (≥1), при
#   смене интервала maxlen пересчитывается, история НЕ пересоздаётся
#   (deque усекает с левого края). Глифы/рамки — Unicode при UTF-8-окружении,
#   ASCII-фолбэк при не-UTF-8 или TERM пустом/dumb; initscr-краш
#   (TERM неизвестен) → фолбэк в plain-режим, не краш. Ключи TUI: q/Q —
#   выход, +/- и =/_ — интервал (клавишами clamp 1..10; стартовое из bash
#   >10 уважается), p — пауза логов (вид заморожен, буферизация живёт).
#   Скрытый --selfcheck — assert-самопроверка без сервера и TTY (exit 0/1);
#   в non-TTY (TERM unset) может дать 37/38 — артефакт окружения, в TTY 38/38.
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
    # (поле, файл в hwmon*, делитель) — масштабы сверены вживу
    #   (на 128 GiB-машине gfx1151):
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
    """Дельты счётчиков /metrics ЗА ТИК (активность, НЕ скорость): движок
    обновляет счётчики токенов только в done-событии, поэтому в работе
    дельта 0, а на завершении — скачок; используется только для sparkline.
    Отрицательный Δ (сброс счётчиков) → None на тике, база всё равно
    обновляется. reset() — после простоя сервера, чтобы после поднятия не
    было ложных дельт (перенос поведения bash-версии)."""

    # @type dict|None  prev_metrics   # метрики предыдущего успешного чтения
    # @type float|None  prev_served    # requests_served предыдущего тика
    def __init__(self):
        self.prev_metrics = None
        self.prev_served = None

    def reset(self):
        self.prev_metrics = None
        self.prev_served = None

    def update(self, snap):
        # @param 1: dict  # snap
        # @returns dict   # prefill/decode — Δprompt/Δcompletion ТОКЕНОВ за
        #   тик (None — нет базы/сброс; НЕ tok/s), served_delta ≥ 0
        out = {'prefill': None, 'decode': None, 'served_delta': 0}
        m = snap['metrics']
        if m is not None:
            if self.prev_metrics is not None:
                for key, counter in (('prefill', 'hipfire_prompt_tokens_total'),
                                     ('decode', 'hipfire_completion_tokens_total')):
                    cur = m.get(counter)
                    prev = self.prev_metrics.get(counter)
                    if cur is not None and prev is not None:
                        d = int(cur - prev)
                        out[key] = d if d >= 0 else None
            self.prev_metrics = m
        st = snap['stats']
        served = st.get('requests_served') if st else None
        if served is not None:
            if self.prev_served is not None and served > self.prev_served:
                out['served_delta'] = int(served - self.prev_served)
            self.prev_served = served
        return out


class LogStreamer(threading.Thread):
    """Логи: при старте — сид `podman logs -t --tail 50 <container>`
    (seed(), синхронно в главном потоке ДO первого тика — D9: стартовые
    строки видны в первой же рамке), далее live-стример
    `podman logs -t --tail 1 -f` (tail 1 = последняя строка сида
    повторится один раз при старте — дедуп: `_seed_tail` отбрасывает её
    только в первой строке live-процесса; сид пуст / live-процесс
    ре-спавнен — дедупа нет, буфер живёт как есть).
    stdout построчно → deque(500), общий со сидом (append thread-safe,
    lock не нужен). podman logs печатает логи в STDERR (проверено вживую
    на 128 GiB-машине gfx1151) — ОБА вызова объединяют stderr в
    stdout-PIPE (stderr=STDOUT);
    с DEVNULL поток пуст и зона вечно «(ждём логи…)». Поток НЕ дёргает
    curses и HTTP. podman/контейнер нет
    → сид и стрим молча падают (buf пуст, зона «(ждём логи…)»), повторные
    попытки раз в ~1 с — повторное появление контейнера видно само.
    stop() завершает подпроцесс (daemon-поток, fd не дёргает)."""

    # @type deque  buf      # последние 500 строк логов (сид + live)
    # @type string|None _seed_tail # хвост сида: дедуп первой live-строки
    def __init__(self, container):
        super().__init__(daemon=True)
        self.container = container
        self.buf = deque(maxlen=500)
        self._proc = None
        self._stopped = False
        self._last_try = 0.0
        self._seed_tail = None

    def seed(self):
        # @returns None  # сид ring-buffer'а: `podman logs -t --tail 50`
        #   (без -f; таймаут 10 с; stderr объединён в stdout — podman logs
        #   печатает в stderr); нет podman/таймаут/rc≠0 — молча (buf
        #   остаётся пустым), исключений не бросает
        try:
            proc = subprocess.run(
                ['podman', 'logs', '-t', '--tail', '50', self.container],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, errors='replace', timeout=10)
        except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
            return
        if proc.returncode == 0:
            lines = proc.stdout.splitlines()
            self.buf.extend(lines)
            self._seed_tail = lines[-1] if lines else None

    def _spawn_once(self):
        now = time.monotonic()
        if now - self._last_try < 1.0:
            return
        self._last_try = now
        try:
            proc = subprocess.Popen(
                ['podman', 'logs', '-t', '--tail', '1', '-f', self.container],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, errors='replace')
        except (FileNotFoundError, OSError):
            return
        self._proc = proc
        for line in proc.stdout:
            line = line.rstrip('\n')
            if self._seed_tail is not None and line == self._seed_tail:
                self._seed_tail = None
                # shortcut: дедуп — только первую строку live-процесса
                # (штатный re-эмит --tail 1); при случайном совпадении теряется
                # одна идентичная строка — допустимо (один раз при старте)
                continue
            self._seed_tail = None
            self.buf.append(line)
        self._proc = None

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


def fmt_tok(v):
    # @returns string  # счётчик токенов компактно: <1000 — целое, 1000…999999
    #   → «99.1k», ≥1M → «1.2M»; None → '-' (watch/cache-tok-temp)
    if v is None:
        return '-'
    if v >= 1_000_000:
        return '%.1fM' % (v / 1e6)
    if v >= 1000:
        return '%.1fk' % (v / 1000.0)
    return str(int(v))


def temp_color(deg):
    # @returns integer  # curses-pair подсветки температуры: None→0,
    #   ≥90 → C_RED, 80…89.9 → C_YELLOW, иначе 0 (пороги от пользователя)
    if deg is None:
        return 0
    if deg >= 90:
        return C_RED
    if deg >= 80:
        return C_YELLOW
    return 0


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
    # @returns string    # полный срез; порядок фиксирован (D2); prefill =
    #   среднее гистограммы (avg), decode = recent_tok_s (последний
    #   завершённый) — честные метрики (D8); без данных → '-'; без датчика → '?'
    st = snap['stats'] or {}
    m = snap['metrics'] or {}
    parts = ['queue: %s' % fmti(st.get('queue_depth'), '-')]
    sv = fmti(st.get('requests_served'), '-')
    if d['served_delta'] > 0:
        sv += ' (+%d)' % d['served_delta']
    parts.append('served: %s' % sv)
    parts.append('cache tok: %s' % fmt_tok(m.get('hipfire_cached_prompt_tokens_total')))
    fails = m.get('hipfire_requests_failed_total')
    if fails is not None and fails > 0:
        parts.append('errors: %d' % int(fails))
    retr = st.get('retries_attempted')
    if retr is not None and retr != 0:
        parts.append('retries: %d' % int(retr))
    parts.append('prefill: %s tok/s (avg)' % fmt1(avg_of(m, 'hipfire_prefill_tokens_per_second')))
    parts.append('decode: %s tok/s (последний)' % fmt1(st.get('recent_tok_s')))
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
    'stats': {'queue_depth': 0, 'requests_served': 123, 'retries_attempted': 1,
              'recent_tok_s': 75.3},
    'metrics': {'hipfire_cached_prompt_tokens_total': 4421.0,
                'hipfire_requests_failed_total': 2.0,
                'hipfire_prefill_tokens_per_second_sum': 1200.0,
                'hipfire_prefill_tokens_per_second_count': 14.0},
    'gpu': {'temp_c': 62.0, 'sclk_mhz': 1500.0, 'power_w': 18.0,
            'busy_pct': 87.0, 'vram_used': None, 'gtt_used': None},
    'cpu_temp_c': 54.0,
    'mem': {'available_gib': 45.2, 'total_gib': 60.4,
            'swap_used_gib': 0.2, 'swap_total_gib': 8.0},
}
PLAIN_D = {'prefill': 0, 'decode': 0, 'served_delta': 1}
PLAIN_FULL = ('12:00:00  queue: 0 │ served: 123 (+1) │ cache tok: 4.4k │ '
              'errors: 2 │ retries: 1 │ prefill: 85.7 tok/s (avg) │ '
              'decode: 75.3 tok/s (последний) │ mem: 45.2/60.4 GiB │ '
              'swap: 0.2/8.0 GiB │ gpu: 62C 1500MHz 18W 87% │ cpu: 54.0C')
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
PLAIN_MIN = ('12:00:00  queue: 0 │ served: 5 │ cache tok: - │ '
             'prefill: - tok/s (avg) │ decode: - tok/s (последний) │ '
             'mem: 12.0/60.0 GiB │ swap: 0.0/8.0 GiB │ '
             'gpu: ?C ?MHz ?W ?% │ cpu: ?C')


def status_bar_layout(W, interval, model, paused):
    # @param 1: integer  # ширина терминала в знаках
    # @returns (left, mid, right, x_mid, x_right, draw_mid, draw_right)  #
    #   bullet в колонке 0 (разрыв 1 кол), left — в колонке 2; модель
    #   усечена так, чтобы разрыв left→mid был гарантированно ≥1 колонки
    #   (контракт: на 80 колонок ни наложений, ни касания); при узком W
    #   mid/right отбрасываются целиком (draw_* = False — put() не клипает
    #   «наполовину», наложений нет)
    prefix = 'hfctl watch │ модель '
    mid = 'интервал %d c' % interval
    right = ('логи: live, пауза: p │ q — выход' if not paused
             else 'логи: пауза, live: p │ q — выход')
    right_x = max(0, W - len(right) - 1)
    mid_x = max(0, min(W // 2 - len(mid) // 2, right_x - len(mid) - 1))
    model_w = mid_x - len(prefix) - 3
    left = prefix + model[:max(0, model_w)]
    draw_mid = mid_x > 2 + len(left)
    draw_right = right_x > 2 + len(left)
    return left, mid, right, mid_x, right_x, draw_mid, draw_right


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
    # Честные метрики (D8): decode = recent_tok_s (последний запрос),
    # prefill = _sum/_count гистограммы
    ck('decode = recent_tok_s (последний)',
       'decode: 75.3 tok/s (последний)' in
       fmt_plain(PLAIN_SNAP, PLAIN_D, '12:00:00'))
    ck('decode no data → -',
       'decode: - tok/s (последний)' in
       fmt_plain(PLAIN_SNAP_MIN, PLAIN_D_MIN, '12:00:00'))
    ck('prefill avg = _sum/_count 1200/14',
       avg_of(m, 'hipfire_prefill_tokens_per_second') == 1200.0 / 14.0)
    ck('prefill avg no samples → None',
       avg_of({'hipfire_prefill_tokens_per_second_sum': 5.0,
               'hipfire_prefill_tokens_per_second_count': 0.0},
              'hipfire_prefill_tokens_per_second') is None)
    # Формат счётчика кэша и пороги температур (watch/cache-tok-temp)
    ck('fmt_tok границы', fmt_tok(999) == '999' and fmt_tok(1000) == '1.0k'
       and fmt_tok(99100) == '99.1k' and fmt_tok(1234567) == '1.2M')
    ck('fmt_tok None → -', fmt_tok(None) == '-')
    ck('temp_color границы', temp_color(79.9) == 0 and temp_color(80) == C_YELLOW
       and temp_color(89.9) == C_YELLOW and temp_color(90) == C_RED)
    ck('temp_color None → 0', temp_color(None) == 0)
    ck('plain cache tok формат',
       'cache tok: 99.1k' in
       fmt_plain(dict(PLAIN_SNAP, metrics=dict(
           PLAIN_SNAP['metrics'],
           hipfire_cached_prompt_tokens_total=99100.0)), PLAIN_D, '12:00:00'))
    ck('hardware temp подсветка',
       [r[2] for r in Watch().rows_hardware(
           dict(PLAIN_SNAP, gpu=dict(PLAIN_SNAP['gpu'], temp_c=91.0),
                cpu_temp_c=83.0))[3:]]
       == [Watch().attr(C_RED), Watch().attr(C_YELLOW)])
    # Сид логов (D9): без podman (pty-окружение) не падает, buf пуст
    ls = LogStreamer('no-such-container')
    try:
        ls.seed()
        seeded_ok = True
    except Exception:
        seeded_ok = False
    ck('seed without podman no crash', seeded_ok)

    # podman logs печатает в STDERR (проверено вживую на 128 GiB-машине
    # gfx1151) — ОБА вызова обязаны объединять stderr в stdout-PIPE;
    # с DEVNULL buf пуст
    # (лог-зона вечно «(ждём логи…)»). Фейковый podman пишет в stderr —
    # прямое воспроизведение дефекта (до фикса оба кейса падают).
    fake_bin = tempfile.mkdtemp(prefix='watch_tui_podman_')
    try:
        shim = fake_bin + '/podman'
        with open(shim, 'w') as f:
            f.write('#!/bin/sh\necho fake-log-line >&2\n')
        os.chmod(shim, 0o755)
        old_path = os.environ['PATH']
        os.environ['PATH'] = fake_bin + os.pathsep + old_path
        try:
            ls_s = LogStreamer('no-such-container')
            ls_s.seed()
            ck('seed: stderr→stdout (podman logs → stderr)',
               list(ls_s.buf) == ['fake-log-line'])
            ls_l = LogStreamer('no-such-container')
            ls_l._spawn_once()
            ck('live: stderr→stdout (podman logs -f → stderr)',
               list(ls_l.buf) == ['fake-log-line'])
            ls_l.stop()
        finally:
            os.environ['PATH'] = old_path
    finally:
        shutil.rmtree(fake_bin)

    hist = [0.0, 2.5, 5.0, 10.0, 10.0, 2.5]
    ck('sparkline UTF-8', sparkline(hist, GLYPHS_UTF, 8) == '▁▂▄██▂')
    ck('sparkline ASCII', sparkline(hist, GLYPHS_ASCII, 8) == '. :@@ ')
    ck('sparkline empty', sparkline([], GLYPHS_UTF, 8) == '')

    ck('glyphs utf8', choose_utf8('UTF-8') is True)
    ck('glyphs ascii encoding', choose_utf8('ANSI_X3.4-1968') is False)
    ck('glyphs term dumb', choose_utf8('UTF-8', term='dumb') is False)
    ck('glyphs term empty', choose_utf8('UTF-8', term='') is False)

    # Масштабы датчиков (сверено вживу на 128 GiB-машине gfx1151) —
    # фейковые деревья /sys
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

    left, mid, right, mid_x, right_x, draw_mid, draw_right = status_bar_layout(
        80, 2, 'qwen3.8:flash-next-mq4-xts', False)
    # строгие '<': равенство mid_x - 2 - len(left)==1 — касание (хвост
    # модели прижат к «интервал»), на 80 кол у prod-моделей это был
    # live-дефект
    ck('status bar 80 cols gap≥1',
       draw_mid and draw_right
       and mid_x - 2 - len(left) >= 1
       and mid_x + len(mid) < right_x
       and right_x + len(right) <= 80)
    # Статус-бар ниже минимума: mid/right отбрасываются целиком (без
    # наложений на left)
    l60, m60, r60, mx60, rx60, dm60, dr60 = status_bar_layout(
        60, 2, 'qwen3.8:flash-next-mq4-xts', False)
    ck('status bar 60 cols',
       dm60 is False and dr60 is True
       and rx60 + len(r60) <= 60
       and rx60 > 2 + len(l60))
    l40, m40, r40, mx40, rx40, dm40, dr40 = status_bar_layout(
        40, 2, 'qwen3.8:flash-next-mq4-xts', False)
    ck('status bar 40 cols',
       dr40 is False
       and (rx40 + len(r40) > 40 or not dr40))
    # Дедуп seed/live: live-процесс ре-эммитит хвост сида (--tail 1) —
    # первая live-строка, равная хвосту сида, отбрасывается
    fake2 = tempfile.mkdtemp(prefix='watch_tui_seed_')
    try:
        shim = fake2 + '/podman'
        with open(shim, 'w') as f:
            f.write('#!/bin/sh\n'
                    'for a in "$@"; do [ "$a" = -f ] && { echo A; echo B; exit 0; }\n'
                    'done\necho A\n')
        os.chmod(shim, 0o755)
        old_path = os.environ['PATH']
        os.environ['PATH'] = fake2 + os.pathsep + old_path
        try:
            ls_a = LogStreamer('no-such-container')
            ls_a.seed()
            ls_b = LogStreamer('no-such-container')
            ls_b.seed()
            ls_b._spawn_once()
            ls_b.stop()
            ck('seed/live no dup',
               list(ls_b.buf) == ['A', 'B'] and list(ls_a.buf) == ['A'])
            # сид пуст (rc≠0) — дедупа нет, все live-строки добавляются
            fake3 = tempfile.mkdtemp(prefix='watch_tui_seed_')
            shim3 = fake3 + '/podman'
            with open(shim3, 'w') as f:
                f.write('#!/bin/sh\n'
                        'for a in "$@"; do [ "$a" = -f ] && { echo C; exit 0; }\n'
                        'done\nexit 1\n')
            os.chmod(shim3, 0o755)
            os.environ['PATH'] = fake3 + os.pathsep + old_path
            ls_e = LogStreamer('no-such-container')
            ls_e.seed()
            ls_f = LogStreamer('no-such-container')
            ls_f._spawn_once()
            ls_f.stop()
            ck('seed empty: live no dedup',
               list(ls_e.buf) == [] and list(ls_f.buf) == ['C'])
            shutil.rmtree(fake3)
        finally:
            os.environ['PATH'] = old_path
    finally:
        shutil.rmtree(fake2)
    # sparkline: последние width значений (свежие не отброшены)
    tail_vals = list(range(1, 31))
    ck('sparkline tail kept',
       len(sparkline(tail_vals, GLYPHS_UTF, 22)) == 22
       and sparkline(tail_vals, GLYPHS_UTF, 22)[-1]
       == GLYPHS_UTF[min(7, int(30 / 30 * 7.999))])
    # Названия блоков/метрик (таблица контракта watch/polish)
    fix = {'engine_ok': True,
           'stats': {'queue_depth': 1, 'requests_served': 123,
                     'retries_attempted': 1},
           'metrics': {'hipfire_requests_failed_total': 2.0,
                       'hipfire_spec_tau_sum': 10.0,
                       'hipfire_spec_tau_count': 2.0,
                       'hipfire_cached_prompt_tokens_total': 5.0},
           'gpu': {'temp_c': 54.0, 'sclk_mhz': 600.0, 'power_w': 5.5,
                   'busy_pct': 0.0, 'vram_used': None, 'gtt_used': None},
           'cpu_temp_c': 39.1,
           'mem': {'available_gib': 45.2, 'total_gib': 60.4,
                   'swap_used_gib': 0.2, 'swap_total_gib': 8.0},
           'kv_free': None, 'kv_total': None, 'uptime_s': 1.0}
    ck('hardware labels',
       [r[0] for r in Watch().rows_hardware(fix)]
       == ['GPU freq', 'GPU load', 'GPU power', 'GPU temp', 'CPU temp'])
    w = Watch()
    ck('engine labels',
       [r[0] for r in w.rows_engine(fix)]
       == ['Model', 'Uptime', 'Queue', 'Errors', w.glyphs.tau + ' avg',
           'Served', 'Retries', 'Cache tok'])
    ck('KV pages dash', ('KV pages', '-') in w.rows_memory(fix, 80))

    # Контент лог-зоны при log_h = 3 НЕ рисуется (review round 2, блокер #1):
    # срез log_view[-(log_h-3)] при log_h=3 = [-0:] = весь буфер, и первая
    # строка печаталась по нижней рамке «Логи». Кейсы с НЕПУСТЫМ log_view на
    # размерах, где лог-зона сжимается в минимум (60×15 / 40×10 / 80×16):
    # нижняя рамка обязана остаться целой. Fake-окно — минимальный curses
    # интерфейс, который использует draw() (getmaxyx/erase/addstr).
    class FakeWin:
        def __init__(self, width, height):
            self.w, self.h = width, height
            self.grid = [[' '] * width for _ in range(height)]

        def getmaxyx(self):
            return (self.h, self.w)

        def erase(self):
            self.grid = [[' '] * self.w for _ in range(self.h)]

        def addstr(self, y, x, s, attr=0):
            for i, ch in enumerate(s):
                if 0 <= y < self.h and 0 <= x + i < self.w:
                    self.grid[y][x + i] = ch

    gw = w.glyphs
    d0 = {'prefill': None, 'decode': None, 'served_delta': 0}
    for W_, H_ in ((60, 15), (40, 10), (80, 16)):
        fw = FakeWin(W_, H_)
        w.log_view = ['LOG-A', 'LOG-B', 'LOG-C']
        w.draw(fw, W_, H_, fix, d0)
        # сравнение внутренней части нижней рамки (колонки 1..W−2): правый
        # угол put отсекает по краю окна, rstrip по нему неиндикативен
        bottom = ''.join(fw.grid[H_ - 1])
        ck('log frame intact at log_h=3 (%d×%d)' % (W_, H_),
           bottom[1:W_ - 1] == gw.h * (W_ - 2))
    # log_h ≥ 4 (80×24 с fix-снапом → 5): хвост буфера виден, свежие строки
    # снизу, рамка цела
    fw = FakeWin(80, 24)
    w.log_view = ['LOG-A', 'LOG-B', 'LOG-C', 'LOG-D', 'LOG-E']
    w.draw(fw, 80, 24, fix, d0)
    grid_rows = [''.join(r) for r in fw.grid]
    # строки контента: x=2 (после «│ » рамки); правый борт рамки остаётся
    # на месте — контент его не перекрывает
    ck('log tail visible at log_h=4+',
       grid_rows[22][2:].startswith('LOG-E')
       and grid_rows[21][2:].startswith('LOG-D')
       and grid_rows[23][1:78] == gw.h * 77)
    w.log_view = []

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
    # @type deque   spark_p / spark_d # история дельт счётчиков за тик (активность)
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
        self.streamer.seed()  # D9: до первой рамки — стартовые строки видны сразу
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
        left, mid, right, mid_x, right_x, draw_mid, draw_right = \
            status_bar_layout(W, self.interval, self.model, self.paused)
        put(win, 0, 2, left)
        if draw_mid:
            put(win, 0, mid_x, mid)
        if draw_right:
            put(win, 0, right_x, right)
        if H < 4 or W < 8:
            return
        # Геометрия (контракт watch/polish §2): высота ряда = макс контента
        # пары + 3 (заголовок + 2 рамки), ряды примыкают (gap=0), «Логи» =
        # остаток вертикали (LOG_MIN=3); клип — только контент-хвосты.
        if H < 10:
            # сетка не влезает (1+3+3+3=10): статус-бар + «Логи» без контента
            self.box(win, 0, H - 3, W, 3)
            put(win, H - 2, 2, 'Логи')
            return
        c_e = 1 if not snap['engine_ok'] else len(self.rows_engine(snap))
        h1 = max(c_e, len(self.rows_hardware(snap))) + 3
        h2 = max(len(self.rows_speed(snap, d, W)),
                 len(self.rows_memory(snap, W))) + 3
        LOG_MIN = 3
        rem = H - 1 - h1 - h2
        if rem < LOG_MIN:
            # не хватает строк суммарно: дефицит из контент-хвостов
            # (ряд 1 — первым, деление целочисленное, детерминированно)
            c1, c2 = h1 - 3, h2 - 3
            d1 = min(c1, (LOG_MIN - rem) * c1 // (c1 + c2))
            d2 = min(c2, LOG_MIN - rem - d1)
            h1 -= d1
            h2 -= d2
        log_h = H - 1 - h1 - h2  # = rem (без клипа) или LOG_MIN (после)
        log_top = 1 + h1 + h2
        col_w = max(10, W // 2)
        x2 = W - col_w
        self.block(win, 0, 1, col_w, h1, 'Движок',
                   [('недоступен', '')] if not snap['engine_ok']
                   else self.rows_engine(snap))
        if W >= 2 * col_w:
            self.block(win, x2, 1, col_w, h1, 'Железо', self.rows_hardware(snap))
        self.block(win, 0, 1 + h1, col_w, h2, 'Скорость',
                   self.rows_speed(snap, d, W))
        if W >= 2 * col_w:
            self.block(win, x2, 1 + h1, col_w, h2, 'Память',
                       self.rows_memory(snap, W))
        self.box(win, 0, log_top, W, log_h)
        put(win, log_top + 1, 2, 'Логи')
        # Контент И «(ждём логи…)» — только при log_h ≥ 4 (при минимуме 3
        # зона = рамка + «Логи» + рамка, строки для контента нет: срез
        # [-(log_h-3)] при log_h=3 это [-0:] = весь буфер, первая строка
        # легла бы на нижнюю рамку). Placeholder — только пока сид пуст и
        # новых строк нет (D9); сид/стрим упали (нет podman/контейнера)
        # — та же строка, без трейса
        if self.log_view and log_h >= 4:
            lines = self.log_view[-(log_h - 3):]
            for i, ln in enumerate(lines):
                put(win, log_top + 2 + i, 2, ln)
        elif log_h >= 4:
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
        # вниз, не поместившиеся отбрасываются ХВОСТОМ (деградация, не
        # перенос). Выравнивание: label дополнен до макс-длины ярлыка
        # блока + ': ' — значения блока стартуют с одной колонки.
        self.box(win, x, y, w, h)
        put(win, y + 1, x + 2, title, curses.A_BOLD)
        lw = max((len(label) + 1 for label, *_ in rows), default=0)
        for i, row in enumerate(rows):
            yy = y + 2 + i
            if yy >= y + h - 1:
                break
            label, value = row[0], row[1]
            attr = row[2] if len(row) > 2 else 0
            # value клипается по внутренней границе блока (колонка рамки
            # x+w−1 не перезаписывается, зазор ≥ 1) — узкий терминал
            # деградирует, а не портит рамку
            put(win, yy, x + 2,
                (label + ':').ljust(lw) + ' ' + value[:max(0, w - lw - 4)],
                attr)

    def rows_engine(self, snap):
        g = self.glyphs
        # Обязательные по DoD 1 (модель/uptime/очередь/ошибки/τ) —
        # первыми: на 80×24 у блока 5 строк, block() отбрасывает ХВОСТ —
        # бьёт только необязательные (обслужено/ретраи/кэш).
        st = snap['stats'] or {}
        m = snap['metrics'] or {}
        rows = [('Model', self.model),
                ('Uptime', fmt_uptime(snap['uptime_s'])),
                ('Queue', fmti(st.get('queue_depth'), '-'))]
        fails = m.get('hipfire_requests_failed_total')
        if fails is not None and fails > 0:
            rows.append(('Errors', str(int(fails)), self.attr(C_RED)))
        rows.append((g.tau + ' avg', fmt1(avg_of(m, 'hipfire_spec_tau'))))
        rows.append(('Served', fmti(st.get('requests_served'), '-')))
        retr = st.get('retries_attempted')
        if retr is not None and retr != 0:
            rows.append(('Retries', str(int(retr)), self.attr(C_RED)))
        rows.append(('Cache tok', fmt_tok(m.get('hipfire_cached_prompt_tokens_total'))))
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
        return [('GPU freq', fmti(gp.get('sclk_mhz')) + ' MHz'),
                ('GPU load', fmti(gp.get('busy_pct')) + '%', busy_attr),
                ('GPU power', fmti(gp.get('power_w')) + ' W'),
                ('GPU temp', fmti(gp.get('temp_c')) + g.deg,
                 self.attr(temp_color(gp.get('temp_c')))),
                ('CPU temp', fmt_c(cpu) + g.deg, self.attr(temp_color(cpu)))]

    def rows_speed(self, snap, d, W):
        # Честные метрики (D8): decode = recent_tok_s (последний завершённый
        # запрос), prefill = среднее гистограммы; sparkline — дельты
        # счётчиков за тик (активность, пики на завершении), НЕ скорость
        st = snap['stats'] or {}
        m = snap['metrics'] or {}
        # окно ≈60 c (maxlen=60//interval); ширина вписана в рамку блока
        # (колонка значения ≤ x+w−2, свежие точки не отбрасываются)
        width = max(4, W // 2 - 18)
        return [('decode', fmt1(st.get('recent_tok_s')) + ' tok/s (последний)'),
                ('prefill', fmt1(avg_of(m, 'hipfire_prefill_tokens_per_second'))
                          + ' tok/s (avg)'),
                ('spark prefill', sparkline(self.spark_p, self.glyphs.spark, width)),
                ('spark decode', sparkline(self.spark_d, self.glyphs.spark, width))]

    def rows_memory(self, snap, W):
        g = self.glyphs
        mem = snap['mem']
        avail, total = mem.get('available_gib'), mem.get('total_gib')
        # bar настолько узок, что полный value «<avail>/<total> GiB»
        # (worst case «999.9/999.9» = 27 зн.) влезает в рамку блока:
        # 1+width+1+11+4 ≤ col_w−2 (80×24: width 10, budget 27)
        width = max(4, min(10, W // 2 - 30))
        mem_attr = self.attr(C_RED) if (avail is not None and avail < 10) else 0
        if avail is None or total is None:
            mem_val = '?'
        else:
            n = max(0, min(width, int(avail / total * width)))
            mem_val = ' %s%s %s/%s GiB' % (g.bar_full * n, g.bar_empty * (width - n),
                                           fmt1(avail), fmt1(total))
        kv = ('%d/%d' % (int(snap['kv_free']), int(snap['kv_total']))
              if snap['kv_free'] is not None and snap['kv_total'] is not None else '-')
        return [('RAM', mem_val, mem_attr),
                ('Swap', '%s/%s GiB' % (fmt1(mem.get('swap_used_gib')),
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
