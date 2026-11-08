#!/bin/bash
# hfctl: полный деплой hipfire-стека на целевой хост (чистая машина или che-evo).
#
# Использование:
#   scripts/deploy_hipfire.sh all           # всё по порядку (по умолчанию)
#   scripts/deploy_hipfire.sh prep          # host_pre(p): apt, render, memlock, linger, unit
#   scripts/deploy_hipfire.sh repo          # перенос репо (tar|ssh, без .git)
#   scripts/deploy_hipfire.sh config        # .env + compose.local.yml + прод-конфиг
#   scripts/deploy_hipfire.sh up            # compose up -d --force-recreate
#   scripts/deploy_hipfire.sh health        # wait_health
#   scripts/deploy_hipfire.sh smoke         # смоук-запросы
#
# Переменные окружения (см. scripts/lib.sh):
#   HF_HOST (hipfire@192.168.1.254), HF_KEY (~/.ssh/strix_halo_key),
#   HF_STACK ("hipfire" — имя каталога стека в $HOME на цели),
#   HF_REPO_SRC (локальный источник репозитория hipfire).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib.sh"
PHASE=${1:-all}
HF_REPO_SRC=${HF_REPO_SRC:-/workspace/hipfire}

do_prep()   { echo "== PHASE prep ==";   bash "$here/host_prep.sh"; }
do_repo() {
  echo "== PHASE repo =="
  [ -f "$HF_REPO_SRC/compose.yml" ] || hf_die "нет $HF_REPO_SRC/compose.yml (HF_REPO_SRC=$HF_REPO_SRC)"
  hf_require_ssh
  echo "   перенос: $HF_REPO_SRC -> $HF_HOST:~/$HF_STACK (tar|ssh, без .git)"
  tar -C "$HF_REPO_SRC" --exclude=.git -cf - . \
    | hfssh "mkdir -p ~/$HF_STACK && tar -xf - -C ~/$HF_STACK"
  hfssh "ls ~/$HF_STACK/compose.yml ~/$HF_STACK/compose.halo.yml ~/$HF_STACK/benchmarks/prompts >/dev/null && echo '   репо на месте'"
}
do_config() { echo "== PHASE config =="; bash "$here/config_prod.sh"; }
do_up() {
  echo "== PHASE up (first up создаёт volume + тянет модель; далее force-recreate) =="
  hfssh "cd ~/$HF_STACK && podman compose -f compose.yml -f compose.halo.yml -f compose.local.yml up -d --force-recreate"
}
do_health()  { echo "== PHASE health ==";  bash "$here/wait_health.sh" 600; }
do_smoke()   { echo "== PHASE smoke ==";   bash "$here/smoke.sh"; }

case "$PHASE" in
  all)    do_prep; do_repo; do_config; do_up; do_health; do_smoke ;;
  prep)   do_prep ;;
  repo)   do_repo ;;
  config) do_config ;;
  up)     do_up ;;
  health) do_health ;;
  smoke)  do_smoke ;;
  *) hf_die "unknown phase: $PHASE (all|prep|repo|config|up|health|smoke)" ;;
esac

echo "hfctl deploy: PHASE '$PHASE' DONE."
