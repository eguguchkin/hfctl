# shellcheck shell=bash
# ── конфиг движка (volume через compose run — volume проектов гарантированно) ─
cfgset() {  # cfgset <key> <value>
  compose run --rm --no-deps hipfire hipfire config set "$1" "$2" </dev/null 2>&1 | tail -1 || true
}
apply_profile() {  # apply_profile <id> — ключи движка из таблицы профилей
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
