# shellcheck shell=bash
# ── профили ─────────────────────────────────────────────────────────────────
# Формат: default_model|all_models (пробел)|draft_tag ('-' = нет)|min_ram_gib|описание
# Канонические id — spec/hfctl.md §5.
#
# @typedef profile_id: '27b-single' | '27b-slots' | 'flash-multi'

PROFILE_LIST="27b-single 27b-slots flash-multi"
profile_27b_single="qwen3.8:27b-mq4-xts|qwen3.8:27b-mq4-xts qwen3.8:27b-mq6-xt|qwen3.8:27b-draft-mq4|58|singleton+DFlash (максимум соло-скорости)"
profile_27b_slots="qwen3.8:27b-mq4-xts|qwen3.8:27b-mq4-xts qwen3.8:27b-mq6-xt|qwen3.8:27b-draft-mq4|58|multi_slot ${SLOTS}×${MAX_SEQ} (HOL-изоляция; −25% агрегат)"
profile_flash_multi="qwen3.8:flash-next-mq4-xts|qwen3.8:flash-next-mq4-xts|-|80|Flash-Next mq4-xts, VMM fn-lanes (настоящий батчинг; требует ≥80 GiB пула)"
# @type profile_id PROFILE_DEFAULT=27b-single
PROFILE_DEFAULT=27b-single
# порог RAM-гейта flash проверяется по field 4; 80 = 72 (мин. реестра) + запас
# (lane store + OS); калибруется на 128 GB-машине (spec/plan.md этап 4).

# Назначение: N-е поле (1-based, разделитель '|') записи профиля из таблицы
#   шапки файла: 1 — модель по умолчанию, 2 — все модели сета (через пробел),
#   3 — draft-sidecar ('-' = нет), 4 — порог RAM-гейта в целых GiB,
#   5 — описание для логов.
#
# Побочные эффекты: только печать поля в stdout; подпроцессы tr и cut;
#   таблица profile_* читается indirect-раскрытием ${!name} (имя: profile_
#   с id, дефисы заменены подчёркиваниями), файлов и глобалов не меняет.
#
# Ограничения/допущения: id берётся КАК ЕСТЬ — алиасы не распознаются
#   (нормализация resolve_profile на вызывающем; живые вызовы передают
#   канон: из commands.sh после resolve_profile, из stack_files.sh —
#   cur_profile из .env). Требует таблицу профилей этого файла; у строки
#   27b-slots поле 5 интерполировано из глобалов SLOTS и MAX_SEQ в момент
#   source диспетчером. Номер поля не валидируется: N за числом полей даёт
#   пустую строку при rc 0 (cut), нечисловой N — ошибку cut.
#
# @param 1: profile_id     # канонический id профиля (алиас → rc 1, см. Ограничения)
# @param 2: /^[1-5]$/      # номер поля таблицы (живые вызовы: 1–5)
# @stdout string           # значение поля (пустая строка при N за числом полей)
# @returns integer         # 0 — поле напечатано; 1 — неизвестный профиль (stdout пуст)
profile_field() {
  local name="profile_$(echo "$1" | tr '-' '_')" v
  v="${!name:-}"
  [ -n "$v" ] || return 1
  echo "$v" | cut -d'|' -f"$2"
}

# Назначение: нормализовать алиас профиля в канонический id: single|mq6|mq4 →
#   27b-single; slots → 27b-slots; flash|flash-next|multi → flash-multi;
#   канонические id проходят как есть (распознаны ровно 10 значений case).
#
# Побочные эффекты: только печать id в stdout; файлов, глобалов и env не
#   касается.
#
# Ограничения/допущения: аргумент — строка как есть (живые вызовы передают
#   пользовательский ввод install --profile / use / pull); нераспознанное
#   значение отклоняется rc 1 без вывода, текст отказа — на вызывающем
#   (die с PROFILE_LIST).
#
# @param 1: string          # алиас или канонический id (арбитражный ввод пользователя)
# @stdout profile_id        # канонический id (только при rc 0)
# @returns integer          # 0 — канон напечатан; 1 — неизвестное значение (stdout пуст)
resolve_profile() {
  case "$1" in
    27b-single|single|mq6|mq4) echo 27b-single ;;
    27b-slots|slots)           echo 27b-slots ;;
    flash-multi|flash|flash-next|multi) echo flash-multi ;;
    *) return 1 ;;
  esac
}

# ── гейты профиля (spec §6): отказ ДО скачивания, с цифрами ─────────────────

# Назначение: весь доступный пул памяти машины в целых GiB — MemTotal из
#   /proc/meminfo (APU: iGPU делит LPDDR с ОС, поэтому RAM-гейт смотрит
#   MemTotal, а не MemAvailable).
#
# Побочные эффекты: только печать числа в stdout; читает /proc/meminfo;
#   ничего не меняет.
#
# Ограничения/допущения: без параметров; округление вниз (awk printf "%d");
#   отсутствие MemTotal в файле даёт пустой stdout (не частный случай наших
#   Linux-машин).
#
# @stdout integer           # целые GiB всего пула (MemTotal/1048576, вниз)
# @returns integer          # rc awk — 0 и при пустом выводе (совпадения нет)
ram_pool_gib() {
  awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo
}

# Назначение: RAM-гейт профиля (spec §6) — отказ ДО любого скачивания, если
#   целый пул машины (ram_pool_gib) меньше порога из поля 4 таблицы профилей.
#
# Побочные эффекты: читает env-флаги HFCTL_FORCE и FORCE_GATE ('1' — обход);
#   при обходе — warn() в stderr с цифрами порога и фактического пула; при
#   отказе — ERROR-строки в stderr (для flash-multi — пояснение про
#   резидентные 70.9 GB и список проходящих гейт профилей) и exit 1 —
#   завершение всего процесса диспетчера. Файлы не меняет; читает
#   /proc/meminfo (через ram_pool_gib).
#
# Ограничения/допущения: prof — канонический id (живые вызовы cmd_install и
#   cmd_use идут строго после resolve_profile). Требует таблицу профилей,
#   profile_avail_list и warn из диспетчера. Локалы prof/need/have одной
#   строкой: prof — аргумент, need — порог поля 4, have — пул машины,
#   оба целые GiB.
#
# @param 1: profile_id      # канонический id профиля (гейт проверяет его порог — поле 4)
# @returns integer          # всегда 0 при возврате (в т.ч. обход по force) —
#   отказ завершает процесс exit 1, вызывающий его не перехватит
profile_gate() {
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

# Назначение: какие профили проходят RAM-гейт на этой машине (для текстов
#   отказа profile_gate и диагностики doctor).
#
# Побочные эффекты: только печать строки в stdout; читает PROFILE_LIST и
#   таблицу профилей, по одному разу на профиль читает /proc/meminfo
#   (ram_pool_gib).
#
# Ограничения/допущения: без параметров; тот же порог (поле 4), что у
#   profile_gate, но без учёта force-обхода; локалы p/out одной строкой:
#   p — перебор PROFILE_LIST (пробел-разделённый), out — накапливаемый
#   список.
#
# @stdout string            # канонические id через пробел, прошедшие гейт; '—' если ни одного
# @returns integer          # всегда 0 — финальный echo
profile_avail_list() {
  local p out=""
  for p in $PROFILE_LIST; do
    [ "$(ram_pool_gib)" -ge "$(profile_field "$p" 4)" ] && out="$out $p"
  done
  echo "${out:-—}"
}
