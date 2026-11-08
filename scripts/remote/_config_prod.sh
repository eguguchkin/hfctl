#!/bin/bash
# hfbox (remote): прод .env + compose.local.yml + one-shot prod-конфиг в volume.
# Полностью идемпотентно, можно гонять до первого up.
set -u
STACK="$HF_STACK"            # имя каталога стека в $HOME
DIR="$HOME/$STACK"
IMAGE=ghcr.io/warpfront/hipfire:0.4.5
MODEL_TAG=qwen3.8:27b-mq6-xt
MODELS_PATH="$HOME/models/hipfire"   # переопредели HF_MODELS_PATH при желании
[ -n "${HF_MODELS_PATH:-}" ] && MODELS_PATH="$HF_MODELS_PATH"

[ -d "$DIR" ] || { echo "FATAL: нет каталога стека $DIR (сначала deploy_hipfire.sh repo)" >&2; exit 1; }
cd "$DIR"

echo "== 1. .env (prod)"
cat > .env <<EOF
# hfbox prod (2026-11-07). Compose-дефолты ниже повторяют .env.example.
HIPFIRE_MODEL=$MODEL_TAG
HIPFIRE_PORT=11435
HIPFIRE_BIND=0.0.0.0
HIPFIRE_UI=0
HIPFIRE_SERVE_ARGS=
HIPFIRE_MODELS_PATH=$MODELS_PATH
HIPFIRE_IMAGE=$IMAGE
HIPFIRE_IMAGE_TARGET=full
COMPOSE_FILE=compose.yml:compose.halo.yml:compose.local.yml
EOF
echo "   записан .env (COMPOSE_FILE в .env инертен: podman-compose его НЕ читает," 
echo "   перечень compose-файлов нужно всегда передавать через -f явно)"

echo "== 2. compose.local.yml (промпт-фикстуры → /prompts:ro + DFlash draft)"
cat > compose.local.yml <<EOF
services:
  hipfire:
    volumes:
      - ./benchmarks/prompts:/prompts:ro
    environment:
      # MQ6-xt не объявляет dflash-sidecar в реестре; MQ4 draft — рекомендованный
      # контроллер для qwen3.8:27b. Пустое значение = DFlash выключен.
      HIPFIRE_DFLASH_DRAFT: ${HF_DFLASH_DRAFT:-/home/hipfire/.hipfire/models/qwen38-27b-dflash-mq4.hfq}
EOF

echo "== 3. one-shot конфиг в volume (движок может быть выключен)"
VOL=$(podman volume ls --format '{{.Name}}' | grep -E '(^|[-_])hipfire-config$|^hipfire_hipfire-config$' | head -1)
[ -n "$VOL" ] || { echo "FATAL: volume hipfire-config не найден (первый запуск создаст его: compose up -d)" >&2; exit 1; }
echo "   volume: $VOL"
cfgset() {
  podman run --rm -v "$VOL:/home/hipfire/.hipfire" "$IMAGE" \
    hipfire config set "$1" "$2" 2>&1 | tail -1
}
cfgset memory.max_seq 262144
cfgset memory.session_cache_disk_bytes 34359738368   # 32 GiB (на qwen3.5 инертен, ключ с запасом)
cfgset serve.vmm_batch true
cfgset serve.continuous_batch_size 4
cfgset serve.batch_nonexact true
cfgset serve.multi_slot false
cfgset serve.multi_slot_slots 4                       # запас для экспериментов (прод: false)
cfgset serve.multi_slot_ctx 262144                    # инертен при multi_slot=false
# DFlash для mq6-xt: тег не объявляет sidecar, схема default off → включаем
# явно; путь черновика приходит env из compose.local.yml (HIPFIRE_DFLASH_DRAFT).
# `on` = fail-closed: отсутствие/несовместимость draft валят загрузку заметно.
# Отключение: HF_DFLASH=off (тогда и HIPFIRE_DFLASH_DRAFT не нужен).
cfgset speculation.dflash "${HF_DFLASH:-on}"

echo "== 4. effective config.toml"
podman run --rm -v "$VOL:/home/hipfire/.hipfire" "$IMAGE" \
  cat /home/hipfire/.hipfire/config.toml 2>/dev/null | grep -vE '^\s*#|^$'

echo "OK: config_prod DONE. Дальше: compose up -d (deploy_hipfire.sh) + wait_health"
