# shellcheck shell=bash
wait_health() {  # wait_health [timeout_sec]
  local t="${1:-900}" i=0
  log "жду готовности (до ${t}с)"
  while [ "$i" -lt "$t" ]; do
    local body
    if body=$(curl -fsS -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null) && \
       printf '%s' "$body" | python3 "$TPL_DIR/python/health_ok.py" 2>/dev/null; then
      printf '%s\n' "$body" | head -c 300; echo
      echo "HEALTHY после ${i}с"
      return 0
    fi
    sleep 5; i=$((i+5))
    if [ "$i" -ge 120 ] && podman logs --since 10m "$CONTAINER" 2>&1 | grep -q "pre-warm failed"; then
      warn "pre-warm упал — ранний выход, последние логи:"
      podman logs --tail 25 "$CONTAINER" 2>&1 | tail -25 || true
      return 1
    fi
  done
  warn "не здоров через ${t}с — последние логи:"
  podman logs --tail 30 "$CONTAINER" 2>&1 | tail -30 || true
  return 1
}

smoke() {
  log "смоук: 2 запроса"
  local ok=1 prompt
  for prompt in "Ответь ровно: ок" "Напиши одну строку кода на python: hello world"; do
    local out
    out=$(curl -fsS -m 300 "http://127.0.0.1:$PORT/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$(cur_model)\",\"messages\":[{\"role\":\"user\",\"content\":\"$prompt\"}],\"max_tokens\":200,\"reasoning_effort\":\"none\"}" 2>/dev/null) || { ok=0; continue; }
    printf '%s' "$out" | python3 "$TPL_DIR/python/smoke_resp.py" || ok=0
  done
  [ "$ok" = 1 ] || die "смоук не прошёл — смотри 'hfctl logs'"
  echo "SMOKE: OK"
}

check_route() {  # check_route <profile> — фактический роут (spec §7): движок
  # может вежливо деградировать (vmm lanes refused → serial) — показываем реальность.
  # Источники: логи (fn-lanes staged / lanes refused — авторитетно) + health.
  local prof="$1" clog staged refused
  clog=$(podman logs --tail 400 "$CONTAINER" 2>&1 || true)
  # ВАЖНО: '|| true' обязателен — под set -e+pipefail grep без совпадения
  # (нормальный случай: lanes приняты, отказа нет) молча убивал весь скрипт
  staged=$(printf '%s' "$clog" | grep -oE "fn-lanes staged: topology=[a-z]+ lanes=[0-9]+[^\"]*spec=[a-z0-9]+" | tail -1) || true
  refused=$(printf '%s' "$clog" | grep -oE "qwen4 lanes refused:[^-—]*" | tail -1) || true
  case "$prof" in
    flash-multi)
      if [ -n "$staged" ]; then
        echo "lanes: $staged"
        echo "      → настоящий батчинг принят (запросы делят trunk-шаг)"
      elif [ -n "$refused" ]; then
        warn "vmm lanes ОТКАЗАНЫ: $refused — сервер работает serial (fallback)"
        warn "тексты eligible-запросов всё равно исполняются корректно (singleton)"
      else
        echo "lanes: данных нет (ни staged, ни refused в логах) — проверь 'hfctl logs'"
      fi
      ;;
    27b-slots)  echo "роут: multi_slot ($(curl -fsS -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null | python3 "$TPL_DIR/python/health_mode.py" 2>/dev/null || echo '?'))" ;;
    *)          echo "роут: singleton+DFlash ($(
                  printf '%s' "$clog" | grep -oE "spec: [a-z0-9 ]+" | tail -1 | head -c 60))" ;;
  esac
}
