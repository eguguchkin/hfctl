#!/bin/bash
# hfctl (remote): конфиг под слот-движок. $1 = slots (default 2), $2 = ctx/slot.
# 4 слота x 262144 НЕ влезут в OOM-guard (needs ~48.7 GiB) — держим 2×262144
# или меньше ctx при большем числе слотов.
set -u
SLOTS=${1:-2}
CTX=${2:-262144}
IMAGE=ghcr.io/warpfront/hipfire:0.4.5
VOL=$(podman volume ls --format '{{.Name}}' | grep -E '(^|[-_])hipfire-config$|^hipfire_hipfire-config$' | head -1)
[ -n "$VOL" ] || { echo "FATAL: volume hipfire-config не найден" >&2; exit 1; }
cfgset() {
  podman run --rm -v "$VOL:/home/hipfire/.hipfire" "$IMAGE" \
    hipfire config set "$1" "$2" 2>&1 | tail -1
}
cfgset serve.multi_slot true
cfgset serve.multi_slot_slots "$SLOTS"
cfgset serve.multi_slot_ctx "$CTX"
cfgset serve.continuous_batch_size 1
cfgset serve.vmm_batch false
cd "$HOME/$HF_STACK" || exit 1
podman compose -f compose.yml -f compose.halo.yml -f compose.local.yml up -d --force-recreate >/dev/null 2>&1
echo "slots ON ($SLOTS x $CTX): стек пересоздан, ждём health локальным враппером"
