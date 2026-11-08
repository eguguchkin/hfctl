#!/bin/bash
# hfctl: переключение режима multi_slot на целевом сервере.
#   scripts/slots_mode.sh on [slots=2] [ctx=262144]   — включить слот-движок
#   scripts/slots_mode.sh off                          — вернуть прод (config_prod)
# Оба направления: конфиг one-shot -> force-recreate -> wait_health -> smoke-lite.
# СМЫСЛ: head-of-line изоляция (короткий не ждёт длинный) ценой ~25% агрегата
# и ~40% соло-скорости (см. AGENTS.md «Замеры параллельности»).
set -euo pipefail
here="$(dirname "$0")"
source "$here/lib.sh"
MODE=${1:-}
SLOTS=${2:-2}
CTX=${3:-262144}
hf_require_ssh
case "$MODE" in
  on)
    echo "== slots ON: slots=$SLOTS ctx=$CTX =="
    hfssh_run "$here/remote/_slots_on.sh" "$SLOTS" "$CTX"
    bash "$here/wait_health.sh" 600
    ;;
  off)
    echo "== slots OFF: возврат к проду (serial FIFO + DFlash) =="
    bash "$here/config_prod.sh" >/dev/null
    hfssh "cd ~/$HF_STACK && podman compose -f compose.yml -f compose.halo.yml -f compose.local.yml up -d --force-recreate >/dev/null 2>&1"
    bash "$here/wait_health.sh" 600
    ;;
  *)
    hf_die "использование: slots_mode.sh on [slots=2] [ctx=262144] | off"
    ;;
esac
# показать, что реально активно
hfssh 'curl -fsS http://127.0.0.1:11435/health' | python3 -c 'import json,sys; d=json.load(sys.stdin); c=d["capabilities"]; print("active:", c["mode"], "| multi_slot:", c["multi_slot"], "| slots:", c.get("multi_slot_slots"), "| ctx:", c.get("multi_slot_ctx"))'
