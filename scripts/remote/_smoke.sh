#!/bin/bash
# hfbox (remote): смоук — 3 запроса (код, проза, короткая математика) + health.
# Проверки: HTTP 200, finish_reason, связность глазами, dflash:true в логах.
set -u
URL=http://127.0.0.1:11435/v1/chat/completions
OUT="$HOME/hfbox-smoke"
mkdir -p "$OUT"
MODEL=${HF_MODEL:-qwen3.8:27b-mq4-xts}

ask() { # $1=файл $2=модель-параметр json сообщения
  curl -s -o "$OUT/$1" -w '%{http_code}' -X POST "$URL" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"max_tokens\":200,\"temperature\":0,\"reasoning_effort\":\"none\",\"messages\":[{\"role\":\"user\",\"content\":\"$2\"}]}"
}

echo "== health до"
curl -fsS http://127.0.0.1:11435/health | head -c 200; echo

echo "== запрос 1 (код)"
c1=$(ask r1.json 'Напиши на Python функцию is_palindrome(s) с docstring. TODO не пиши.')
echo "http=$c1"
echo "== запрос 2 (проза)"
c2=$(ask r2.json 'Пересказ одним предложением: что такое KV-кэш в трансформере?')
echo "http=$c2"
echo "== запрос 3 (короткая математика)"
c3=$(ask r3.json 'Сколько будет 17*23? Ответь только числом.')
echo "http=$c3"

python3 - <<'PY'
import json, os
out = os.path.expanduser("~/hfbox-smoke")
ok = True
for i in (1, 2, 3):
    f = f"{out}/r{i}.json"
    try:
        d = json.load(open(f))
        msg = d["choices"][0]["message"].get("content") or ""
        fin = d["choices"][0].get("finish_reason")
        df  = (d.get("hipfire") or {}).get("dflash")
        print(f"r{i}: finish={fin} dflash={df} chars={len(msg)} | {msg[:100]!r}")
        if fin not in ("stop", "length") or len(msg) < 1:
            ok = False
    except Exception as e:
        print(f"r{i}: PARSE FAIL: {e}; raw: {open(f).read()[:200]!r}")
        ok = False
print("SMOKE_RESULT:", "OK" if ok else "FAIL")
PY

echo "== dflash в логах за 3 мин:"
podman logs --since 3m hipfire_hipfire_1 2>&1 | grep -oiE 'dflash[^ ]*|spec[^,]*armed[^,]*' | sort | uniq -c | head -6 || echo "(строк нет)"
exit 0
