#!/usr/bin/env bash
# EXP-001 — TUI hfctl watch на живой машине (DoD 1-2, 4-7, 9)
#
# Цель: доказать на реальной установке: TUI рендерит 5 блоков + статус-бар
#   на 80×24, зоны рядов примыкают (пустой строки между рядами нет),
#   названия блоков с заглавной, человекочитаемые ярлыки (CPU temp —
#   дробный), самодостаточная подпись клавиши p в статус-баре, зона логов
#   живая (сид `podman logs --tail 50` при старте — стартовые строки
#   контейнера видны сразу + live `podman logs -f`, дубля последней
#   сид-строки на границе сид/live НЕТ), и после завершённого запроса
#   блок «Скорость» показывает честные метрики (D8): prefill avg > 0 и
#   decode (последний) — число.
#
# ВАЖНО (обновление 2026-11-13, сабстэдж watch/polish): критерии
#   переписаны под новый визуальный контракт task.md (закрытый
#   watch-tui-контракт изменён осознанно):
#   - названия блоков теперь с заглавной: «Движок»/«Железо»/«Скорость»/
#     «Память»/«Логи» (старые lowercase-greps невалидны);
#   - «Tctl» → «CPU temp» (дробная температура сохраняется: ждём
#     \d+\.\d, не целое и не ?);
#   - лог-зона: заголовок «Логи» (старый старт-условие startswith('логи')
#     невалидно);
#   - статус-бар (row 0): самодостаточная подпись p — «логи: live, пауза:
#     p │ q — выход» (live-состояние);
#   - «ряды примыкают» — относительный чек: над заголовком «Скорость»
#     верхняя рамка ряда 2, над ней нижняя рамка ряда 1 (без жёстких
#     строчных индексов — индексы старого сабстэджа невалидны);
#   - дедуп seed/live (DoD 9): в зоне логов capture 1 нет двух АБЮЦИЯННЫХ
#     идентичных строк (live `--tail 1` ре-эммитит хвост сида; дедуп
#     отбрасывает его; в первые 12 с простоя контейнера легитимные
#     идентичные соседи крайне маловероятны — ложный срабатывание
#     допустимо разбирать руками).
#   Критерии, оставшиеся в силе без изменений: «hfctl watch» в row 0,
#   «интервал N c» + разрыв ≥1 кол перед ним (контракт fix round 2
#   закрытого сабстэджа), «(ждём логи…)»/«логи недоступны» — не PASS,
#   честные метрики D8 (prefill avg > 0, decode — число).
#
# Prerequisites (проверяются скриптом):
#   - запуск НА целевой машине (ssh -t <host> 'bash -s' < этот скрипт,
#     или копирование и локальный запуск там)
#   - tmux, python3, podman в PATH; контейнер hipfire_hipfire_1 running;
#     /stats на :$PORT отвечает
#
# ВАЖНО (фикс round 2): tmux-окно исполняет команду в НЕинтерактивном
#   shell БЕЗ .bashrc → ~/.local/bin в PATH нет → голое «hfctl» даёт rc=127
#   и сессия закрывается мгновенно (корень FAIL round 1). Поэтому команда
#   окна — ПОЛНЫЙ путь $HFCTL_BIN + явный export PATH.
#
# ВАЖНО (фикс round 3, D8/D9): «live prefill > 0» — НЕ критерий: движок
#   обновляет счётчики токенов только в done-событии (live-скорости в
#   процессе не существует — FACTS). Критерий: в capture ПОСЛЕ завершения
#   хотя бы одного запроса `prefill: N tok/s (avg)` с N > 0 и `decode:
#   N tok/s (последний)` — число (не ?/-).
#
# ВАЖНО (фикс 2026-11-13, fix-цикл 2 round 2 — ложный FAIL): в 80×24
#   capture заголовок лог-зоны — ПОЛНАЯ строка рамки «│ Логи … │» (правая
#   граница есть); парсер учитывает обе формы (рамка/упрощённый);
#   самопроверка парсера на mini-фикстурах идёт ПЕРЕД анализом: провал →
#   RESULT: ERROR — парсер (НЕ FAIL — продукт не виноват).
#
# Команда запуска:
#   ssh -t <host> 'bash -s' < flow/external/EXP-001-tui-ssh.sh
#
# Что есть PASS: capture 1 (80×24) содержит все 5 заголовков блоков с
#   заглавной (Движок/Железо/Скорость/Память/Логи) + «hfctl watch» и
#   «интервал N c» (разрыв ≥1 кол перед «интервал»), самодостаточную
#   подпись p («логи: live, пауза: p │ q — выход»); ряды примыкают
#   (рамка-рамка без строки между); «CPU temp» — дробное число; в зоне
#   логов ≥1 строка, не «(ждём логи…)» и не «логи недоступны», без
#   дубля последней сид-строки; capture 3 (после завершения запроса)
#   содержит prefill avg > 0 и decode число. Вывод + captures — в
#   EXP-001-tui-ssh.result.txt.
set -uo pipefail
cd "$(dirname "$0")"
RES="EXP-001-tui-ssh.result.txt"
: > "$RES"
say() { printf '%s\n' "$*" | tee -a "$RES"; }

fail() { say "RESULT: BLOCKED — $*"; exit 2; }

[ -t 1 ] && say "примечание: запуск в TTY (ок)" || say "примечание: запуск не в TTY (tmux всё равно даёт свой экран)"
command -v tmux >/dev/null || fail "tmux не найден"
command -v podman >/dev/null || fail "podman не найден"
command -v python3 >/dev/null || fail "python3 не найден"
command -v curl >/dev/null || fail "curl не найден"
HFCTL_BIN="$(command -v hfctl || echo "$HOME/hipfire/hfctl")"
[ -x "$HFCTL_BIN" ] || fail "hfctl не найден (ни в PATH, ни в ~/hipfire/hfctl)"
ENVCFG="$HOME/hipfire/.env"
PORT="$(sed -n 's/^HIPFIRE_PORT=//p' "$ENVCFG" 2>/dev/null | head -n1)"
PORT="${PORT:-11435}"
MODEL="$(sed -n 's/^HIPFIRE_MODEL=//p' "$ENVCFG" 2>/dev/null | head -n1)"
MODEL="${MODEL:-qwen3.8:27b-mq4-xts}"
CONTAINER="${HFCTL_EXP_CONTAINER:-hipfire_hipfire_1}"
podman ps --format '{{.Names}}' | grep -qx "$CONTAINER" || fail "контейнер $CONTAINER не running"
curl -fsS -m 5 "http://127.0.0.1:$PORT/stats" >/dev/null 2>&1 || fail "/stats на :$PORT не отвечает"

TMOPT=(-L exp001)
tmux ${TMOPT[@]} kill-server 2>/dev/null || true
# tmux-окно = не интерактивный shell (без .bashrc) → в PATH нет ~/.local/bin;
# полный путь $HFCTL_BIN + явный export PATH (корень FAIL round 1 — rc=127).
TMUX_CMD="export PATH=\"$HOME/.local/bin:$PATH\"; exec '$HFCTL_BIN' watch"
tmux ${TMOPT[@]} new-session -d -x 80 -y 24 -n watch -s wt "$TMUX_CMD"
say "tmux-сессия wt (80x24) поднята: hfctl watch"
sleep 12

CAP1="$(tmux ${TMOPT[@]} capture-pane -p -t wt:0.0)"
printf '%s\n' "$CAP1" > "$RES.cap1.txt"; say "--- capture 1 (до генерации) ---"; tee -a "$RES" < "$RES.cap1.txt"

# живой long-запрос в фоне (генерация)
curl -fsS -m 180 "http://127.0.0.1:$PORT/v1/chat/completions" \
    -H 'content-type: application/json' \
    -d '{"model":"'"$MODEL"'","max_tokens":600,"reasoning_effort":"none","messages":[{"role":"user","content":"Write a detailed 600-word essay on the history of streaming computation."}]}' >/dev/null 2>&1 &
CURL_PID=$!
sleep 3
CAP2="$(tmux ${TMOPT[@]} capture-pane -p -t wt:0.0)"
printf '%s\n' "$CAP2" > "$RES.cap2.txt"; say "--- capture 2 (во время генерации) ---"; tee -a "$RES" < "$RES.cap2.txt"

# ждём завершение запроса (done → recent_tok_s и prefill-гистограмма
# обновляются — счётчики движка живут только в done-событии)
DEADLINE=$((SECONDS + 180))
while kill -0 "$CURL_PID" 2>/dev/null && [ "$SECONDS" -lt "$DEADLINE" ]; do sleep 2; done
CAP3="$(tmux ${TMOPT[@]} capture-pane -p -t wt:0.0)"
printf '%s\n' "$CAP3" > "$RES.cap3.txt"; say "--- capture 3 (после завершения запроса) ---"; tee -a "$RES" < "$RES.cap3.txt"

tmux ${TMOPT[@]} kill-server 2>/dev/null || true
say "tmux-сессия закрыта"

# анализ
python3 - "$RES.cap1.txt" "$RES.cap3.txt" >>"$RES" 2>&1 <<'PYEOF'
import re, sys
c1, c3 = open(sys.argv[1]).read(), open(sys.argv[2]).read()
fails = []
# DoD 4: названия блоков — с заглавной (контракт watch/polish; старые
# lowercase-имена в capture не должны встречаться)
for k in ('Движок', 'Железо', 'Скорость', 'Память', 'Логи', 'hfctl watch'):
    if k not in c1:
        fails.append('нет блока/статус-бара: ' + k)
row0 = c1.splitlines()[0] if c1.splitlines() else ''
# DoD 7: новый статус-бар — самодостаточная подпись p (live-состояние)
if 'интервал' not in row0:
    fails.append('нет «интервал N c» в статус-баре')
else:
    i = row0.index('интервал')
    if i < 1 or row0[i - 1] != ' ':
        fails.append('нет разрыва 1 кол. перед «интервал»: %r' % row0)
if 'логи: live, пауза: p │ q — выход' not in row0:
    fails.append('нет самодостаточной подписи p (live) в row0: %r' % row0)
# лог-зона: заголовок «Логи» (капс, контракт watch/polish) в двух формах
# capture — упрощённый (без рамок) или рамка 80 кол «│ Логи … │» (правая
# граница есть); контент до нижней рамки («└…»/«+--…»); левая рамка «│» +
# отступ — срез, правая «│» отбрасывается (безвредна).
def logzone_lines(cap):
    out, started, framed = [], False, False
    for ln in cap.splitlines():
        s = ln.rstrip()
        core = s.lstrip()
        if started:
            if core.startswith(('└', '+--')):
                break
            if framed:
                body = core[1:].lstrip() if core[:1] == '│' else core
            else:
                body = s[2:] if s.startswith('  ') else core
            out.append(body.rstrip('│+').rstrip())
            continue
        if core.startswith('Логи'):
            started = True
        elif core[:1] == '│' and core[1:].lstrip().startswith('Логи'):
            started, framed = True, True
    return out
# самопроверка парсера (до анализа): mini-фикстуры обеих форм capture —
# «рамка 80 кол» и «упрощённый (без рамок)»; парсер обязан найти ≥1 строку
# на обоих, правая рамка должна отбрасываться. Провал — RESULT: ERROR —
# парсер (скрипт сломан сам по себе, НЕ FAIL продукта).
def _z(c):
    return [l for l in logzone_lines(c) if l]
FIX_FRAMED = ('│ Логи' + ' ' * 73 + '│\n'
              '│ 12:00:01 seed-line-A' + ' ' * 40 + '│\n'
              '│ 12:00:05 seed-line-B' + ' ' * 40 + '│\n'
              '└' + '─' * 78 + '┘\n')
FIX_PLAIN = ('  Логи\n  12:00:01 seed-line-A\n  12:00:05 seed-line-B\n'
             '+' + '-' * 78 + '+\n')
_zf, _zp = _z(FIX_FRAMED), _z(FIX_PLAIN)
if len(_zf) < 1 or any('│' in l for l in _zf) or len(_zp) < 1:
    print('АНАЛИЗ: ERROR — парсер: самопроверка не прошла '
          '(framed=%r, plain=%r)' % (_zf, _zp))
    sys.exit(1)
zone_all = logzone_lines(c1)
zone = [l for l in zone_all
        if l and l != '(ждём логи…)' and not l.startswith('логи недоступны')]
if not zone:
    fails.append('зона логов без стартовых строк: %r' % zone_all)
else:
    # DoD 9: дедуп seed/live — live-процесс ре-эммитит последнюю сид-строку
    # (--tail 1); дедуп отбрасывает её → в capture нет двух АБЮЦИЯННЫХ
    # идентичных строк в зоне. В первые 12 с простоя контейнера
    # легитимные дубли крайне маловероятны (ложное срабатывание
    # разбирать руками).
    dups = [a for a, b in zip(zone, zone[1:]) if a == b]
    if dups:
        fails.append('дубль в зоне логов (граница сид/live): %r' % dups)
# DoD 1/2: «ряды примыкают» — относительный чек без жёстких индексов:
# над строкой заголовка «Скорость» (i) — верхняя рамка ряда 2 (i-1),
# над ней — нижняя рамка ряда 1 (i-2); пустой строки между рядами нет.
rows = c1.splitlines()
idx = [k for k, r in enumerate(rows) if 'Скорость' in r]
if not idx:
    fails.append('нет строки с заголовком «Скорость»')
else:
    i = idx[0]
    def top_row(r):
        return (len(r) >= 80 and r[0] == '┌' and r[39] == '┐'
                and r[40] == '┌' and r[79] == '┐'
                and set(r[1:39]) == {'─'} and set(r[41:79]) == {'─'})
    def bot_row(r):
        return (len(r) >= 80 and r[0] == '└' and r[39] == '┘'
                and r[40] == '└' and r[79] == '┘'
                and set(r[1:39]) == {'─'} and set(r[41:79]) == {'─'})
    if i < 2 or not top_row(rows[i - 1]) or not bot_row(rows[i - 2]):
        fails.append('ряды не примыкают (i=%d): %r | %r'
                     % (i, rows[i - 2] if i >= 2 else '', rows[i - 1]))
# DoD 5: «CPU temp» — дробное число (не ?, не целое)
m = re.search(r'CPU temp:\s*([?0-9.]+)', c1)
if not m or m.group(1) == '?':
    fails.append('CPU temp без числа: ' + (m.group(0) if m else 'строки нет'))
elif not re.search(r'\.\d', m.group(1)):
    fails.append('CPU temp не дробный (контракт: температура с одним знаком): '
                 + m.group(0))
# D8 (без изменений по смыслу): честные метрики после завершённого запроса.
# Фикс test-triage round 1 (watch/polish): DoD 6 — значения выровнены в
# колонку ((label+':').ljust(lw)+' '), между «:» и числом НЕСКОЛЬКО пробелов →
# «\s+» вместо литерального «: » (старый одиночный пробел давал ложный FAIL
# «строки нет» при корректном capture).
mp = re.search(r'prefill:\s+([0-9.]+) tok/s \(avg\)', c3)
mpx = re.search(r'prefill:\s+(\S+) tok/s \(avg\)', c3)
md = re.search(r'decode:\s+([0-9.]+) tok/s \(последний\)', c3)
mdx = re.search(r'decode:\s+(\S+) tok/s \(последний\)', c3)
if not mp or float(mp.group(1)) <= 0:
    fails.append('prefill avg не > 0 после запроса: ' + (mpx.group(0) if mpx else 'строки нет'))
if not md:
    fails.append('decode (последний) не число: ' + (mdx.group(0) if mdx else 'строки нет'))
if fails:
    print('АНАЛИЗ: FAIL — ' + '; '.join(fails))
else:
    print('АНАЛИЗ: все критерии выполнены (CPU temp=%sC, prefill avg=%s tok/s, '
          'decode=%s tok/s, строк в зоне логов: %d)'
          % (m.group(1), mp.group(1), md.group(1), len(zone)))
PYEOF

if grep -q '^АНАЛИЗ: все критерии' "$RES"; then
  say "RESULT: PASS — TUI 80x24: 5 блоков с заглавной + статус-бар (самодостаточная p, разрыв ≥1 перед «интервал»), ряды примыкают, CPU temp дробный, сид-строки логов без дубля seed/live, честные метрики D8"
elif grep -q '^АНАЛИЗ: ERROR' "$RES"; then
  say "RESULT: ERROR — парсер лог-зоны: самопроверка на mini-фикстурах не прошла (продукт не виноват; см. $RES)"
else
  say "RESULT: FAIL — см. АНАЛИЗ в $RES"
fi
