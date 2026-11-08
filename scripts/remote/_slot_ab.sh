#!/bin/bash
# hfctl (remote): A/B «параллель vs сериал» для экспериментов с multi_slot.
# В ВЫХОДНОЙ Прод-конфигурации НЕ ЗАПУСКАТЬ (прод = serial FIFO + DFlash).
# Это инструмент для slot-экспериментов: 2 запроса параллельно, затем те же
# последовательно; сравниваем стену. Артефакты: ~/ab/{p,s}{1,2}.json.
set -u
URL=http://127.0.0.1:11435/v1/chat/completions
MODEL=${HF_MODEL:-qwen3.8:27b-mq6-xt}
OUT="$HOME/ab"
mkdir -p "$OUT"
A="Напиши на Python функцию quicksort со вставкой-тестом. Подробные комментарии, 200+ слов."
B="Расскажи историю про маяк и смотрителя. Красивый литературный текст, 200+ слов."

mk() { curl -s -X POST "$URL" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":250,\"temperature\":0,\"reasoning_effort\":\"none\",\"messages\":[{\"role\":\"user\",\"content\":\"$1\"}]}" \
  -o "$OUT/$2"; }

T0=$(date +%s.%N); mk "$A" p1 & mk "$B" p2 & wait; T1=$(date +%s.%N)
echo "PARALLEL_WALL=$(python3 -c "print(f'{$T1-$T0:.1f}')")"
T0=$(date +%s.%N); mk "$A" s1; mk "$B" s2; T1=$(date +%s.%N)
echo "SERIAL_WALL=$(python3 -c "print(f'{$T1-$T0:.1f}')")"

python3 - <<'PY'
import json, glob, os
for f in sorted(glob.glob(os.path.expanduser('~/ab/*.json'))):
    try:
        d = json.load(open(f))
        u = (d.get('usage') or {}).get('completion_tokens')
        eng = (d.get('hipfire') or {}).get('tok_s')
        print(os.path.basename(f), '| tok:', u, '| engine tok_s:', eng)
    except Exception as e:
        print(f, 'ERR', e)
PY
