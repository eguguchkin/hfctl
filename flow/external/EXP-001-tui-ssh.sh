#!/usr/bin/env bash
# EXP-001 — TUI hfctl watch на живой машине (DoD 1, 2, 5, 10)
#
# Цель: доказать на реальной установке: TUI рендерит 5 блоков + статус-бар
#   на 80×24, зона логов живая (течёт `podman logs -f`), цифра Tctl
#   присутствует, и при живой генерации (фоновый long-запрос к серверу)
#   «live prefill» показывает число > 0.
#
# Prerequisites (проверяются скриптом):
#   - запуск НА целевой машине (ssh -t <host> 'bash -s' < этот скрипт,
#     или копирование и локальный запуск там)
#   - tmux, python3, podman в PATH; контейнер hipfire_hipfire_1 running;
#     /stats на :$PORT отвечает
#
# Команда запуска:
#   ssh -t <host> 'bash -s' < flow/external/EXP-001-tui-ssh.sh
#
# Что есть PASS: capture-pane (80×24) содержит все 5 заголовков блоков
#   (движок/железо/скорость/память/логи) + «hfctl watch» (статус-бар);
#   в зоне логов нет «логи недоступны» и «(ждём логи…)» (вид не пуст —
#   живые логи текут); строка «Tctl» содержит число (не ?); после
#   запуска фоновой генерации capture содержит «live prefill: N tok/s»
#   с N > 0. Вывод + capture — в EXP-001-tui-ssh.result.txt.
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
tmux ${TMOPT[@]} new-session -d -x 80 -y 24 -n watch -s wt "hfctl watch"
say "tmux-сессия wt (80x24) поднята: hfctl watch"
sleep 12

CAP1="$(tmux ${TMOPT[@]} capture-pane -p -t wt:0.0)"
printf '%s\n' "$CAP1" > "$RES.cap1.txt"; say "--- capture 1 (до генерации) ---"; tee -a "$RES" < "$RES.cap1.txt"

# живой long-запрос в фоне (генерация)
curl -fsS -m 90 "http://127.0.0.1:$PORT/v1/chat/completions" \
    -H 'content-type: application/json' \
    -d '{"model":"'"$MODEL"'","max_tokens":600,"reasoning_effort":"none","messages":[{"role":"user","content":"Write a detailed 600-word essay on the history of streaming computation."}]}' >/dev/null 2>&1 &
sleep 3
CAP2="$(tmux ${TMOPT[@]} capture-pane -p -t wt:0.0)"
printf '%s\n' "$CAP2" > "$RES.cap2.txt"; say "--- capture 2 (во время генерации) ---"; tee -a "$RES" < "$RES.cap2.txt"

tmux ${TMOPT[@]} kill-server 2>/dev/null || true
say "tmux-сессия закрыта"

# анализ
python3 - "$RES.cap1.txt" "$RES.cap2.txt" >>"$RES" 2>&1 <<'PYEOF' || true
import sys
c1, c2 = open(sys.argv[1]).read(), open(sys.argv[2]).read()
fails = []
for k in ('движок', 'железо', 'скорость', 'память', 'логи', 'hfctl watch'):
    if k not in c1:
        fails.append('нет блока/статус-бара: ' + k)
if 'интервал' not in c1:
    fails.append('нет «интервал N c» в статус-баре')
for k in ('логи недоступны', '(ждём логи…)'):
    if k in c1:
        fails.append('зона логов не живая: ' + k)
import re
m = re.search(r'Tctl:\s*([?0-9.]+)', c1)
if not m or m.group(1) == '?':
    fails.append('Tctl без числа: ' + (m.group(0) if m else 'строки нет'))
m2 = re.search(r'live prefill:\s*([0-9.]+)\s*tok/s', c2)
if not m2 or float(m2.group(1)) <= 0:
    fails.append('live prefill при генерации не > 0: ' + (m2.group(0) if m2 else 'нет числа'))
if fails:
    print('АНАЛИЗ: FAIL — ' + '; '.join(fails))
else:
    print('АНАЛИЗ: все критерии выполнены (Tctl=' + m.group(1) + 'C, live prefill=' + m2.group(1) + ' tok/s)')
PYEOF

if grep -q '^АНАЛИЗ: все критерии' "$RES"; then
  say "RESULT: PASS — TUI 80x24: 5 блоков + статус-бар, живые логи, Tctl=$ (см. АНАЛИЗ), live prefill > 0 при генерации"
else
  say "RESULT: FAIL — см. АНАЛИЗ в $RES"
fi
