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
#    СНАЧАЛА тишина окна: очередь пуста и в последних логах нет чужих
#    запросов (урок contamin-прогона 11:50 на B) — под трафиком не мерить.
q=$(curl -s http://127.0.0.1:11435/stats | grep -o '"queue_depth":[0-9]*' | grep -o '[0-9]*$' || echo "?")
echo "queue_depth перед bench: $q"
[ "$q" = "0" ] || fail "окно не тихое: queue_depth=$q (чужой трафик) — перенести bench"
noise=$(podman logs --since 30s hipfire 2>&1 | grep -ciE 'chatcmpl|POST /v1' || true)
[ "$noise" = 0 ] || fail "окно не тихое: $noise чужих запросов за 30 с"
art=$("$ST/hfctl" bench --json 2>/dev/null) || fail "bench quick не завершился"
echo "$art" | grep -E '"(image|route|solo-code|median|unit)"' | head -8
# route для профиля: flash-multi = lanes (fn-lanes, бейзлайн 75.8 снят на
# lanes); 27b-single = dflash. Проверяем ожидаемый route по профилю.
case "$PROFILE" in
  flash-multi) want=lanes ;;
  27b-single)  want=dflash ;;
  *) fail "неизвестный профиль $PROFILE — добавь ожидаемый route в скрипт" ;;
esac
BENCH_ART="$art" WANT_ROUTE="$want" BASELINE_TOKS="$BASELINE_TOKS" python3 - <<'PY' || fail "bench-проверки (см. вывод выше)"
import json, os, sys
a = json.loads(os.environ["BENCH_ART"])
m = a["summary"]["solo-code"]["median"]
base = float(os.environ["BASELINE_TOKS"])
want = os.environ["WANT_ROUTE"]
route = a.get("route", "")
print("solo-code: %.2f tok/s (бейзлайн 0.4.6: %s); route: %s (ждём %s)"
      % (m, base, route, want))
assert want in route, "route %r не содержит %s" % (route, want)
d = (m - base) / base * 100.0
assert abs(d) < 5.0, "отклонение solo-code %.1f%% (лимит 5%%)" % d
print("solo-code отклонение %+.1f%% — в пределах 5%%" % d)
PY
echo "RESULT: PASS — 0.4.7: healthy, smoke, route=$PROFILE-канон, solo-code в пределах 5% от бейзлайна"
