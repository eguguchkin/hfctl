#!/usr/bin/env bash
# EXP-104 — приёмка дефолтного пина 0.4.7 (машинное окно, тихое время)
# Цель: новый hfctl (дефолтный пин 0.4.7) на живой машине:
#   recreate → healthy → smoke → check_route → bench quick;
#   работающий образ = ghcr.io/warpfront/hipfire:0.4.7, route dflash,
#   solo-code в пределах 5% от бейзлайна 0.4.6.
# Предусловие: оркестратор scp-нул новый бинарь на /tmp/hfctl-0.4.7;
#   тихое окно (recreate = короткое прерывание сервиса).
# Env: PROFILE=27b-single (che-evo) | flash-multi (машина B);
#      BASELINE_TOKS=<solo-code бейзлайн 0.4.6> (evo 131.0 / B 75.8)
# Запуск: export PROFILE BASELINE_TOKS;
#   ssh -i "$HF_KEY" -o BatchMode=yes "$HF_HOST" 'bash -s' < this-script
# Вывод: весь → stdout → EXP-104-<host>.result.txt; последняя строка
#   RESULT: PASS|FAIL|ERROR — …
set -uo pipefail
PROFILE="${PROFILE:?PROFILE не задан}"
BASELINE_TOKS="${BASELINE_TOKS:?BASELINE_TOKS не задан}"
ST="$HOME/hipfire"
fail() { echo "RESULT: FAIL — $*"; exit 1; }

# 1) бинарь в стек (единственный путь обновления — бинарь в стеке)
cp /tmp/hfctl-0.4.7 "$ST/hfctl" && chmod +x "$ST/hfctl" || fail "scp-бинарь не найден / права"

# 2) use: recreate (pull 0.4.7 если нет локально) + wait_health(900 c)
#    + smoke (2 реальных запроса) + check_route
"$ST/hfctl" use "$PROFILE" || fail "use не завершился (podman logs hipfire)"

# 3) работающий образ
img=$(podman ps --format '{{.Image}}' | grep -m1 hipfire || true)
echo "container image: $img"
case "$img" in
  *hipfire:0.4.7) : ;;
  *) fail "рабочий образ не 0.4.7 ($img)" ;;
esac

# 4) bench quick (3 сценария, ≤90 c) + чек соло-кода и route
art=$("$ST/hfctl" bench --json 2>/dev/null) || fail "bench quick не завершился"
echo "$art" | grep -E '"(image|route|solo-code|median|unit)"' | head -8
BENCH_ART="$art" BASELINE_TOKS="$BASELINE_TOKS" python3 - <<'PY' || fail "bench-проверки (см. вывод выше)"
import json, os, sys
a = json.loads(os.environ["BENCH_ART"])
m = a["summary"]["solo-code"]["median"]
base = float(os.environ["BASELINE_TOKS"])
print("solo-code: %.2f tok/s (бейзлайн 0.4.6: %s); route: %s"
      % (m, base, a.get("route")))
assert "dflash" in a.get("route", ""), "route без dflash: %r" % a.get("route")
d = (m - base) / base * 100.0
assert abs(d) < 5.0, "отклонение solo-code %.1f%% (лимит 5%%)" % d
print("solo-code отклонение %+.1f%% — в пределах 5%%" % d)
PY
echo "RESULT: PASS — 0.4.7: healthy, smoke, dflash, solo-code в пределах 5% от бейзлайна"
