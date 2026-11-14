#!/usr/bin/env bash
# EXP-003 — plain-режим в TTY-сессии не портит терминал (DoD 10)
#
# Цель: доказать, что `hfctl watch > f` в ssh-TTY-сессии (stdout → файл =
#   plain-режим) НЕ оставляет в f байтов ESC (0x1b) и не переводит
#   терминал пользователя в альтернативный экран: после завершения в той
#   же сессии обычный вывод (echo ok) печатается чисто.
#
# Prerequisites (проверяются скриптом): запуск НА целевой машине В TTY
#   (ssh -t); hfctl (PATH или ~/hipfire/hfctl); контейнер running, /stats
#   отвечает.
#
# Команда запуска:
#   ssh -t <host> 'bash -s' < flow/external/EXP-003-plain-tty-safe.sh
#
# Что есть PASS: в f нет ни одного байта 0x1b; после watch `echo ok`
#   печатается (терминал не в alt-экране — ФИНАЛЬНАЯ визуальная
#   подтверждение делает пользователь, глядя на свою сессию; скрипт
#   проверяет автоматизируемую часть и помечает её в RESULT). Вывод —
#   в EXP-003-plain-tty-safe.result.txt.
set -uo pipefail
cd "$(dirname "$0")"
RES="EXP-003-plain-tty-safe.result.txt"
: > "$RES"
say() { printf '%s\n' "$*" | tee -a "$RES"; }
fail() { say "RESULT: BLOCKED — $*"; exit 2; }

[ -t 0 ] || fail "stdin не TTY — скрипт запускать ssh -t (нужна настоящая TTY-сессия)"
HFCTL_BIN="$(command -v hfctl || echo "$HOME/hipfire/hfctl")"
[ -x "$HFCTL_BIN" ] || fail "hfctl не найден"
command -v podman >/dev/null || fail "podman не найден"
ENVCFG="$HOME/hipfire/.env"
PORT="$(sed -n 's/^HIPFIRE_PORT=//p' "$ENVCFG" 2>/dev/null | head -n1)"
PORT="${PORT:-11435}"
CONTAINER="${HFCTL_EXP_CONTAINER:-hipfire_hipfire_1}"
podman ps --format '{{.Names}}' | grep -qx "$CONTAINER" || fail "контейнер $CONTAINER не running"
curl -fsS -m 5 "http://127.0.0.1:$PORT/stats" >/dev/null 2>&1 || fail "/stats на :$PORT не отвечает"

OUT="$RES.watch.txt"
say "запуск: hfctl watch > f (8 c, TTY-сессия, stdout → файл)"
HFCTL_PORT="$PORT" timeout 8 "$HFCTL_BIN" watch > "$OUT" 2>&1
say "watch завершён; проверка файла"

ESC=$(tr -cd '\033' < "$OUT" | wc -c)
say "байты ESC (0x1b) в f: $ESC"
say "строки plain-стрима: $(wc -l < "$OUT")"
echo ok
say "↑ проверка чистоты терминала: выше должно быть просто 'ok', терминал не в alt-экране (визуально подтверждает пользователь)"

if [ "$ESC" -eq 0 ]; then
  say "RESULT: PASS — в f нет 0x1b, стрим plain; терминал: пользователь подтверждает визуально"
else
  say "RESULT: FAIL — в f найдено $ESC байт(ов) 0x1b (alt-экран просочился)"
fi
