#!/bin/bash
# hfbox (remote): параллельный API-тест — N одновременных запросов к живому serve.
# Проверки: все 200, тексты связные, нет перемешивания/крашей, очередь FIFO
# (суммарное время ≈ сумма сериализованных генераций).
# Перед гонкой чистит старые resp_*.json в OUT — иначе парсер соберёт мусор.
set -u
N=${1:-4}
URL=http://127.0.0.1:11435/v1/chat/completions
OUT="$HOME/par-runs"
MODEL=${HF_MODEL:-qwen3.8:27b-mq6-xt}
mkdir -p "$OUT"; rm -f "$OUT"/resp_*.json
stamp(){ python3 -c 'import time;print(f"{time.time():.3f}")'; }

PROMPTS=(
"Напиши на Python функцию binary_search(iterable, target) -> int|None с docstring. 100 токенов."
"Объясни одним абзацем, что такое спекулятивное декодирование в LLM-инференсе."
"List 5 facts about the Roman Empire, one sentence each, in English."
"Напиши на Python класс Stack с push/pop/peek. 120 токенов."
"Почему у APU нет отдельной видеопамяти? Два предложения."
"Translate to English: Контекстное окно модели ограничено двумястами тысячами токенов."
"Дай SQL-запрос: выбрать топ-10 пользователей по сумме заказов. Одна строка кода."
"Что такое k-v кэш в трансформерах? Три предложения."
)

T0=$(stamp)
for i in $(seq 1 "$N"); do
  p=${PROMPTS[$(( (i-1) % 8 ))]}
  ( curl -s -w '\n{"_http_code":%{http_code},"_total_s":%{time_total}}' \
      -X POST "$URL" -H "Content-Type: application/json" \
      -d "{\"model\":\"$MODEL\",\"max_tokens\":128,\"temperature\":0,\"reasoning_effort\":\"none\",\"messages\":[{\"role\":\"user\",\"content\":\"$p\"}]}" \
      -o "$OUT/resp_$i.json" ) &
done
wait
T1=$(stamp)
echo "TOTAL_WALL_S=$(python3 -c "print(f'{$T1-$T0:.1f}')")"

python3 - <<PY
import json, glob
files = sorted(glob.glob("$OUT/resp_*.json"), key=lambda x: int(x.split('_')[-1].split('.')[0]))
for f in files:
    raw = open(f).read()
    meta = {}
    try:
        head, _, last = raw.rpartition('\n')
        if '"_http_code"' in last[-80:]:
            meta = json.loads(last); raw = head
        obj = json.loads(raw)
    except Exception as e:
        print(f.split('/')[-1], 'RAW:', raw[:120].replace('\n', ' '), '|', e)
        continue
    if 'choices' in obj:
        c = obj['choices'][0]['message'].get('content') or ''
        t = obj.get('timings') or {}
        print(f.split('/')[-1], '| http:', meta.get('_http_code'),
              '| finish:', obj['choices'][0].get('finish_reason'),
              '| tokens:', (obj.get('usage') or {}).get('completion_tokens'),
              '| total_s:', meta.get('_total_s'),
              '|', repr(c[:90]))
    else:
        print(f.split('/')[-1], '| NO-CHOICES:', raw[:200])
PY

echo "== health после нагрузки =="
curl -fsS http://127.0.0.1:11435/health | head -c 200; echo
echo "== ошибки в логах за 3 мин =="
podman logs --since 3m hipfire_hipfire_1 2>&1 | grep -iE 'error|panic|refus|429|overflow|queue' | head -8 || echo "(нет)
"
