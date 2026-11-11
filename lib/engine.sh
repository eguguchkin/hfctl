# shellcheck shell=bash
# ── конфиг движка (volume через compose run — volume проектов гарантированно) ─

# Назначение: записать один ключ конфига движка в config-каталог активного
#   профиля — one-shot `compose run` (движок может быть выключен).
#
# Побочные эффекты: подпроцесс podman (одноразовый контейнер пишет config.toml
#   в bind-каталог активного профиля из compose-файлов $STACK_DIR; образ
#   подтягивается при отсутствии); в stdout — последняя строка вывода
#   `config set` (stderr слит в stdout).
#
# Ограничения/допущения: требуются глобалы compose и STACK_DIR (lib/stack.sh)
#   и канон compose-файлов CF; профиль берётся из текущего стека (HFCTL_PROFILE
#   в .env), т.е. до смены профиля запись идёт в прежний state-каталог; ключ и
#   значение здесь НЕ валидируются — отказ движка виден только текстом в
#   выводе, а из-за `|| true` возврат всегда 0 (вызывающему ошибка не видна);
#   stdin закрыт (/dev/null) — интерактивных запросов нет.
#
# @param 1: /^\w+(\.\w+)+$/                             # ключ конфига движка (точечный: memory.max_seq, serve.multi_slot)
# @param 2: /\d+/ | 'on' | 'off' | 'true' | 'false'     # значение: целое или булев литерал
# @returns integer                                      # всегда 0 — отказ движка заглушён `|| true`
cfgset() {
  compose run --rm --no-deps hipfire hipfire config set "$1" "$2" </dev/null 2>&1 | tail -1 || true
}

# Назначение: применить полный набор ключей движка выбранного профиля
#   (спекуляция/батчинг/кэш) к активному стеку — через cfgset.
#
# Побочные эффекты: последовательные cfgset (10–12 подпроцессов podman
#   one-shot) с записью в config-каталог активного профиля; log-строка (с
#   описанием профиля из поля 5 таблицы профилей) и хвосты вывода cfgset
#   в stdout.
#
# Ограничения/допущения: prof — канонический id (нормализация resolve_profile
#   на совести вызывающего); НЕизвестный id НЕ отклоняется — молча применяется
#   ветка 27b-single (default в case), а описание в логе остаётся пустым.
#   Требует глобалов MAX_SEQ и SLOTS (диспетчер; SLOTS участвует только в
#   ветке 27b-slots), compose/STACK_DIR и profiles.sh; вызывается между
#   `compose up -d` и `--force-recreate` (commands.sh) — после применения
#   обязателен recreate, движок на лету конфиг не перечитывает.
#
# @param 1: '27b-single' | '27b-slots' | 'flash-multi'   # канонический id профиля (неизвестный → ветка 27b-single)
# @returns integer                                       # всегда 0 — cfgset не возвращает отказ
apply_profile() {
  local prof="$1"
  log "профиль движка: $prof ($(profile_field "$prof" 5))"
  cfgset memory.max_seq "$MAX_SEQ"
  cfgset memory.session_cache_disk_bytes 34359738368
  cfgset serve.idle_timeout_seconds 0   # модель резидентна: грузится при старте (pre-warm), не выгружается при простое
  case "$prof" in
    27b-slots)
      cfgset speculation.dflash on
      cfgset serve.multi_slot true
      cfgset serve.multi_slot_slots "$SLOTS"
      cfgset serve.multi_slot_ctx "$MAX_SEQ"
      cfgset serve.continuous_batch_size 1
      cfgset serve.vmm_batch false
      cfgset serve.batch_nonexact false
      ;;
    flash-multi)
      # VMM continuous batching (fn-lanes, Qwen4): spec/hfctl.md §5.
      # При отказе lanes движок сам печатает 'qwen4 lanes refused: … —
      # fallback to sequential' и живёт serial (проверка в check_route).
      cfgset speculation.dflash off          # у flash native MTP; роут решает движок
      cfgset serve.multi_slot false
      cfgset serve.multi_slot_slots 2
      cfgset serve.multi_slot_ctx "$MAX_SEQ"
      cfgset serve.continuous_batch_size 4
      cfgset serve.vmm_batch true
      cfgset serve.batch_sampled true
      cfgset serve.batch_nonexact false      # ВАЖНО: qwen4 lanes живут ТОЛЬКО на
      # Exact-роуте (batch_staging.rs:569: Nonexact → refuse 'only the exact
      # lane route'). Ключ наследуется от 27b-single (там true) — если не
      # сбросить явно, flash молча теряет lanes → serial. Корень «lanes-загадки»
      # 2026-11-09: не moving tag, а leftover nonexact=true от 27b-single.
      cfgset memory.session_cache_bytes 12884901888  # 12 GiB: полный 262K-снапшот 8.78 GiB + запас (Э-3 §4.2)
      ;;
    *)  # 27b-single (default)
      cfgset speculation.dflash on
      cfgset serve.multi_slot false
      cfgset serve.multi_slot_slots 4
      cfgset serve.multi_slot_ctx "$MAX_SEQ"
      cfgset serve.continuous_batch_size 4
      cfgset serve.vmm_batch true
      cfgset serve.batch_nonexact true
      cfgset memory.session_cache_bytes 0   # Qwen3.5: engine-session cache не работает (disk tier инертен) — 0 экономит 8 GiB GPU-RAM
      ;;
  esac
}
