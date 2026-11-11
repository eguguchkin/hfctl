# shellcheck shell=bash
# ── state-каталоги по профилям (этап 7: явные bind вместо named volumes) ────
# config/ → /home/hipfire/.hipfire, kernel/ → /var/cache/hipfire.
# disk-тир контекст-кэша (session-cache/) живёт внутри config/ → per-профиль
# автоматически; RAM-тир так и был per-процесс (умирает при recreate).

# @typedef profile_id: '27b-single' | '27b-slots' | 'flash-multi'

# Назначение: каталог state-состояния профиля — $STATE_BASE/<profile_id>
#   (внутри config/ и kernel/).
#
# Побочные эффекты: только печать пути в stdout; каталог не создаёт, файлов
#   не касается.
#
# Ограничения/допущения: требует глобал STATE_BASE (диспетчер); аргумент не
#   валидируется — путь конкатенацией, нормализация (resolve_profile) на
#   совести вызывающего; подобные пути строятся и напрямую ($STATE_BASE/$prof
#   в stack_files.sh, $STATE_BASE/$(cur_profile) в commands.sh) — функция
#   служит для единого вида log-строк миграции.
#
# @param 1: profile_id # канонический id профиля (живые вызовы — из migrate_state)
# @stdout string       # путь каталога профиля ($STATE_BASE/<id>) — mkdir НЕ делает
state_dir() { echo "$STATE_BASE/$1"; }

# Назначение: одноразовая идемпотентная миграция legacy named volumes
#   (hipfire_hipfire-config / hipfire_hipfire-kernels) в state-каталоги
#   профиля profiles/<profile_id>/{config,kernel} — этап 7, bind вместо
#   volumes.
#
# Побочные эффекты: создаёт $STATE_BASE/<profile_id>/{config,kernel}; при
#   живом legacy-вольюме и ПУСТОМ целевом каталоге — cp -a всего _data (у
#   юзера в disk-тире могут быть гигабайты); log-строки в stdout; подпроцессы
#   podman volume inspect (volumes только читаются, не меняются).
#
# Ограничения/допущения: требует глобалы STATE_BASE и log (диспетчер).
#   Неизвестный id НЕ отклоняется — под него просто создаётся каталог.
#   Отсутствие вольюма — норма: inspect заглушён «|| true», пустой vdata
#   пропускает копию; повторный запуск на непустом целевом каталоге — no-op.
#
# @param 1: profile_id # канонический id профиля (нормализация resolve_profile на вызывающем)
# @returns integer     # всегда 0 — отсутствие legacy-вольюмов штатно заглушено; сбой mkdir убивает set -e
migrate_state() {
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

# Назначение: имя каталога-сета моделей для профиля — изоляция профилей:
#   сервер монтирует только свой сет (чужая модель → 404, не молчаливый swap).
#
# Побочные эффекты: только печать имени сета в stdout; файлов не касается.
#
# Ограничения/допущения: глобалов не требует; НЕизвестный id уходит в
#   default-ветку case (сет 27b).
#
# @param 1: profile_id      # id профиля (неизвестный → сет 27b)
# @stdout '27b' | 'flash'   # имя подкаталога-сета в $MODELS_BASE
model_set() { case "$1" in flash-multi) echo flash ;; *) echo 27b ;; esac; }

# Назначение: перенаправить глобал MODELS_DIR (bind-маунт моделей) на каталог
#   сета профиля и создать этот каталог.
#
# Побочные эффекты: перезаписывает глобал MODELS_DIR (объявлен в диспетчере;
#   install/use переустанавливают его через эту же функцию, cmd_pull — прямым
#   env-префиксом); mkdir -p каталога сета в $MODELS_BASE; в stdout не
#   печатает ничего.
#
# Ограничения/допущения: требует глобал MODELS_BASE; id профиля берётся как
#   есть (resolve_profile — на вызывающем; НЕизвестный id даёт сет 27b через
#   default-ветку model_set).
#
# @param 1: profile_id # канонический id профиля
# @returns integer     # всегда 0 при возврате — штатный mkdir; его сбой завершает процесс (set -e)
set_models_dir() { MODELS_DIR="$MODELS_BASE/$(model_set "$1")"; mkdir -p "$MODELS_DIR"; }

# Назначение: одноразовая миграция плоского каталога моделей (v1/v2) в
#   подкаталоги-сеты: файлы с «flash-next» в имени → flash/, прочие → 27b/.
#
# Побочные эффекты: mv файлов верхнего уровня $MODELS_BASE в подкаталоги
#   сетов + mkdir этих подкаталогов; log-строка в stdout, если что-то
#   сдвинуто.
#
# Ограничения/допущения: требует глобал MODELS_BASE; нет каталога-базы —
#   немедленный no-op. Сдвигаются только regular-файлы верхнего уровня
#   ([ -f ]) — подкаталоги не трогаются; идемпотентна (после раскладки
#   файлов верхнего уровня не остаётся).
#
# @returns integer # всегда 0 — явный return 0 (в т.ч. no-op без базы и без перемещений)
migrate_models() {
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
