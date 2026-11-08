#!/bin/bash
# hfctl (remote): поллинг health до готовности (loading_model == null).
# $1 = таймаут в секундах (по умолчанию 300).
set -u
TIMEOUT=${1:-300}
N=$(( TIMEOUT / 5 ))
URL=http://127.0.0.1:11435/health

last=""
for i in $(seq 1 $N); do
  s=$(curl -fsS "$URL" 2>/dev/null) && last=$s
  if echo "$s" | grep -q '"loading_model":null\|loading_model": null'; then
    echo "HEALTHY after $((i*5))s"
    echo "$s" | head -c 400; echo
    exit 0
  fi
  # Пока грузится / ещё не слушает — просто ждём
  sleep 5
done

echo "TIMEOUT: health не готов за ${TIMEOUT}s. Последний ответ: ${last:-<none>}" >&2
echo "== логи (последние 25 строк) =="
podman logs --tail 25 hipfire_hipfire_1 2>&1 | tail -25 || true
exit 1
