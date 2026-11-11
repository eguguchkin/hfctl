# shellcheck shell=bash
# ── health: ожидание готовности, смоук, фактический роут ──────────────────────
# Модуль не определяет собственных глобалов; читает PORT/CONTAINER/TPL_DIR
# (диспетчер) и cur_model (lib/stack.sh), пишет лог через log/warn/die.
# Вызывается из commands.sh (install/use), autostart.sh (up) и bench.sh (--fresh).

# Назначение: ждать готовности сервера — опрос GET /health каждые 5 с, пока
#   health_ok.py не примет ответ (status ok, model непустой, loading_model
#   не задан).
#
# Побочные эффекты: в stdout — log-строка ожидания, при успехе первые 300
#   байт тела /health и строка «HEALTHY после Nс», при неудаче — хвост логов
#   контейнера (podman logs) в stdout; warn() в stderr; подпроцессы
#   curl/python3/podman; спит по 5 с за итерацию; состояние стека не меняет.
#
# Ограничения/допущения: требуются глобалы PORT, CONTAINER, TPL_DIR и хелперы
#   log/warn (диспетчер). Локалы t/i одной строкой: t — целые секунды таймаута
#   (значение по умолчанию 900 при пропуске аргумента), i — истёкшие секунды
#   (кратно 5). Ранний выход по «pre-warm failed» в логах срабатывает только
#   после 120 с ожидания — таймаут меньше этого лишь отключает эту проверку.
#
# @param 1: integer  # таймаут в секундах (опциональный, default 900; живые вызовы: 600/900)
# @returns integer   # 0 — готов; 1 — pre-warm упал или таймаут (подробности в stdout/stderr)
wait_health() {
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

# Назначение: смоук-проверка живого сервера — 2 запроса к
#   /v1/chat/completions (проза «Ответь ровно: ок» + одна строка python-кода)
#   с max_tokens=200 и reasoning_effort=none; непустота content проверяет
#   smoke_resp.py.
#
# Побочные эффекты: 2 реальных запроса генерации к модели на
#   127.0.0.1:$PORT (curl -m 300); подпроцесс python3; в stdout — log-строка,
#   строки «ответ: <до 60 символов>» от smoke_resp.py и «SMOKE: OK»; при
#   провале — FATAL-строка die() в stderr. Файлы и конфиг не меняет.
#
# Ограничения/допущения: без параметров; требуются глобалы PORT, TPL_DIR и
#   log/die/cur_model (диспетчер/stack.sh). Сбой curl или пустой content
#   только помечают провал (ok=0) и дают второму запросу отработать; не-JSON
#   ответ даёт smoke_resp.py ненулевой rc со traceback в stderr. Провал —
#   die(): процесс диспетчера завершается с кодом 1, возврат функции
#   вызывающий перехватить не успевает.
#
# @returns integer # всегда 0 при возврате — провал завершает процесс через die() (exit 1)
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

# Назначение: единый снимок фактического роута («фактический роут» модуля):
#   один раз тянет хвост логов контейнера и извлекает движковые предикаты
#   (lanes staged / lanes refused / spec) + health-режим слотов — из него
#   питаются и check_route, и bench_route (критерии больше не расходятся:
#   кто последний сказал в логах, тот и роут).
#
# Побочные эффекты: подпроцессы podman logs (--tail 400, stderr слит в
#   stdout), curl GET /health (5 с) + python3 health_mode.py; ПИШЕТ глобалы
#   ROUTE_LOG/ROUTE_STAGED/ROUTE_REFUSED/ROUTE_SPEC/ROUTE_HEALTH; в stdout не
#   печатает.
#
# Ограничения/допущения: требует глобалы CONTAINER, PORT, TPL_DIR
#   (диспетчер). Глобалы (строки; '' = совпадения нет; ROUTE_HEALTH при
#   недоступном/нераспознанном /health = '?'): ROUTE_LOG — хвост логов,
#   ROUTE_STAGED/ROUTE_REFUSED/ROUTE_SPEC — последнее совпадение шаблона
#   (tail -1). Шаблоны grep — шесть принятых движковых швов (переехали
#   дословно из check_route/bench_route), тексты движка правятся здесь, а не
#   «чинятся». «|| true» при grep обязателен под set -e+pipefail: отсутствие
#   совпадения — норма (lanes приняты → refused нет; serial → staged нет).
#
# @returns integer # всегда 0 — отказы заглушены; пустые поля снимка — норма
route_snapshot() {
  ROUTE_LOG=$(podman logs --tail 400 "$CONTAINER" 2>&1 || true)
  ROUTE_STAGED=$(printf '%s' "$ROUTE_LOG" \
    | grep -oE "fn-lanes staged: topology=[a-z]+ lanes=[0-9]+[^\"]*spec=[a-z0-9]+" | tail -1) || true
  ROUTE_REFUSED=$(printf '%s' "$ROUTE_LOG" \
    | grep -oE "qwen4 lanes refused:[^-—]*" | tail -1) || true
  ROUTE_SPEC=$(printf '%s' "$ROUTE_LOG" \
    | grep -oE "spec: [a-z0-9 ]+" | tail -1 | head -c 60) || true
  ROUTE_HEALTH=$(curl -fsS -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null \
    | python3 "$TPL_DIR/python/health_mode.py" 2>/dev/null || echo '?')
  return 0
}

# Назначение: показать фактический роут профиля (spec §7): движок может
#   вежливо деградировать (vmm lanes refused → serial) — показываем реальность.
#   Источники — общий снимок route_snapshot (логи авторитетны, /health для
#   слотов).
#
# Побочные эффекты: через route_snapshot — podman logs / curl / python3
#   (см. его docblock); в stdout — строка роута («lanes: …», «роут:
#   multi_slot (…)» или «роут: singleton+DFlash (…)»); warn() в stderr при
#   отказе lanes. Ничего не меняет.
#
# Ограничения/допущения: требует warn (диспетчер) и route_snapshot этого
#   файла. Приоритет расхождений как на этапе 8: staged → refused → «данных
#   нет». Best-effort по дизайну: пустые поля снимка — штатные ветки («данных
#   нет», «?»); неизвестный prof попадает в default-ветку case
#   (singleton+DFlash). Тексты вывода — контракт (spec §7), не менять.
#
# @param 1: '27b-single' | '27b-slots' | 'flash-multi'   # канонический id профиля (вызывающие передают resolve_profile; неизвестный → singleton-ветка)
# @returns integer                                       # всегда 0 — информационная печать, отказы поиска заглушены
check_route() {
  local prof="$1"
  route_snapshot
  case "$prof" in
    flash-multi)
      if [ -n "$ROUTE_STAGED" ]; then
        echo "lanes: $ROUTE_STAGED"
        echo "      → настоящий батчинг принят (запросы делят trunk-шаг)"
      elif [ -n "$ROUTE_REFUSED" ]; then
        warn "vmm lanes ОТКАЗАНЫ: $ROUTE_REFUSED — сервер работает serial (fallback)"
        warn "тексты eligible-запросов всё равно исполняются корректно (singleton)"
      else
        echo "lanes: данных нет (ни staged, ни refused в логах) — проверь 'hfctl logs'"
      fi
      ;;
    27b-slots)  echo "роут: multi_slot ($ROUTE_HEALTH)" ;;
    *)          echo "роут: singleton+DFlash ($ROUTE_SPEC)" ;;
  esac
}
