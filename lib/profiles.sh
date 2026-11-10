# shellcheck shell=bash
# ── профили ─────────────────────────────────────────────────────────────────
# Формат: default_model|all_models (пробел)|draft_tag ('-' = нет)|min_ram_gib|описание
# Канонические id — spec/hfctl.md §5.
PROFILE_LIST="27b-single 27b-slots flash-multi"
profile_27b_single="qwen3.8:27b-mq4-xts|qwen3.8:27b-mq4-xts qwen3.8:27b-mq6-xt|qwen3.8:27b-draft-mq4|58|singleton+DFlash (максимум соло-скорости)"
profile_27b_slots="qwen3.8:27b-mq4-xts|qwen3.8:27b-mq4-xts qwen3.8:27b-mq6-xt|qwen3.8:27b-draft-mq4|58|multi_slot ${SLOTS}×${MAX_SEQ} (HOL-изоляция; −25% агрегат)"
profile_flash_multi="qwen3.8:flash-next-mq4-xts|qwen3.8:flash-next-mq4-xts|-|80|Flash-Next mq4-xts, VMM fn-lanes (настоящий батчинг; требует ≥80 GiB пула)"
PROFILE_DEFAULT=27b-single
# порог RAM-гейта flash проверяется по field 4; 80 = 72 (мин. реестра) + запас
# (lane store + OS); калибруется на 128 GB-машине (spec/plan.md этап 4).

profile_field() {  # profile_field <id> <N> — N-е поле профиля (1-based, '|')
  local name="profile_$(echo "$1" | tr '-' '_')" v
  v="${!name:-}"
  [ -n "$v" ] || return 1
  echo "$v" | cut -d'|' -f"$2"
}
resolve_profile() {  # нормализация алиасов → канонический id; 1 если неизвестно
  case "$1" in
    27b-single|single|mq6|mq4) echo 27b-single ;;
    27b-slots|slots)           echo 27b-slots ;;
    flash-multi|flash|flash-next|multi) echo flash-multi ;;
    *) return 1 ;;
  esac
}

# ── гейты профиля (spec §6): отказ ДО скачивания, с цифрами ─────────────────
ram_pool_gib() {  # весь доступный пул (APU: MemTotal; iGPU делит LPDDR с ОС)
  awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo
}
profile_gate() {  # profile_gate <id> — RAM-гейт; die с цифрами при отказе
  local prof="$1" need have
  if [ "${HFCTL_FORCE:-}" = 1 ] || [ "${FORCE_GATE:-}" = 1 ]; then
    need=$(profile_field "$prof" 4); have=$(ram_pool_gib)
    [ "$have" -ge "$need" ] || warn "--force: RAM-гейт обойдён (нужно ≥${need} GiB, есть ${have}) — движок может отказать в загрузке"
    return 0
  fi
  need=$(profile_field "$prof" 4); have=$(ram_pool_gib)
  [ "$have" -ge "$need" ] || {
    echo "ERROR: профиль $prof требует ≥${need} GiB единого пула памяти" >&2
    case "$prof" in
      flash-multi) echo "       (flash-next mq4-xts: 70.9 GB резидентно целиком;" >&2
                    echo "        offload на APU не добавляет ёмкости — это та же память;" >&2
                    echo "        + lane store для батчинга)" >&2 ;;
    esac
    echo "       На этой машине: ${have} GiB. Доступные профили: $(profile_avail_list)" >&2
    exit 1
  }
}
# какие профили проходят RAM-гейт на этой машине (для текстов отказа и doctor)
profile_avail_list() {
  local p out=""
  for p in $PROFILE_LIST; do
    [ "$(ram_pool_gib)" -ge "$(profile_field "$p" 4)" ] && out="$out $p"
  done
  echo "${out:-—}"
}
