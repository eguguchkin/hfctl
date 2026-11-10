# shellcheck shell=bash
# ── state-каталоги по профилям (этап 7: явные bind вместо named volumes) ────
# config/ → /home/hipfire/.hipfire, kernel/ → /var/cache/hipfire.
# disk-тир контекст-кэша (session-cache/) живёт внутри config/ → per-профиль
# автоматически; RAM-тир так и был per-процесс (умирает при recreate).
state_dir() { echo "$STATE_BASE/$1"; }
migrate_state() {  # migrate_state <profile> — legacy named volumes → profiles/<p>
  # одноразово, idempotent: копирует _data в каталог профиля, если тот пуст
  # (в legacy-вольюме у юзера может быть гигабайты disk-тира — копируем всё).
  local base="$STATE_BASE/$1" vdata
  mkdir -p "$base/config" "$base/kernel"
  vdata=$(podman volume inspect hipfire_hipfire-config --format '{{.Mountpoint}}' 2>/dev/null || true)
  if [ -n "$vdata" ] && [ -d "$vdata" ] && [ -z "$(ls -A "$base/config" 2>/dev/null)" ]; then
    cp -a "$vdata/." "$base/config/"
    log "state: миграция legacy-volume → $(state_dir "$1")/config (вкл. session-cache)"
  fi
  vdata=$(podman volume inspect hipfire_hipfire-kernels --format '{{.Mountpoint}}' 2>/dev/null || true)
  if [ -n "$vdata" ] && [ -d "$vdata" ] && [ -z "$(ls -A "$base/kernel" 2>/dev/null)" ]; then
    cp -a "$vdata/." "$base/kernel/"
    log "state: миграция legacy-volume → $(state_dir "$1")/kernel"
  fi
}

# ── каталоги моделей по сетам (изоляция профилей: сервер видит только свой
# сет → запрос с чужим model получает 404 вместо молчаливого swap) ───────────
model_set() { case "$1" in flash-multi) echo flash ;; *) echo 27b ;; esac; }
set_models_dir() { MODELS_DIR="$MODELS_BASE/$(model_set "$1")"; mkdir -p "$MODELS_DIR"; }
migrate_models() {  # плоский models/ (v1/v2) → подкаталоги-сеты
  [ -d "$MODELS_BASE" ] || return 0
  local f moved=0
  for f in "$MODELS_BASE"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
      *flash-next*) mkdir -p "$MODELS_BASE/flash"; mv "$f" "$MODELS_BASE/flash/"; moved=1 ;;
      *)            mkdir -p "$MODELS_BASE/27b";   mv "$f" "$MODELS_BASE/27b/";   moved=1 ;;
    esac
  done
  [ "$moved" = 1 ] && log "миграция моделей: разложены по сетам (27b/, flash/) — маунт видит только сет активного профиля"
  return 0
}
