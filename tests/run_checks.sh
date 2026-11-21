#!/usr/bin/env bash
# run_checks.sh — internal-check батарея сабстэджа 13.1 (самолечение аномалий,
# фиксы Ф1–Ф5) + 13.2 (preflight: apt-пятёрка + GPU-подготовка, P-A…P-H) +
# AGENTS-четыре. Прецеденты: gfctl tests/run_checks.sh (faux-bin
# PATH-заглушки с журналом вызовов, harness-субшелл «глобалы диспетчера +
# source lib + faux-PATH + eval») и .dev/tasks/defects/boot-device-mismatch/
# selfcheck.sh (GPU-гейт через env-крючки шапки autostart.sh).
#
# Назначение: одним вызовом — синтаксис, py_compile, usage-контракт, статусный
#   отказ на чанковом порту; на КАЖДЫЙ фикс — позитив-сценарий и мутационная
#   проверка («вырежи строки с маркером # fix:<имя> на КОПИИ дерева → сценарий
#   обязан ПАДАТЬ»; маркер не найден → FAIL «мутация не применилась», защита
#   от дрейфа маркеров). Счёт PASS/FAIL; rc 0 только при FAIL=0.
#
# Побочные эффекты: только временный каталог mktemp (удаляется по EXIT) с
#   копиями дерева для мутантов. Реальных podman/systemctl/sudo/машин нет —
#   всё через faux-PATH; HOME/USER — в $TMP. Ф3 гоняется с НАСТОЯЩИМИ
#   flock/ps/fuser (семантику блокировок даёт ядро): holder — python3-процесс
#   с argv0 «podman-compose» (busybox flock контейнера не умеет fd+command
#   форму утилитового; python держит настоящий flock на lock-файле).
#
# Ограничения/допущения: bash + python3 в PATH; /dev/kfd и /dev/dri здесь не
#   нужны (up-пути батареи зовутся напрямую, GPU-гейт только в _boot; P-сценарии
#   13.2 хукают их через HFCTL_KFD/HFCTL_DRI). Среда песочницы — Alpine, а
#   preflight требует ubuntu|debian из /etc/os-release: батарея (кроме
#   AGENTS-четырёх на реальном пути) перезапускает себя под `unshare -rm` с
#   bind-подменой /etc/os-release на фейк ID=ubuntu — только внутри своего
#   namespace, реальный /etc не трогается; если userns недоступен, батарея
#   идёт без подмены и P-сценарии честно падают на os-чеке.
#   Запуск из любого каталога. exit-код = вердикт.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# ре-exec под user+mount namespace (см. Ограничения): до создания $TMP, без хвостов
if [ "${HF_CHECKS_UNSHARED:-0}" != 1 ] && command -v unshare >/dev/null 2>&1 \
   && command -v mount >/dev/null 2>&1 && unshare -rm true 2>/dev/null; then
  exec unshare -rm env HF_CHECKS_UNSHARED=1 bash "$0" "$@"
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hfctl-checks.XXXXXX")" || { echo "run_checks: mktemp недоступен" >&2; exit 1; }
trap '[ -n "${TMP:-}" ] && rm -rf "$TMP"' EXIT
# подмена /etc/os-release внутри namespace (продукт читает абсолютный путь)
if [ "${HF_CHECKS_UNSHARED:-0}" = 1 ]; then
  printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$TMP/fake-os-release"
  mount -o bind "$TMP/fake-os-release" /etc/os-release 2>/dev/null || true
fi
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; }
unset CONTAINERS_CONF || true   # env-гигиена: сценарий «файла нет → env чист»

ORPHAN_ID="dccea132feedbeef00112233445566778899aabbccddeeff00112233445566"

# ── faux-bin: PATH-заглушки внешних бинарей ──────────────────────────────────
# Каждая пишет в $HFCTL_FAUX_LOG построчно «<cmd> <args…>» и сценарится env-
# флагами HFCTL_FAUX_*; ролей не делают (никаких реальных podman/systemd/
# loginctl/sudo — hygiene AGENTS). Сценарии:
#   podman  — на каждый вызов в журнал ещё и «env CONTAINERS_CONF=<v|UNSET>»
#             (ассерт Ф5); compose up: HFCTL_FAUX_UP=ok | orphan-once (первый
#             up печатает ошибку сироты с HFCTL_FAUX_ORPHAN_ID, rc 1; дальше
#             rc 0) | orphan-always; счётчики up в файлах $HFCTL_FAUX_CNT.up /
#             .upok; inspect: последний аргумент-цель — hipfire_* контейнер
#             (running после первого успешного up, иначе rc 1) либо hex-ID
#             guard'а сироты (HFCTL_FAUX_INSPECT_ID=running → rc 0);
#             pod inspect → HFCTL_FAUX_POD_INFRA=absent(rc 1, дефолт) |
#             empty(rc 0, пусто) | full(rc 0, ID); pod rm / ps / rm / stop rc 0;
#             compose stop — HFCTL_FAUX_STOPFAIL=1 → rc 1 с ошибкой.
#   containers-storage — журналирует delete-container <ID>; HFCTL_FAUX_CS_FAIL=1
#             → rc 1; отсутствие бинаря = не класть в PATH (FAUX_NS).
#   systemctl/loginctl/sudo — журналирование, rc 0, ничего реального.
FAUX="$TMP/faux"; mkdir -p "$FAUX"
FAUXLOG="$TMP/faux.log"; FAUXCNT="$TMP/faux.cnt"
: > "$FAUXLOG"
cat > "$FAUX/podman" <<'EOF'
#!/usr/bin/env bash
set -u
L="${HFCTL_FAUX_LOG:?}"
{ printf 'podman'; printf ' %s' "$@"; printf '\n'; } >> "$L"
printf 'env CONTAINERS_CONF=%s\n' "${CONTAINERS_CONF-UNSET}" >> "$L"
CNT="${HFCTL_FAUX_CNT:?}"
case "$1" in
  compose)
    shift; sub=""; skip=0
    for a in "$@"; do
      [ "$skip" = 1 ] && { skip=0; continue; }
      case "$a" in -f) skip=1 ;; *) [ -z "$sub" ] && sub="$a" ;; esac
    done
    case "$sub" in
      up)
        n=$(cat "$CNT.up" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$CNT.up"
        case "${HFCTL_FAUX_UP:-ok}" in
          ok) : ;;
          orphan-once) [ "$n" = 1 ] || { echo "pretend up ok"; k=$(cat "$CNT.upok" 2>/dev/null || echo 0); echo "$((k + 1))" > "$CNT.upok"; exit 0; } ;;
          orphan-always) : ;;
        esac
        if [ "${HFCTL_FAUX_UP:-ok}" != ok ] && { [ "${HFCTL_FAUX_UP}" = orphan-always ] || [ "$n" = 1 ]; }; then
          printf 'Error: creating container storage: the container name "hipfire_hipfire-init_1" is already in use by %s … external entity\n' "${HFCTL_FAUX_ORPHAN_ID:?}"
          exit 1
        fi
        k=$(cat "$CNT.upok" 2>/dev/null || echo 0); echo "$((k + 1))" > "$CNT.upok"
        echo "pretend up ok"; exit 0 ;;
      stop)
        if [ "${HFCTL_FAUX_STOPFAIL:-0}" = 1 ]; then
          echo "Error: fake compose stop failure (pasta: permission denied, signal to init container)"; exit 1
        fi
        echo "pretend stop ok"; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  inspect)
    t=""; for a in "$@"; do t="$a"; done   # последний аргумент — цель inspect
    case "$t" in
      *hipfire_*)
        # контейнер проекта: running после первого успешного up
        [ "$(cat "$CNT.upok" 2>/dev/null || echo 0)" -gt 0 ] && { echo running; exit 0; }
        exit 1 ;;
      *)
        # hex-ID (guard сироты): libpod «видит»/не видит
        [ "${HFCTL_FAUX_INSPECT_ID:-missing}" = running ] && { echo running; exit 0; }
        exit 1 ;;
    esac ;;
  pod)
    case "${2:-}" in
      inspect)
        case "${HFCTL_FAUX_POD_INFRA:-absent}" in
          empty) printf ''; exit 0 ;;
          full)  printf '%s\n' "${HFCTL_FAUX_ORPHAN_ID:?}"; exit 0 ;;
          *)     exit 1 ;;
        esac ;;
      rm) exit 0 ;;
      *) exit 0 ;;
    esac ;;
  ps) exit 0 ;;
  rm) exit 0 ;;
  stop) exit 0 ;;
esac
exit 0
EOF
cat > "$FAUX/containers-storage" <<'EOF'
#!/usr/bin/env bash
{ printf 'containers-storage'; printf ' %s' "$@"; printf '\n'; } >> "${HFCTL_FAUX_LOG:?}"
[ "${HFCTL_FAUX_CS_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF
for b in systemctl; do
cat > "$FAUX/$b" <<EOF
#!/usr/bin/env bash
{ printf '$b'; printf ' %s' "\$@"; printf '\n'; } >> "\${HFCTL_FAUX_LOG:?}"
exit 0
EOF
done
# loginctl: 13.2 — при HFCTL_FAUX_LINGER=1 печатает Linger=yes (ветка «linger
#   уже включён»), иначе пусто (ветка enable-linger preflight)
cat > "$FAUX/loginctl" <<'EOF'
#!/usr/bin/env bash
{ printf 'loginctl'; printf ' %s' "$@"; printf '\n'; } >> "${HFCTL_FAUX_LOG:?}"
[ "${HFCTL_FAUX_LINGER:-0}" = 1 ] && printf 'Linger=yes\n'
exit 0
EOF
# sudo: журнал + rc 0; форма install -m 0644 SRC DST — дополнительно РЕАЛЬНАЯ
#   копия install'ом в цель, только когда DST внутри $TMP (limits-ассерты P-E/P-F;
#   настоящих sudo-мутаций нет — HFCTL_LIMITS всегда хукается в $TMP)
cat > "$FAUX/sudo" <<'EOF'
#!/usr/bin/env bash
{ printf 'sudo'; printf ' %s' "$@"; printf '\n'; } >> "${HFCTL_FAUX_LOG:?}"
if [ "${1:-}" = install ] && [ "${2:-}" = -m ] && [ "${3:-}" = 0644 ]; then
  case "${5:-}" in "${HFCTL_FAUX_TMP:?}"/*) install -m 0644 "$4" "$5" ;; esac
fi
exit 0
EOF
# id/usermod: 13.2 — id -u → 1000 (root-чек preflight), id -nG → HFCTL_FAUX_GROUPS
#   (дефолт tester render video); usermod — журнал, rc 0
cat > "$FAUX/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -u)  echo 1000 ;;
  -nG) echo "${HFCTL_FAUX_GROUPS:-tester render video}" ;;
  *)   echo "uid=1000(tester) gid=1000(tester)" ;;
esac
EOF
cat > "$FAUX/usermod" <<'EOF'
#!/usr/bin/env bash
{ printf 'usermod'; printf ' %s' "$@"; printf '\n'; } >> "${HFCTL_FAUX_LOG:?}"
exit 0
EOF
chmod +x "$FAUX"/*
# FAUX_FULL: FAUX + faux podman-compose/fuser/curl — P-сценарии «всё на месте»
#   (podman-compose в контейнере реально отсутствует, fuser/curl здесь — faux
#   для детерминизма; на Ф3 не влияет: там используется $FAUX или $NOFU)
FAUX_FULL="$TMP/faux-full"; mkdir -p "$FAUX_FULL"
for b in "$FAUX"/*; do ln -sf "$b" "$FAUX_FULL/$(basename "$b")"; done
cat > "$FAUX_FULL/podman-compose" <<'EOF'
#!/usr/bin/env bash
{ printf 'podman-compose'; printf ' %s' "$@"; printf '\n'; } >> "${HFCTL_FAUX_LOG:?}"
exit 0
EOF
for b in fuser curl; do
cat > "$FAUX_FULL/$b" <<EOF
#!/usr/bin/env bash
{ printf '$b'; printf ' %s' "\$@"; printf '\n'; } >> "\${HFCTL_FAUX_LOG:?}"
exit 0
EOF
done
chmod +x "$FAUX_FULL"/*
# STRIPPED: базовые утилиты + mktemp/cmp/install БЕЗ podman/podman-compose/
#   containers-storage/fuser/curl — P-A «всё отсутствует» (apt-пятёрка целиком);
#   faux id/loginctl/sudo/usermod — журналирующие заглушки 13.2
STRIPPED="$TMP/faux-stripped"; mkdir -p "$STRIPPED"
for b in bash python3 flock ps tail grep awk sed head cat cut date sleep touch mkdir rm ls env mktemp cmp install; do
  src=$(command -v "$b" 2>/dev/null) && ln -sf "$src" "$STRIPPED/$b"
done
for b in id usermod loginctl sudo; do ln -sf "$FAUX/$b" "$STRIPPED/$b"; done
# существующие пути-цели для HFCTL_KFD/HFCTL_DRI (гейт gpu_prep: [ -e ])
: > "$TMP/kfd-node"; : > "$TMP/dri-node"
# FAUX_NS: то же БЕЗ containers-storage (сценарий «бинаря нет», Variant B;
# настоящий containers-storage в контейнере отсутствует — проверено эмпирически)
FAUX_NS="$TMP/faux-nostor"; mkdir -p "$FAUX_NS"
for b in podman systemctl loginctl sudo; do ln -sf "$FAUX/$b" "$FAUX_NS/$b"; done
# NOFU: строгий PATH без fuser/lsof и без системного (сценарий «нет fuser» —
# тихая деградация); holder Ф3 и up-путь должны работать этим набором
NOFU="$TMP/faux-nofu"; mkdir -p "$NOFU"
for b in bash python3 flock ps tail grep awk sed head cat date sleep touch mkdir rm ls env; do
  src=$(command -v "$b" 2>/dev/null) && ln -sf "$src" "$NOFU/$b"
done
ln -sf "$FAUX/podman" "$NOFU/podman"

# ── hf — harness: субшелл с глобалами диспетчера + source lib + faux-PATH ────
# (прецедент gfctl; дерево под тестом — HF_TREE, по умолчанию репо).
HF_STACK="$TMP/stack"
hf() {  # hf <bash-код> — stdout+stderr и rc наружу
  local tree="${HF_TREE:-$ROOT}"
  (
    set -euo pipefail
    export PATH="${HF_PATH:-$FAUX:$PATH}"
    export HFCTL_FAUX_LOG="$FAUXLOG" HFCTL_FAUX_CNT="$FAUXCNT" HFCTL_FAUX_ORPHAN_ID="$ORPHAN_ID"
    export HOME="$TMP/home" USER="tester" HFCTL_FAUX_TMP="$TMP"
    IMAGE="ghcr.io/warpfront/hipfire:0.4.7"
    STACK_DIR="$HF_STACK" MODELS_BASE="$HF_STACK/models" MODELS_DIR="$HF_STACK/models/27b"
    STATE_BASE="$HF_STACK/profiles" PORT=11435 BIND="0.0.0.0" SLOTS=2 MAX_SEQ=262144 MEMLOCK="${HF_MEMLOCK:-1318060032}"
    DRAFT_FILE="/home/hipfire/.hipfire/models/qwen38-27b-dflash-mq4.hfq"
    STOP_MARKER="$HF_STACK/.hfctl-stopped"
    CONTAINER="hipfire_hipfire_1" UNIT_NAME="hipfire-compose"
    ASSUME_YES=1 SELF="$tree/hfctl" LIB_DIR="$tree/lib" TPL_DIR="$tree/tpl"
    log()  { printf '\n== %s\n' "$*"; }
    warn() { printf 'WARN: %s\n' "$*" >&2; }
    die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
    ask()  { return 0; }
    isint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
    source "$LIB_DIR/profiles.sh"
    source "$LIB_DIR/stack.sh"
    source "$LIB_DIR/stack_files.sh"
    source "$LIB_DIR/autostart.sh"
    eval "$1"
  )
}

# ── швы сценариев ────────────────────────────────────────────────────────────
new_stack() { HF_STACK="$TMP/stack-$1"; rm -rf "$HF_STACK"; mkdir -p "$HF_STACK"; }
fresh_log() { : > "$FAUXLOG"; rm -f "$FAUXCNT"* 2>/dev/null || true; }
ups_count()     { local n; n=$(grep -c 'up -d' "$FAUXLOG" 2>/dev/null); echo "${n:-0}"; }
deletes_count() { local n; n=$(grep -c 'containers-storage delete-container' "$FAUXLOG" 2>/dev/null); echo "${n:-0}"; }
is_dead() { local s; s="$(ps -o stat= -p "$1" 2>/dev/null)"; [ -z "$s" ] || [ "${s#*Z}" != "$s" ]; }

# holder Ф3: настоящий держатель flock — python3 с argv0 «podman-compose»
# (cmdline матчит предикат продукта; etimes настоящий; busybox flock этого
# контейнера не умеет «flock FD command», поэтому lock берёт сам python).
HOLDER_CODE='import fcntl,sys,time
f=open(sys.argv[1],"a+")
fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB)
sys.stderr.write("held\n")
time.sleep(600)'
spawn_holder() {  # spawn_holder <lock-path> — печатает pid holder'а
  ( exec -a podman-compose python3 -c "$HOLDER_CODE" "$1" ) >/dev/null 2>&1 &
  echo $!
}
lock_is_held() {  # lock_is_held <lock-path> — 0, если flock -n не может взять
  ( flock -n 9 ) 9>"$1" 2>/dev/null
  [ $? -ne 0 ]
}

limits_bytes() {  # limits_bytes <user> <memlock> — ожидаемые байты limits-файла
  printf '%s soft memlock %s\n%s hard memlock %s\n' "$1" "$2" "$1" "$2"
}

# ── сценарии позитивов (return 0 = все ассерты держатся) ─────────────────────

# Ф1: compose stop упал → podman stop основного контейнера всё равно вызван,
#     off дошёл до «ВЫКЛ…» с rc 0
scen_f1_fail() {
  new_stack f1fail; fresh_log
  local out rc
  out=$(HFCTL_FAUX_STOPFAIL=1 hf 'cmd_off' 2>&1); rc=$?
  grep -qF 'podman stop hipfire_hipfire_1' "$FAUXLOG" \
    && grep -qE 'compose .* stop' "$FAUXLOG" \
    && [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'ВЫКЛ'
}

# Ф1 happy: compose stop ok → podman stop тоже вызван (безвреден по контракту)
scen_f1_happy() {
  new_stack f1happy; fresh_log
  local out rc
  out=$(hf 'cmd_off' 2>&1); rc=$?
  grep -qF 'podman stop hipfire_hipfire_1' "$FAUXLOG" \
    && grep -qE 'compose .* stop' "$FAUXLOG" \
    && [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'ВЫКЛ'
}

# Ф2 locked: up#1 — ошибка сироты, хил удаляет ID, up#2 ок → rc 0, ровно 2 up
scen_f2_locked() {
  new_stack f2locked; fresh_log
  local out rc
  out=$(HFCTL_FAUX_UP=orphan-once hf 'hf_up_locked' 2>&1); rc=$?
  grep -qF "containers-storage delete-container $ORPHAN_ID" "$FAUXLOG" \
    && [ "$(ups_count)" = 2 ] && [ "$rc" = 0 ] \
    && printf '%s' "$out" | grep -q 'повторяю up'
}

# Ф2 devsafe: тот же сценарий через boot/watchdog-путь
scen_f2_devsafe() {
  new_stack f2devsafe; fresh_log
  local out rc
  out=$(HFCTL_FAUX_UP=orphan-once hf 'hf_up_devsafe' 2>&1); rc=$?
  grep -qF "containers-storage delete-container $ORPHAN_ID" "$FAUXLOG" \
    && [ "$(ups_count)" = 2 ] && [ "$rc" = 0 ]
}

# Ф2 happy: чистый up — ровно 1 вызов compose up, rc 0 (контракт без аномалий)
scen_up_happy() {
  new_stack uhappy; fresh_log
  local out rc
  out=$(hf 'hf_up_locked' 2>&1); rc=$?
  [ "$(ups_count)" = 1 ] && [ "$rc" = 0 ] && [ "$(deletes_count)" = 0 ]
}

# Ф2 кап: обе ошибки сироты при HEAL_MAX=1 → второй хил НЕ случается
scen_f2_cap() {
  new_stack f2cap; fresh_log
  local out rc
  out=$(HFCTL_HEAL_MAX=1 HFCTL_FAUX_UP=orphan-always hf 'hf_up_locked' 2>&1); rc=$?
  [ "$(deletes_count)" = 1 ] && [ "$(ups_count)" = 2 ] && [ "$rc" != 0 ]
}

# Ф2 бинаря нет: WARN с ручной командой, delete-container НЕ вызван, поведение
# как прежде (один up, rc 1)
scen_f2_nobin() {
  new_stack f2nobin; fresh_log
  local out rc
  out=$(HFCTL_FAUX_UP=orphan-once HF_PATH="$FAUX_NS:$PATH" hf 'hf_up_locked' 2>&1); rc=$?
  printf '%s' "$out" | grep -qF "containers-storage delete-container $ORPHAN_ID" \
    && [ "$(deletes_count)" = 0 ] && [ "$(ups_count)" = 1 ] && [ "$rc" != 0 ]
}

# Ф2 guard: ID видит libpod → не сирота, delete НЕ вызван
scen_f2_guard() {
  new_stack f2guard; fresh_log
  local out rc
  out=$(HFCTL_FAUX_UP=orphan-once HFCTL_FAUX_INSPECT_ID=running hf 'hf_up_locked' 2>&1); rc=$?
  printf '%s' "$out" | grep -q 'не сирота, самолечение отменено' \
    && [ "$(deletes_count)" = 0 ] && [ "$(ups_count)" = 1 ]
}

# Ф3 stale: зависший держатель (argv0 podman-compose, возраст > порога) убит,
# up прошёл, «пропуска» нет
scen_f3_stale() {
  new_stack f3stale; fresh_log
  local lock="$HF_STACK/.hfctl.lock" hp out rc
  hp=$(spawn_holder "$lock")
  sleep 2
  is_dead "$hp" && { echo "holder не дожил до сценария"; return 1; }
  lock_is_held "$lock" || { echo "holder не держит лок (сценарий пустой)"; return 1; }
  out=$(HFCTL_LOCK_STALE=1 hf 'hf_up_locked' 2>&1); rc=$?
  is_dead "$hp" \
    && ! printf '%s' "$out" | grep -q 'уже выполняется' \
    && [ "$(ups_count)" = 1 ] && [ "$rc" = 0 ]
}

# Ф3 fresh: здоровый параллельный holder (моложе порога) НЕ тронут — «пропуск»
scen_f3_fresh() {
  new_stack f3fresh; fresh_log
  local lock="$HF_STACK/.hfctl.lock" hp out rc
  hp=$(spawn_holder "$lock")
  sleep 2
  lock_is_held "$lock" || { echo "holder не держит лок (сценарий пустой)"; return 1; }
  out=$(hf 'hf_up_locked' 2>&1); rc=$?
  ! is_dead "$hp" \
    && printf '%s' "$out" | grep -q 'up уже выполняется — пропуск' \
    && [ "$(ups_count)" = 0 ] && [ "$rc" = 0 ]
}

# Ф3 нет fuser в PATH: тихая деградация к прежнему поведению (skip, без kill)
scen_f3_nofuser() {
  new_stack f3nofu; fresh_log
  local lock="$HF_STACK/.hfctl.lock" hp out rc
  hp=$(spawn_holder "$lock")
  sleep 2
  lock_is_held "$lock" || { echo "holder не держит лок (сценарий пустой)"; return 1; }
  out=$(HFCTL_LOCK_STALE=1 HF_PATH="$NOFU" hf 'hf_up_locked' 2>&1); rc=$?
  ! is_dead "$hp" \
    && printf '%s' "$out" | grep -q 'up уже выполняется — пропуск' \
    && [ "$(ups_count)" = 0 ] && [ "$rc" = 0 ]
}

# Ф4 pod с пустым INFRA ID: pod rm -f ДО первого compose up, up прошёл
scen_f4_empty() {
  new_stack f4empty; fresh_log
  local out rc rm_line up_line
  out=$(HFCTL_FAUX_POD_INFRA=empty hf 'hf_up_locked' 2>&1); rc=$?
  rm_line=$(grep -n 'podman pod rm -f pod_hipfire' "$FAUXLOG" | head -1 | cut -d: -f1)
  up_line=$(grep -n 'up -d' "$FAUXLOG" | head -1 | cut -d: -f1)
  printf '%s' "$out" | grep -q 'пустым INFRA ID' \
    && [ -n "$rm_line" ] && [ -n "$up_line" ] && [ "$rm_line" -lt "$up_line" ] \
    && [ "$(ups_count)" = 1 ] && [ "$rc" = 0 ]
}

# Ф4 pod здоров (INFRA ID непуст): rm нет, up прошёл
scen_f4_full() {
  new_stack f4full; fresh_log
  local rc
  HFCTL_FAUX_POD_INFRA=full hf 'hf_up_locked' >/dev/null 2>&1; rc=$?
  ! grep -q 'podman pod rm -f pod_hipfire' "$FAUXLOG" && [ "$(ups_count)" = 1 ] && [ "$rc" = 0 ]
}

# Ф4 pod нет (inspect rc 1): no-op, up прошёл
scen_f4_absent() {
  new_stack f4absent; fresh_log
  local rc
  hf 'hf_up_locked' >/dev/null 2>&1; rc=$?
  ! grep -q 'podman pod rm -f pod_hipfire' "$FAUXLOG" && [ "$(ups_count)" = 1 ] && [ "$rc" = 0 ]
}

# Ф5 доставка: conf на месте и юниты отрендерены с Environment (cmd_autostart)
scen_f5_deliver() {
  new_stack f5deliver; fresh_log
  rm -rf "$TMP/home"; mkdir -p "$TMP/home"
  local rc
  hf 'cmd_autostart' >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] \
    && [ -f "$HF_STACK/.hfctl-containers.conf" ] \
    && grep -q 'Environment=CONTAINERS_CONF=' "$TMP/home/.config/systemd/user/hipfire-compose.service" \
    && grep -q 'Environment=CONTAINERS_CONF=' "$TMP/home/.config/systemd/user/hipfire-compose-watchdog.service"
}

# Ф5 env-контракт compose(): файл есть → env выставлен; файла нет → env чист
scen_f5_env() {
  new_stack f5env; fresh_log
  hf 'write_stack_files' >/dev/null 2>&1 || return 1
  [ -f "$HF_STACK/.hfctl-containers.conf" ] || return 1
  fresh_log
  hf 'hf_up_locked' >/dev/null 2>&1 || return 1
  grep -qF "env CONTAINERS_CONF=$HF_STACK/.hfctl-containers.conf" "$FAUXLOG" || return 1
  new_stack f5noconf; fresh_log
  hf 'hf_up_locked' >/dev/null 2>&1 || return 1
  grep -q 'env CONTAINERS_CONF=UNSET' "$FAUXLOG" || return 1
  return 0
}

# ── 13.2: preflight — apt-пятёрка + GPU-подготовка (гейт/группы/limits.d) ────
# Хуки: HFCTL_KFD/HFCTL_DRI (существующие/несуществующие пути), HFCTL_LIMITS
#   (всегда в $TMP), HFCTL_FAUX_GROUPS (группы юзера), HFCTL_FAUX_LINGER,
#   HF_MEMLOCK (лимит сессии: хард песочницы 4097452 не поднимается —
#   «достаточная сессия» эмулируется MEMLOCK=2097152 ≤ 4097452).

# P-A pkgs-missing: stripped PATH (всё пятеро нет), GPU есть, группы ок,
# limits заранее равен рендеру → ровно один apt install с пятью именами,
# update перед ним, rc 0
scen_p_a() {
  new_stack pa; fresh_log
  local lim="$TMP/limits-pa.conf" rc n_upd n_inst
  limits_bytes tester 1318060032 > "$lim"
  HFCTL_LIMITS="$lim" HFCTL_KFD="$TMP/kfd-node" HFCTL_DRI="$TMP/dri-node" \
    HF_PATH="$STRIPPED" hf 'preflight' >/dev/null 2>&1; rc=$?
  n_inst=$(grep -c 'apt-get install -y -qq podman podman-compose containers-storage psmisc curl' "$FAUXLOG" || true)
  n_upd=$(grep -n 'apt-get update -qq' "$FAUXLOG" | head -1 | cut -d: -f1)
  local n_ln; n_ln=$(grep -n 'apt-get install -y -qq podman' "$FAUXLOG" | head -1 | cut -d: -f1)
  [ "${n_inst:-0}" = 1 ] && [ -n "$n_upd" ] && [ -n "$n_ln" ] \
    && [ "$n_upd" -lt "$n_ln" ] && [ "$rc" = 0 ]
}

# P-B pkgs-present: FAUX_FULL (все пять есть) → rc 0, apt-get в журнале 0 раз
scen_p_b() {
  new_stack pb; fresh_log
  local lim="$TMP/limits-pb.conf" rc n_apt
  limits_bytes tester 1318060032 > "$lim"
  HFCTL_LIMITS="$lim" HFCTL_KFD="$TMP/kfd-node" HFCTL_DRI="$TMP/dri-node" \
    HF_PATH="$FAUX_FULL:$PATH" hf 'preflight' >/dev/null 2>&1; rc=$?
  n_apt=$(grep -c 'apt-get' "$FAUXLOG" || true)
  [ "$rc" = 0 ] && [ "${n_apt:-0}" = 0 ]
}

# P-C не-GPU: хуки → несуществующие пути → info-пропуск, затем §6.3-die;
# ноль мутаций (usermod/install-limits/enable-linger/apt в журнале НЕТ)
scen_p_c() {
  new_stack pc; fresh_log
  local out rc
  out=$(HFCTL_KFD="$TMP/no-kfd" HFCTL_DRI="$TMP/no-dri" hf 'preflight' 2>&1); rc=$?
  printf '%s' "$out" | grep -q 'GPU-подготовка пропущена' \
    && printf '%s' "$out" | grep -q '/dev/kfd нет' \
    && [ "$rc" != 0 ] \
    && ! grep -qE 'usermod|install -m 0644|enable-linger|apt-get' "$FAUXLOG"
}

# P-D группы свежие: kfd есть, video нет в id -nG → usermod render,video в
# журнале, честный вывод «после перезахода», rc 42; limits/linger/apt не достигнуты
scen_p_d() {
  new_stack pd; fresh_log
  local out rc
  out=$(HFCTL_FAUX_GROUPS="tester render" HFCTL_KFD="$TMP/kfd-node" \
    HFCTL_DRI="$TMP/dri-node" hf 'preflight' 2>&1); rc=$?
  grep -qF 'sudo usermod -aG render,video tester' "$FAUXLOG" \
    && printf '%s' "$out" | grep -q 'после перезахода' \
    && [ "$rc" = 42 ] \
    && ! grep -qE 'install -m 0644|enable-linger|apt-get' "$FAUXLOG"
}

# P-E limits-файла нет: создан, байты == рендер (tester/2097152), сессия с
# достаточным лимитом → rc 0, linger вызван
scen_p_e() {
  new_stack pe; fresh_log
  local lim="$TMP/limits-pe.conf" rc
  rm -f "$lim"
  HF_MEMLOCK=2097152 HFCTL_LIMITS="$lim" HFCTL_KFD="$TMP/kfd-node" \
    HFCTL_DRI="$TMP/dri-node" hf 'preflight' >/dev/null 2>&1; rc=$?
  [ -f "$lim" ] || return 1
  limits_bytes tester 2097152 > "$TMP/limits-pe.expected"
  cmp -s "$TMP/limits-pe.expected" "$lim" || return 1
  grep -q 'enable-linger' "$FAUXLOG" && [ "$rc" = 0 ]
}

# P-F idempotence: файл заранее равен рендеру → install в журнале 0 раз;
# «чужое» содержимое → переписан (журнал + байты)
scen_p_f() {
  new_stack pf; fresh_log
  local lim="$TMP/limits-pf.conf" rc
  limits_bytes tester 2097152 > "$lim"
  HF_MEMLOCK=2097152 HFCTL_LIMITS="$lim" HFCTL_KFD="$TMP/kfd-node" \
    HFCTL_DRI="$TMP/dri-node" hf 'preflight' >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] || return 1
  [ "$(grep -c 'install -m 0644' "$FAUXLOG" || true)" = 0 ] || return 1
  fresh_log
  printf 'someone soft memlock 64\n' > "$lim"
  HF_MEMLOCK=2097152 HFCTL_LIMITS="$lim" HFCTL_KFD="$TMP/kfd-node" \
    HFCTL_DRI="$TMP/dri-node" hf 'preflight' >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] || return 1
  grep -q 'install -m 0644' "$FAUXLOG" || return 1
  limits_bytes tester 2097152 > "$TMP/limits-pf.expected"
  cmp -s "$TMP/limits-pf.expected" "$lim"
}

# P-G низкий memlock сессии: файла нет + субшелл с реальным builtin
#   ulimit -l 65536 (hard=65536; одиночный `ulimit -Hl` в песочнице даёт
#   EINVAL: cur>max) → rc 42, warn «Требуется ребут», файл записан, linger
#   не достигнут
scen_p_g() {
  new_stack pg; fresh_log
  local lim="$TMP/limits-pg.conf" out rc
  rm -f "$lim"
  out=$( ( ulimit -l 65536; \
           HFCTL_LIMITS="$lim" HFCTL_KFD="$TMP/kfd-node" HFCTL_DRI="$TMP/dri-node" \
           hf 'preflight' ) 2>&1 ); rc=$?
  printf '%s' "$out" | grep -q 'Требуется ребут' \
    && [ -f "$lim" ] && [ "$rc" = 42 ] \
    && ! grep -q 'enable-linger' "$FAUXLOG"
}

# P-H полный no-op (эмуляция FAEX/evo): всё на месте, группы ок, limits равен,
# linger уже включён → rc 0; в журнале нет apt/usermod/install-limits/enable-linger
scen_p_h() {
  new_stack ph; fresh_log
  local lim="$TMP/limits-ph.conf" rc n_bad
  limits_bytes tester 1318060032 > "$lim"
  HFCTL_FAUX_LINGER=1 HFCTL_LIMITS="$lim" HFCTL_KFD="$TMP/kfd-node" \
    HFCTL_DRI="$TMP/dri-node" HF_PATH="$FAUX_FULL:$PATH" \
    hf 'preflight' >/dev/null 2>&1; rc=$?
  n_bad=$(grep -cE 'apt-get|usermod|install -m 0644|enable-linger' "$FAUXLOG" || true)
  [ "$rc" = 0 ] && [ "${n_bad:-0}" = 0 ]
}

# инвентарь маркеров: 9 имён на месте, счёт по локациям верный
check_markers() {
  local m
  for m in off-stop orphan-heal lock-reclaim pod-infra containers-conf preflight-pkgs gpu-gate gpu-groups gpu-limits; do
    grep -rq "# fix:$m" "$ROOT/lib" || { echo "маркер # fix:$m отсутствует"; return 1; }
  done
  [ "$(grep -c '# fix:off-stop'    "$ROOT/lib/autostart.sh")" = 1 ] || return 1
  [ "$(grep -c '# fix:orphan-heal' "$ROOT/lib/autostart.sh")" = 2 ] || return 1
  [ "$(grep -c '# fix:lock-reclaim' "$ROOT/lib/autostart.sh")" = 2 ] || return 1
  [ "$(grep -c '# fix:pod-infra'   "$ROOT/lib/autostart.sh")" = 2 ] || return 1
  local s=0 f c
  for f in stack.sh stack_files.sh autostart.sh; do
    c=$(grep -c '# fix:containers-conf' "$ROOT/lib/$f" 2>/dev/null) || c=0
    s=$((s + c))
  done
  [ "$s" = 3 ] || return 1
  [ "$(grep -c '# fix:preflight-pkgs' "$ROOT/lib/stack.sh")" = 2 ] || return 1
  [ "$(grep -c '# fix:gpu-gate'       "$ROOT/lib/stack.sh")" = 1 ] || return 1
  [ "$(grep -c '# fix:gpu-groups'     "$ROOT/lib/stack.sh")" = 1 ] || return 1
  [ "$(grep -c '# fix:gpu-limits'     "$ROOT/lib/stack.sh")" = 1 ] || return 1
}

# ── мутационный движок ───────────────────────────────────────────────────────
# Копия дерева (hfctl+lib+tpl) в $TMP, sed-удаление строк с маркером (или
# явный sed-выражение для Ф5-unit), bash -n мутанта, сценарий обязан УПАСТЬ.
mutant_marker() {  # mutant_marker <имя> <маркер> → путь мутанта | '' (маркер не найден)
  local dst="$TMP/mut-$1"
  rm -rf "$dst"; mkdir -p "$dst"
  cp -a "$ROOT/hfctl" "$ROOT/lib" "$ROOT/tpl" "$dst/" || { echo ''; return; }
  grep -rq "# fix:$2" "$dst/lib" || { echo ''; return; }
  find "$dst/lib" -name '*.sh' -exec sed -i "/# fix:$2/d" {} +
  echo "$dst"
}
mutant_sed() {  # mutant_sed <имя> <файл-от-ROOT> <sed-expr> → путь | '' (нет цели)
  local dst="$TMP/mut-$1" rel="$2"
  rm -rf "$dst"; mkdir -p "$dst"
  cp -a "$ROOT/hfctl" "$ROOT/lib" "$ROOT/tpl" "$dst/" || { echo ''; return; }
  [ -f "$ROOT/$rel" ] || { echo ''; return; }
  sed -i "$3" "$dst/$rel"
  echo "$dst"
}
check_mutation() {  # check_mutation <лейбл> <путь|''> <сценарий…>
  local label="$1" dst="$2"; shift 2
  if [ -z "$dst" ]; then bad "мутация $label: маркер не найден (дрейф маркеров)"; return; fi
  if ! bash -n "$dst/lib/autostart.sh" "$dst/lib/stack.sh" "$dst/lib/stack_files.sh" 2>/dev/null; then
    bad "мутация $label: мутант не парсится"; return
  fi
  local prev="${HF_TREE:-$ROOT}"; HF_TREE="$dst"   # $ROOT эквивалентен unset для hf
  if "$@"; then bad "мутация $label: сценарий прошёл на мутанте — защита не держит"; else ok "мутация $label: сценарий упал — защита держит"; fi
  HF_TREE="$prev"
}

# ═════════════════════════════════════════════════════════════════════════════
echo "== 0. AGENTS-четыре: bash -n / py_compile / usage rc=1 / status --json на чанковом порту"
if bash -n "$ROOT/hfctl" "$ROOT"/lib/*.sh "$ROOT/tests/run_checks.sh" 2>"$TMP/syn.err"; then
  ok "bash -n hfctl lib/*.sh tests/run_checks.sh"
else
  bad "bash -n: $(cat "$TMP/syn.err")"
fi
if PYTHONPYCACHEPREFIX="$TMP/pycache" python3 -m py_compile "$ROOT"/tpl/python/*.py 2>"$TMP/py.err"; then
  ok "python3 -m py_compile tpl/python/*.py"
else
  bad "py_compile: $(tail -1 "$TMP/py.err")"
fi
out=$(bash "$ROOT/hfctl" 2>&1); rc=$?
if [ "$rc" = 1 ] && [ -n "$out" ]; then ok "bare-вызов: usage напечатан, rc=1"; else bad "bare-вызов: rc=$rc (нужен 1 + usage)"; fi
out=$(HOME="$TMP/home" HFCTL_PORT=1 bash "$ROOT/hfctl" status --json 2>&1); rc=$?
if [ -n "$out" ] && ! printf '%s' "$out" | grep -qiE 'traceback|internal error|syntax error'; then
  ok "status --json на чанковом порту: корректный отказ, не краш (rc=$rc)"
else
  bad "status --json на чанковом порту: подозрительный вывод (rc=$rc)"; printf '%s\n' "$out" | tail -3
fi

echo "== 1. инвентарь маркеров # fix:<имя> (защита от дрейфа)"
if check_markers; then ok "9 имён маркеров на месте, счёт по локациям 1/2/2/2/3/2/1/1/1"; else bad "инвентарь маркеров: $(check_markers 2>&1)"; fi

echo "== 2. Ф1 off: явный podman stop основного контейнера"
if scen_f1_fail; then ok "Ф1: compose stop rc 1 → podman stop hipfire_hipfire_1 вызван, off дошёл до «ВЫКЛ» rc 0"; else bad "Ф1 позитив (compose stop fail)"; fi
if scen_f1_happy; then ok "Ф1: happy compose stop rc 0 → podman stop тоже вызван (безвреден)"; else bad "Ф1 позитив (happy)"; fi

echo "== 3. Ф2 storage-сирота: самолечение + retry up"
if scen_f2_locked; then ok "Ф2: hf_up_locked — сирота удалена (delete-container ID), ровно 2 up, rc 0"; else bad "Ф2 позитив (hf_up_locked)"; fi
if scen_f2_devsafe; then ok "Ф2: hf_up_devsafe — сирота удалена, ровно 2 up, rc 0"; else bad "Ф2 позитив (hf_up_devsafe)"; fi
if scen_up_happy; then ok "Ф2: happy up без аномалий — ровно 1 up, rc 0, хил не звался"; else bad "Ф2 позитив (happy up)"; fi
if scen_f2_cap; then ok "Ф2: кап HEAL_MAX=1 — второй хил НЕ случился (1 delete, 2 up, rc≠0)"; else bad "Ф2 кап"; fi
if scen_f2_nobin; then ok "Ф2: containers-storage нет — WARN с ручной командой, delete НЕ вызван"; else bad "Ф2 Variant B (нет бинаря)"; fi
if scen_f2_guard; then ok "Ф2: ID видит libpod — «не сирота», delete НЕ вызван"; else bad "Ф2 guard (libpod видит ID)"; fi

echo "== 4. Ф3 lock: реклейм зависших держателей (настоящие flock/fuser/ps)"
if scen_f3_stale; then ok "Ф3: stale-holder убит (kill -9), up прошёл, «пропуска» нет"; else bad "Ф3 позитив (stale)"; fi
if scen_f3_fresh; then ok "Ф3: fresh-holder не тронут — «up уже выполняется — пропуск», up не звался"; else bad "Ф3 позитив (fresh)"; fi
if scen_f3_nofuser; then ok "Ф3: нет fuser в PATH — тихая деградация к прежнему skip"; else bad "Ф3 позитив (нет fuser)"; fi

echo "== 5. Ф4 pod: пустой INFRA ID → пересоздание до up"
if scen_f4_empty; then ok "Ф4: pod rm -f pod_hipfire ДО compose up, up прошёл rc 0"; else bad "Ф4 позитив (пустой INFRA)"; fi
if scen_f4_full; then ok "Ф4: INFRA ID непуст — rm нет, up прошёл"; else bad "Ф4 позитив (здоровый pod)"; fi
if scen_f4_absent; then ok "Ф4: pod нет (inspect rc 1) — no-op, up прошёл"; else bad "Ф4 позитив (pod отсутствует)"; fi

echo "== 6. Ф5 CONTAINERS_CONF: доставка + env-контракт compose()"
if scen_f5_deliver; then ok "Ф5: cmd_autostart поставил .hfctl-containers.conf и отрендерил юниты с Environment"; else bad "Ф5 позитив (cmd_autostart)"; fi
if scen_f5_env; then ok "Ф5: compose() — env выставлен при файле, UNSET при отсутствии"; else bad "Ф5 позитив (env-контракт)"; fi

echo "== 7. 13.2 preflight: apt-пятёрка + GPU-подготовка (гейт/группы/limits.d)"
if scen_p_a; then ok "P-A: pkgs-missing — apt-пятёрка одним списком (5 имён), update перед install, rc 0"; else bad "P-A позитив (apt-пятёрка)"; fi
if scen_p_b; then ok "P-B: pkgs-present — apt-get в журнале 0 раз, rc 0"; else bad "P-B позитив (всё на месте — apt не звался)"; fi
if scen_p_c; then ok "P-C: не-GPU — info-пропуск + §6.3-die, ноль мутаций"; else bad "P-C позитив (гейт)"; fi
if scen_p_d; then ok "P-D: группы свежие — usermod render,video, «после перезахода», rc 42"; else bad "P-D позитив (группы)"; fi
if scen_p_e; then ok "P-E: limits-файла нет — создан, байты == рендер, rc 0, linger вызван"; else bad "P-E позитив (запись limits)"; fi
if scen_p_f; then ok "P-F: limits idempotent — равен → install 0 раз; чужой → переписан"; else bad "P-F позитив (cmp-idempotence)"; fi
if scen_p_g; then ok "P-G: низкий memlock сессии (настоящий ulimit) — rc 42, warn «ребут», файл записан"; else bad "P-G позитив (низкий ulimit)"; fi
if scen_p_h; then ok "P-H: полный no-op (FAEX/evo) — rc 0, в журнале нет apt/usermod/install/linger"; else bad "P-H позитив (happy no-op)"; fi

echo "== 8. мутации: вырезание по маркерам на КОПИИ дерева → сценарий падает"
check_mutation "off-stop" "$(mutant_marker off-stop off-stop)" scen_f1_fail
d=$(mutant_marker orphan-heal orphan-heal)
if [ -n "$d" ]; then
  check_mutation "orphan-heal" "$d" scen_f2_locked
  check_mutation "orphan-heal(devsafe)" "$d" scen_f2_devsafe
else
  bad "мутация orphan-heal: маркер не найден (дрейф маркеров)"
fi
check_mutation "lock-reclaim" "$(mutant_marker lock-reclaim lock-reclaim)" scen_f3_stale
check_mutation "pod-infra" "$(mutant_marker pod-infra pod-infra)" scen_f4_empty
check_mutation "containers-conf" "$(mutant_marker containers-conf containers-conf)" scen_f5_deliver
if grep -q 'Environment=CONTAINERS_CONF' "$ROOT/tpl/systemd/hipfire-compose.service.tpl"; then
  check_mutation "containers-conf-unit" "$(mutant_sed containers-conf-unit tpl/systemd/hipfire-compose.service.tpl '/Environment=CONTAINERS_CONF/d')" scen_f5_deliver
else
  bad "мутация containers-conf-unit: Environment-строки нет в tpl (дрейф)"
fi
check_mutation "preflight-pkgs" "$(mutant_marker preflight-pkgs preflight-pkgs)" scen_p_a
check_mutation "gpu-gate" "$(mutant_marker gpu-gate gpu-gate)" scen_p_c
check_mutation "gpu-groups" "$(mutant_marker gpu-groups gpu-groups)" scen_p_d
check_mutation "gpu-limits" "$(mutant_marker gpu-limits gpu-limits)" scen_p_e

printf 'ИТОГО: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
