#!/bin/bash
# hfctl (remote): батарея конкурентности — сравнение режимов FIFO-vs-slots.
# Сценарии (×3 повтора):
#   solo_s  — одиночный короткий (48 tok): базовая скорость одиночки
#   solo_l  — одиночный длинный (1000 tok)
#   par     — два длинных (2×600 tok) параллельно: PAR_WALL + агрегат
#   behind  — короткий (48) через 2 c после старта длинного (1000):
#             latency короткого = его wall (главная метрика HOL-изоляции)
set -u
URL=http://127.0.0.1:11435/v1/chat/completions
MODEL=${HF_MODEL:-qwen3.8:27b-mq6-xt}
OUT="$HOME/conc-runs"
mkdir -p "$OUT"; rm -f "$OUT"/*.json
stamp(){ python3 -c 'import time;print(f"{time.time():.3f}")'; }

LONG1="Расскажи подробно историю про маяк и смотрителя: четыре главы, детали, диалоги, литературный язык."
LONG2="Напиши на Python большой модуль: связный список, стек, очередь, бинарное дерево поиска; подробно, с комментариями и тестами."
SHORT="Сколько будет 128*7? Ответь только числом."

ask(){ # $1=name $2=max_tokens $3=prompt
  local t0 t1
  t0=$(stamp)
  curl -s -X POST "$URL" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"max_tokens\":$2,\"temperature\":0,\"reasoning_effort\":\"none\",\"messages\":[{\"role\":\"user\",\"content\":\"$3\"}]}" \
    -o "$OUT/$1.json"
  t1=$(stamp)
  echo "  $1 wall=$(python3 -c "print(f'{$t1-$t0:.2f}')")"
}

for rep in 1 2 3; do
  echo "=== REP $rep ==="
  echo "-- solo short 48"
  ask solo_s_${rep} 48 "$SHORT"
  echo "-- solo long 1000"
  ask solo_l_${rep} 1000 "$LONG1"
  echo "-- two parallel 2x600"
  T0=$(stamp)
  ask par_a_${rep} 600 "$LONG1" &
  ask par_b_${rep} 600 "$LONG2" &
  wait
  T1=$(stamp)
  echo "PAR_WALL=$(python3 -c "print(f'{$T1-$T0:.2f}')")"
  echo "-- short behind long (long1000, +2s short48)"
  T0=$(stamp)
  ask beh_l_${rep} 1000 "$LONG1" &
  sleep 2
  ask beh_s_${rep} 48 "$SHORT"
  wait
  T1=$(stamp)
  echo "BEH_WALL=$(python3 -c "print(f'{$T1-$T0:.2f}')")"
done

echo "=== completion tokens ==="
python3 - <<'PY'
import json, glob, os
out = os.path.expanduser("~/conc-runs")
for f in sorted(glob.glob(out + "/*.json")):
    n = os.path.basename(f)[:-5]
    try:
        d = json.load(open(f))
        print(n, "| tok:", (d.get("usage") or {}).get("completion_tokens"),
              "| finish:", d["choices"][0].get("finish_reason"))
    except Exception as e:
        print(n, "| ERR", e)
PY
echo CONC_BENCH_DONE
