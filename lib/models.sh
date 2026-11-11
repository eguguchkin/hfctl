# shellcheck shell=bash
# ── вытягивание моделей ──────────────────────────────────────────────────────
# Модуль не определяет собственных глобалов; читает IMAGE и MODELS_DIR и
# пишет лог через log() — всё объявлено в диспетчере hfctl до source этого
# файла. Профильные данные берёт из profile_field (lib/profiles.sh).
# Вызывается из commands.sh (install / use / смена сета моделей).

# Назначение: вытянуть одну модель (или draft-sidecar) из реестра hipfire в
#   $MODELS_DIR — идемпотентно: sha256-верификация внутри `hipfire pull`.
#
# Побочные эффекты: файлы в $MODELS_DIR (bind-маунт контейнерного home
#   моделей); подпроцесс podman + сеть (образ подтягивается при отсутствии);
#   в stdout — log-строка и последние 2 строки вывода pull (stderr слит в
#   stdout); глобалы и состояние стека не меняет.
#
# Ограничения/допущения: требуются глобалы IMAGE и MODELS_DIR (значения могут
#   передаваться env-префиксом вызывающего: `MODELS_DIR=… pull_model …`) и
#   podman; валидность тега НЕ проверяется — неизвестный тег отклоняет реестр
#   ненулевым возвратом; из-за `set -o pipefail` в диспетчере отказ pull'а
#   сохраняется сквозь конвейер с tail.
#
# @param 1: /^[\w.-]+:[\w.-]+$/    # тег реестра: модель либо draft-sidecar
# @returns integer                 # 0 — модель на месте (или уже была); ненулевой — отказ podman/pull
pull_model() {
  local tag="$1"
  log "тяну модель $tag"
  podman run --rm -v "$MODELS_DIR:/home/hipfire/.hipfire/models" "$IMAGE" \
    hipfire pull "$tag" --yes 2>&1 | tail -2
}

# Назначение: вытянуть весь набор моделей профиля (поле 2 реестра профилей)
#   и его draft-sidecar (поле 3), если профиль его объявляет.
#
# Побочные эффекты: гарантирует локальное наличие образа IMAGE (`podman pull`,
#   повтор при первом сбое); через pull_model — файлы в $MODELS_DIR и подтяжка
#   моделей по сети; log-строки и хвосты вывода pull в stdout.
#
# Ограничения/допущения: prof — канонический id (нормализация resolve_profile
#   на совести вызывающего: неизвестный id → profile_field вернёт 1, и `set -e`
#   оборвёт команду); требует profiles.sh и глобалов IMAGE/MODELS_DIR; RAM-гейт
#   (profile_gate) здесь НЕ проверяется — это шаг вызывающего до скачивания;
#   «-» или пустое поле 3 означает профиль без draft и молча пропускается.
#
# @param 1: '27b-single' | '27b-slots' | 'flash-multi'   # канонический id профиля
# @returns integer                                       # 0 — весь набор и draft на месте; ненулевой — сбой profile_field или любого pull_model (set -e)
pull_profile_models() {
  local prof="$1" tag draft
  podman image exists "$IMAGE" || podman pull "$IMAGE" >/dev/null || podman pull "$IMAGE"
  for tag in $(profile_field "$prof" 2); do
    pull_model "$tag"
  done
  draft=$(profile_field "$prof" 3)
  [ "$draft" != "-" ] && [ -n "$draft" ] && pull_model "$draft" || true
}
