#!/usr/bin/env bash
# selfcheck: defect/boot-device-mismatch — shell-приёмки слоя 1 (GPU-ready
# wait + recreate-on-device-mismatch в _boot/_watchdog, lib/autostart.sh).
#
# Назначение: машинная проверка код-подэтапа (своей батареи tests/ у hfctl
#   нет, DoD 2): стабы podman/sleep/date через PATH-фикстуру против
#   НАСТОЯЩЕГО диспетчера (`bash hfctl _boot|_watchdog`). Сценарии:
#   (а) boot: GPU готова, up ok        → 1 up, rm НЕ звался, rc 0;
#   (б) boot: up упал «cannot stat»    → rm -f + повторный up → running, rc 0;
#   (в) boot: GPU-ready таймаут        → die с диагностикой (rc 1, FATAL);
#   (г) watchdog при неготовом GPU     → тихий выход (rc 0, ни одного вызова);
#   (д) watchdog при девайс-отказе     → rm -f + повторный up + строка в лог;
#   (е) boot: up упал БЕЗ сигнатуры    → rm НЕ звался, цикл поднял со 2-й;
#   (ж) watchdog при running           → молчание (ни up, ни rm, ни лога).
#
# Побочные эффекты: только временный каталог mktemp -d в /tmp/opencode
#   (удаляется по EXIT). Машины не трогает, наружу не ходит, идемпотентен.
#
# Ограничения/допущения: /dev/kfd и /dev/dri в песочнице нет — GPU-гейт
#   фейкается env-путями HFCTL_KFD/HFCTL_DRI (продуктовые хуки шапки
#   autostart.sh, продом не используются); ход часов фейкается
#   (sleep+=сек, date +%s читает виртуальные часы — дедлайны _boot и
#   GPU-wait 60 с сходятся мгновенно). Запуск из любого каталога; путь к
#   репо считается от расположения скрипта. exit-код = вердикт.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"   # tasks/<defect>/<sub> → корень репо
TMP="$(mktemp -d "${TMPDIR:-/tmp}/boot-selfcheck.XXXXXX")" || { echo "selfcheck: mktemp недоступен" >&2; exit 1; }
trap '[ -n "${TMP:-}" ] && rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/stack"
FIX="$TMP/bin"

pass=0 fail=0
ok()   { pass=$((pass+1)); echo "ok $pass - $1"; }
nope() { fail=$((fail+1)); echo "FAIL - $1" >&2; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else nope "$1 (ожидалось [$3], получено [$2])"; fi; }
expect_grep()    { if grep -q "$2" "$3" 2>/dev/null; then ok "$1"; else nope "$1 (нет [$2] в $3)"; fi; }
expect_nogrep()  { if grep -q "$2" "$3" 2>/dev/null; then nope "$1 (найдено [$2] в $3)"; else ok "$1"; fi; }

# ── 0. синтаксис изменённых продуктовых файлов (DoD 1) ──────────────────────
if bash -n "$REPO/hfctl" "$REPO/lib/autostart.sh" 2>"$TMP/syntax.err"; then
  ok "bash -n hfctl lib/autostart.sh"
else
  nope "bash -n: $(cat "$TMP/syntax.err")"
fi

# ── PATH-фикстура: fake podman / sleep / date ───────────────────────────────
cat > "$FIX/sleep" <<'EOF'
#!/usr/bin/env bash
# стаб sleep: двигает виртуальные часы (FAKE_CLOCK) — дедлайны _boot и
# GPU-wait сходятся мгновенно; аргумент — целые секунды.
set -u
case "${1:-}" in ''|*[!0-9]*) echo "fake sleep: аргумент '$1'" >&2; exit 99;; esac
echo "$(( $(cat "$FAKE_CLOCK") + $1 ))" > "$FAKE_CLOCK"
EOF
cat > "$FIX/date" <<'EOF'
#!/usr/bin/env bash
# стаб date: +%s — виртуальные часы FAKE_CLOCK; -Is — константа; остальное —
# реальный /bin/date.
case "${1:-}" in
  +%s) cat "$FAKE_CLOCK" ;;
  -Is) echo "2026-11-18T00:00:00+03:00" ;;
  *)   exec /bin/date "$@" ;;
esac
EOF
cat > "$FIX/podman" <<'EOF'
#!/usr/bin/env bash
# стаб podman: поведение по FAKE_SCENARIO (healthy|devfail|nosig), журнал
# вызовов — FAKE_CALLS (строка "$*" на вызов).
# healthy: up всегда ok, контейнер running.
# devfail: ПЕРВЫЙ up падает с сигнатурой device-mismatch (crun cannot stat +
# Failed to create container), контейнер exited до podman rm -f; после rm —
# up ok, running.
# nosig: ПЕРВЫЙ up падает БЕЗ сигнатуры (pull); running — только после
# второго up (rm не звать).
set -u
printf '%s\n' "$*" >> "$FAKE_CALLS"
s="${FAKE_SCENARIO:-healthy}"
ups=$(grep -c 'up -d' "$FAKE_CALLS")
case "$1" in
  compose)
    [ "${*: -2}" = "up -d" ] || { echo "fake podman: compose args '$*'" >&2; exit 99; }
    case "$s" in
      healthy) echo "Container hipfire_hipfire_1 started"; exit 0 ;;
      devfail)
        if [ ! -f "$FAKE_CALLS.rm" ] && [ "$ups" -eq 1 ]; then
          echo "Error: unable to start container hipfire_hipfire_1: crun: cannot stat \`/dev/dri/card0\`: No such file or directory" >&2
          echo "Failed to create container hipfire_hipfire_1"
          exit 1
        fi
        echo "Container hipfire_hipfire_1 started"; exit 0 ;;
      nosig)
        if [ "$ups" -eq 1 ]; then echo "Error: image pull failed" >&2; exit 1; fi
        echo "Container hipfire_hipfire_1 started"; exit 0 ;;
    esac ;;
  inspect)
    case "$s" in
      devfail) if [ -f "$FAKE_CALLS.rm" ]; then echo running; else echo exited; fi ;;
      nosig)   if [ "$ups" -ge 2 ]; then echo running; else echo exited; fi ;;
      *)       echo running ;;
    esac
    exit 0 ;;
  ps) echo "deadbeef00" ;;
  rm) : > "$FAKE_CALLS.rm"; echo "removed" ;;
  *)  echo "fake podman: unexpected: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$FIX/podman" "$FIX/sleep" "$FIX/date"

# ── прогон сценария: run <_boot|_watchdog> <fake-сценарий> <ready|notready>
#    → RC (rc процесса), $TMP/out, $TMP/err, $TMP/calls (журнал вызовов)
run() {
  rm -f "$TMP/calls" "$TMP/calls.rm" "$TMP/stack/.hfctl-watchdog.log"
  : > "$TMP/calls"
  /bin/date +%s > "$TMP/clock"
  rm -rf "$TMP/dev"; mkdir -p "$TMP/dev/dri"
  if [ "$3" = ready ]; then : > "$TMP/dev/kfd"; : > "$TMP/dev/dri/renderD128";
  else : > "$TMP/dev/dri/card0"; fi   # ранний бут: EFI-fb card0, без renderD/kfd
  RC=0
  PATH="$FIX:$PATH" HFCTL_DIR="$TMP/stack" \
    HFCTL_KFD="$TMP/dev/kfd" HFCTL_DRI="$TMP/dev/dri/renderD*" \
    FAKE_CLOCK="$TMP/clock" FAKE_CALLS="$TMP/calls" FAKE_SCENARIO="$2" \
    bash "$REPO/hfctl" "$1" >"$TMP/out" 2>"$TMP/err" || RC=$?
}
ups() { grep -c 'up -d' "$TMP/calls"; }
rms() { grep -c '^rm -f ' "$TMP/calls"; }

# (а) boot: GPU готова, штатный up — без recreate
run _boot healthy ready
expect "(а) rc 0"             "$RC" "0"
expect "(а) 1 up, 0 rm"       "$(ups)_$(rms)" "1_0"

# (б) boot: up упал с сигнатурой device-mismatch → rm -f → повторный up
run _boot devfail ready
expect "(б) rc 0"             "$RC" "0"
expect "(б) 2 up, 1 rm"       "$(ups)_$(rms)" "2_1"

# (в) boot: GPU-ready таймаут → die с диагностикой (и ни одного up)
run _boot healthy notready
expect "(в) rc 1"             "$RC" "1"
expect "(в) 0 up"             "$(ups)" "0"
expect_grep "(в) FATAL в stderr"       "FATAL" "$TMP/err"
expect_grep "(в) упоминание GPU-нод"   "GPU-ноды" "$TMP/err"
expect_grep "(в) ls /dev/dri в тексте" "/dev/dri" "$TMP/err"

# (г) watchdog при неготовом GPU — тихий выход без единого вызова
run _watchdog healthy notready
expect "(г) rc 0"             "$RC" "0"
expect "(г) ни одного вызова podman" "$(wc -l < "$TMP/calls" | tr -d ' ')" "0"
expect "(г) лог вотчдога не писался" "$([ -f "$TMP/stack/.hfctl-watchdog.log" ] && echo да || echo нет)" "нет"

# (д) watchdog при девайс-отказе — тот же класс защиты (rm + повторный up)
run _watchdog devfail ready
expect "(д) rc 0"             "$RC" "0"
expect "(д) 2 up, 1 rm"       "$(ups)_$(rms)" "2_1"
expect_grep "(д) строка в логе вотчдога" "state=exited" "$TMP/stack/.hfctl-watchdog.log"

# (е) boot: up упал БЕЗ сигнатуры — rm НЕ звался, цикл поднял повторным up
run _boot nosig ready
expect "(е) rc 0"             "$RC" "0"
expect "(е) 2 up, 0 rm"       "$(ups)_$(rms)" "2_0"

# (ж) watchdog при running — молчание (штатный путь без изменений)
run _watchdog healthy ready
expect "(ж) rc 0"             "$RC" "0"
expect "(ж) 0 up, 0 rm"       "$(ups)_$(rms)" "0_0"
expect "(ж) лог вотчдога не писался" "$([ -f "$TMP/stack/.hfctl-watchdog.log" ] && echo да || echo нет)" "нет"

echo "selfcheck: $pass/$((pass+fail)) ok"
[ "$fail" -eq 0 ]
