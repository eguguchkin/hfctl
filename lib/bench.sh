# shellcheck shell=bash
# ── bench (spec Э-2): локальный бенч производительности ─────────────────────
# Принципы: конфиг сервера НЕ трогаем (ar-baseline = пропуск, сравнение рук —
# через use); сервер трогаем только с --fresh; честные цифры — wall curl +
# usage, τ/TTFT — best-effort из логов движка (нет данных = пусто, не выдумываем).
# Python-помощники живут в tpl/python/ (контракты — spec/task-8.md Design §4),
# многострочные awk — в tpl/awk/, фикстура — в tpl/bench/.
# @type /^[\da-f]{32}$/ # канонический md5 фикстуры solo-code (tpl/bench/merge_sort_thinking_off.txt);
#   несовпадение при прогоне — warn, сравнимость замеров и --compare под вопросом
BENCH_FIXTURE_MD5=253c7ac50857fe6d0e10fb0d2c5e35c0

# Назначение: напечатать usage-справку `hfctl bench` (heredoc: режимы, флаги,
#   артефакт).
#
# Побочные эффекты: только stdout; читает глобал STACK_DIR (путь каталога
#   артефактов подставляется в текст). Сеть, файлы, сервер не трогает.
#
# Ограничения/допущения: без параметров; текст не выведен из кода cmd_bench —
#   при смене флагов/сценариев правится руками синхронно.
#
# @returns integer # всегда 0
bench_help() {
  cat <<EOF
hfctl bench — бенч производительности сервера (локально, без ssh)

  hfctl bench                  quick: 3 сценария (solo-code, solo-prose, ttft), ≤90 c
  hfctl bench full             все 8 сценариев: + prefill-100k, long-gen,
                               parallel N=2/N=4, HOL, ar-baseline
  hfctl bench --runs N         повторов на сценарий (default 3, допустимо 1–20)
  hfctl bench --parallel N[,M…] параллельные батчи поверх quick/full (целые
                               1..8 через запятую; каждый — один прогон;
                               full без флага = 2,4)
  hfctl bench --out DIR        каталог артефактов (default $STACK_DIR/bench-runs)
  hfctl bench --json           машиночитаемый JSON в stdout (артефакт всё равно пишется)
  hfctl bench --compare [FILE] дельта с прошлым прогоном (без FILE — свежайший json)
  hfctl bench --fresh          перед прогоном recreate+wait_health — ЕДИНСТВЕННЫЙ
                               режим, трогающий сервер

Сервер должен работать (hfctl up). Конфиг сервера bench не меняет, поэтому
ar-baseline (без спекуляции) печатается как пропущенный: сравнение рук —
через 'hfctl use' разных профилей.
Артефакт: $STACK_DIR/bench-runs/<timestamp>.json — база для --compare.
Ctrl-C (SIGINT) или SIGTERM прерывают прогон на любой фазе: частичный прогон
не сохраняется, начатые запросы доубиваются (rc 130/143).
EOF
}

# Назначение: фактический роут обслуживания в enum артефакта bench — из
#   общего снимка route_snapshot (health.sh): для flash-multi — принятый
#   ROUTE_STAGED (снимок уже снимает его при свежем отказе lanes →
#   serial-fallback), для 27b-slots — «multi-slot» статически (константа
#   артефакта --compare; live-режим слотов печатается отдельно через
#   bench_slots по /health), иначе — последнее «spec: …» в логах
#   (singleton-dflash) либо serial.
#
# Побочные эффекты: через route_snapshot — podman logs / curl / python3
#   (ошибка логов = пустые поля снимка, не отказ); в stdout — одна строка
#   роута. Сеть и файлы не трогает.
#
# Ограничения/допущения: любой неизвестный prof попадает в singleton-ветку
#   case; отсутствие строк в логах — не ошибка: пустые поля дают
#   serial-fallback/serial. Формат enum — контракт артефакта (--compare),
#   значения не менять.
#
# @param 1: '27b-single' | '27b-slots' | 'flash-multi'                                           # канонический id профиля (важны flash-multi/27b-slots; прочее → singleton-ветка)
# @stdout 'lanes' | 'serial-fallback' | 'multi-slot' | 'singleton-dflash' | 'singleton-serial'   # фактический роут (см. Назначение); печатается echo с переводом строки
# @returns integer                                                                               # всегда 0 — отказы поиска заглушены в route_snapshot
bench_route() {
  local prof="$1"
  route_snapshot
  case "$prof" in
    flash-multi) [ -n "$ROUTE_STAGED" ] && echo "lanes" || echo "serial-fallback" ;;
    27b-slots)
      echo "multi-slot" ;;
    *)
      case "$ROUTE_SPEC" in
        "spec: dflash"*) echo "singleton-dflash" ;;
        *)               echo "singleton-serial" ;;
      esac ;;
  esac
}

# Назначение: фактическое число слотов multi-slot из capabilities живого
#   /health (tpl/python/bench_slots.py), с фолбэком на глобал $SLOTS при
#   любой неудаче чтения/разбора.
#
# Побочные эффекты: HTTP GET /health через curl (localhost, таймаут 5 с) +
#   подпроцесс python3; в stdout — число слотов; читает глобалы PORT, SLOTS.
#   Файлы и сервер не меняет.
#
# Ограничения/допущения: сервер недоступен, не-JSON ответ или пустой
#   capabilities.multi_slot_slots — python печатает пустое либо падает, и
#   всегда возвращается $SLOTS; функция не может завершиться ошибкой.
#
# @stdout /\d+/      # число слотов (при пустом /health — значение глобала SLOTS)
# @returns integer   # всегда 0
bench_slots() {
  local s
  s=$(curl -fsS -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null | python3 "$TPL_DIR/python/bench_slots.py" 2>/dev/null || true)
  echo "${s:-$SLOTS}"
}

# Назначение: собрать OpenAI-payload JSON (model — cur_model(), temperature 0,
#   reasoning_effort "none", max_tokens $3, stream при $4=1) через
#   tpl/python/bench_payload.py.
#
# Побочные эффекты: ПЕРЕЗАПИСЬ файла $1; читает текстовый промпт $2 как есть;
#   подпроцесс python3; читает глобалы TPL_DIR и текущую модель (cur_model).
#
# Ограничения/допущения: reasoning_effort "none" и temperature 0 зашиты в
#   генератор (защита коротких max_tokens от thinking-бюджета — грабля
#   hflab №1); отсутствующий/нечитаемый $2 или нечисловой $3 — python падает
#   с ненулевым rc (под set -e команда вызывающего прерывается).
#
# @param 1: string        # путь выходного payload (.json, перезаписывается)
# @param 2: string        # путь текстового файла промпта (содержимое → messages)
# @param 3: /\d+/         # max_tokens запроса
# @param 4: '0' | '1'     # стриминг (опциональный, default '0')
# @returns integer        # 0 — payload записан; ненулевой — ошибка python
bench_payload() {
  python3 "$TPL_DIR/python/bench_payload.py" \
    "$1" "$2" "$3" "${4:-0}" "$(cur_model)"
}

# Назначение: один замеряемый запрос к живому серверу: curl POST
#   /v1/chat/completions с payload $1 (wall — разница date до/после curl),
#   разбор usage через tpl/python/bench_req.py; stdout —
#   «wall prompt_tokens completion_tokens».
#
# Побочные эффекты: РЕАЛЬНАЯ генерация у модели по сети (расходует токены;
#   таймаут curl = $3 секунд); ПЕРЕЗАПИСЬ файла $2 сырым ответом (при ошибке
#   curl там остаётся частичное/пустое); подпроцессы curl/awk/python3/date;
#   читает глобалы PORT, TPL_DIR.
#
# Ограничения/допущения: сервер должен быть ready (готовность — забота
#   вызывающего cmd_bench/wait_health); в теле обязателен явный if/return:
#   bare `cmd || return $?` внутри $( ) под set -e уносит весь скрипт
#   (комментарий в теле); prompt_tokens отсутствует в usage — python печатает 0.
#
# @param 1: string             # путь payload JSON (от bench_payload)
# @param 2: string             # путь файла сырого ответа (перезаписывается)
# @param 3: /\d+/              # таймаут curl, целые секунды
# @stdout /^[\d.]+ \d+ \d+$/   # «wall prompt_tokens completion_tokens»: wall — float (с, 3 знака), прочее — целые
# @returns integer             # 0 — строка на stdout; 1 — curl без ответа/ошибка; 3 — ответ не JSON; 4 — usage нет (caller: WARN+пропуск)
bench_req() {
  # ВАЖНО: явный if/return, не 'cmd || return $?' — внутри $( ) с set -e
  # bare-return уносит весь скрипт (bash-семантика выхода из подстановки).
  local pay="$1" resp="$2" to="$3" rc=0 t0 t1
  t0=$(date +%s.%N)
  if ! curl -fsS -m "$to" "http://127.0.0.1:$PORT/v1/chat/completions" \
       -H 'Content-Type: application/json' --data-binary @"$pay" > "$resp" 2>/dev/null; then
    return 1
  fi
  t1=$(date +%s.%N)
  rc=0
  awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f\n", b-a}' | python3 "$TPL_DIR/python/bench_req.py" "$resp" || rc=$?
  return "$rc"
}

# Назначение: последний τ движка из логов контейнера за последние $1 секунд
#   (grep «τ=»/«tau=», tail -1); пустой stdout = данных в логах нет
#   (best-effort, не выдумываем).
#
# Побочные эффекты: подпроцесс podman logs (только чтение логов); в stdout —
#   значение τ без перевода строки; читает глобал CONTAINER.
#
# Ограничения/допущения: $1 — целые секунды «от сейчас»: вызывающие передают
#   дельту своего start с запасом +2 с; при нескольких τ-строках за окно
#   берётся последняя.
#
# @param 1: /\d+/          # секунд назад (передаётся в podman logs --since)
# @stdout '' | /^[\d.]+$/  # τ движка либо пустая строка (данных в логах нет)
# @returns integer         # всегда 0 (grep мимо заглушён «|| true»)
bench_tau() {
  local tau
  tau=$(podman logs --since "${1}s" "$CONTAINER" 2>&1 | grep -oE "(τ|tau)=[0-9.]+" | tail -1) || true
  printf '%s' "${tau#*=}"
}

# Назначение: медиана чисел колонки $2 сценария $1 по
#   $BENCH_TMP/runs.tsv (awk-фильтр → sort -g → tpl/awk/bench_med.awk);
#   пустой stdout = чисел для сценария/колонки нет.
#
# Побочные эффекты: чтение $BENCH_TMP/runs.tsv; подпроцессы awk/sort/awk;
#   в stdout — медиана (printf %.3f, без перевода строки). Ничего не пишет.
#
# Ограничения/допущения: пустой/отсутствующий runs.tsv → сразу 0 без вывода;
#   пустые значения и «-» в колонке в медиану не попадают; глобал BENCH_TMP
#   (mktemp-каталог cmd_bench) обязателен; колонка 1 — имя сценария, медиана
#   по ней не считается.
#
# @param 1: string        # ключ сценария (колонка 1 runs.tsv)
# @param 2: /\d+/         # номер колонки 2..6 (2=wall, 3=tokens, 4=tok_s, 5=τ, 6=ttft_ms)
# @stdout '' | /^[\d.]+$/ # медиана (awk печатает %.3f) либо пусто
# @returns integer        # всегда 0
bench_med() {
  [ -s "$BENCH_TMP/runs.tsv" ] || return 0
  awk -F'\t' -v s="$1" -v c="$2" '$1==s && $c!="" && $c!="-" {print $c}' "$BENCH_TMP/runs.tsv" \
    | sort -g \
    | awk -f "$TPL_DIR/awk/bench_med.awk"
}

# Назначение: соло-сценарий: RUNS прогонов bench_req (payload из промпта $2 с
#   max_tokens $3); каждый успешный прогон — строка в runs.tsv: wall,
#   completion_tokens, tok/s = tokens/wall, τ из логов (колонки 2–5).
#
# Побочные эффекты: RUNS РЕАЛЬНЫХ генераций у модели (сеть, токены; таймаут
#   300 с); ПЕРЕЗАПИСЬ $BENCH_TMP/solo.json (payload) и
#   $BENCH_TMP/solo_resp (сырой ответ); допись строк в $BENCH_TMP/runs.tsv;
#   warn-строки в stderr; подпроцессы через bench_payload/bench_req/bench_tau
#   (curl/awk/python3/date/podman).
#
# Ограничения/допущения: сервер ready; файл промпта $2 уже создан вызывающим
#   cmd_bench (фикстура solo-code — с md5-гейтом); глобалы RUNS, BENCH_TMP,
#   PORT, CONTAINER, TPL_DIR обязательны; неудачный прогон — WARN и пропуск,
#   все прогоны неудачны — сценарий просто не попадает в таблицу.
#
# @param 1: 'solo-code' | 'solo-prose'  # ключ сценария для колонки 1 runs.tsv
# @param 2: string                      # путь текстового файла промпта
# @param 3: /\d+/                       # max_tokens
# @returns integer                      # всегда 0 (неудачи прогонов — warn, не rc)
bench_solo() {
  local sc="$1" cf="$2" mt="$3" i out w pt toks tk tau start ok=0
  bench_payload "$BENCH_TMP/solo.json" "$cf" "$mt"
  start=$(date +%s)
  for i in $(seq 1 "$RUNS"); do
    if out=$(bench_req "$BENCH_TMP/solo.json" "$BENCH_TMP/solo_resp" 300); then
      read -r w pt toks <<<"$out"
      tk=$(awk -v t="$toks" -v s="$w" 'BEGIN{ if (s+0>0) printf "%.2f", t/s; else print "" }')
      tau=$(bench_tau "$(( $(date +%s) - start + 2 ))")
      printf '%s\t%s\t%s\t%s\t%s\t-\n' "$sc" "$w" "$toks" "$tk" "$tau" >> "$BENCH_TMP/runs.tsv"
      ok=$((ok+1))
    else
      warn "$sc: прогон $i не удался (curl/usage) — пропущен"
    fi
  done
  [ "$ok" -gt 0 ] || warn "$sc: все прогоны не удались — сценарий пропущен"
  return 0
}

# Назначение: сценарий ttft: RUNS стриминг-запросов (max_tokens 8, stream=1)
#   через tpl/python/ttft.py — время до первого content-chunk в миллисекундах;
#   результат — колонка 6 (ttft_ms) строк runs.tsv.
#
# Побочные эффекты: RUNS РЕАЛЬНЫХ стриминг-запросов к модели (сеть, токены;
#   внутренний таймаут python 120 с); ПЕРЕЗАПИСЬ $BENCH_TMP/ttft.json (payload);
#   допись строк ttft в $BENCH_TMP/runs.tsv; warn в stderr; подпроцессы
#   python3/awk/date (через bench_payload).
#
# Ограничения/допущения: промпт $BENCH_TMP/c_ttft.txt создаёт заранее
#   cmd_bench; глобалы RUNS, BENCH_TMP, PORT, TPL_DIR обязательны; python
#   печатает «null»/«ERR …» при отсутствии content или сетевой ошибке —
#   такой прогон идёт WARN и пропускается; таймаут 120 с зашит в python и
#   не параметризован.
#
# @returns integer # всегда 0 (неудачи прогонов — warn, не rc)
bench_ttft() {
  local i ttft ok=0
  bench_payload "$BENCH_TMP/ttft.json" "$BENCH_TMP/c_ttft.txt" 8 1
  for i in $(seq 1 "$RUNS"); do
    ttft=$(python3 "$TPL_DIR/python/ttft.py" "http://127.0.0.1:$PORT/v1/chat/completions" \
             "$BENCH_TMP/ttft.json" 2>/dev/null || true)
    case "$ttft" in
      ""|null|ERR*) warn "ttft: прогон $i — стрим не дал content — пропущен"; continue ;;
    esac
    printf 'ttft\t-\t-\t-\t-\t%s\n' "$ttft" >> "$BENCH_TMP/runs.tsv"
    ok=$((ok+1))
  done
  [ "$ok" -gt 0 ] || warn "ttft: все прогоны не удались — сценарий пропущен"
  return 0
}

# Назначение: сценарий prefill-100k: развёртка кодовой фикстуры до ~100K
#   токенов (tpl/python/prefill_gen.py, оценка 4 симв/ток), RUNS запросов с
#   max_tokens 16; в runs.tsv колонка 3 = usage.prompt_tokens, колонка 4 =
#   prompt_tokens/(wall − время decode-16-ток при известной MED_SOLO_CODE).
#
# Побочные эффекты: RUNS РЕАЛЬНЫХ префилл-запросов ~100K токенов (сеть,
#   дорого по вычислению и времени; таймаут 600 с; генерация минимальна —
#   16 токенов); запись $BENCH_TMP/c_prefill.txt, ПЕРЕЗАПИСЬ prefill.json/
#   prefill_resp; допись строк prefill-100k в runs.tsv; log/warn-строки;
#   подпроцессы python3/awk/date/podman (через bench_req/bench_tau).
#
# Ограничения/допущения: сервер ready; требует $BENCH_TMP/c_code.txt
#   (md5-фикстура, создаёт cmd_bench) и глобалы RUNS, BENCH_TMP, PORT,
#   CONTAINER; MED_SOLO_CODE опционален: пуст → decode не вычитается
#   (пояснение cmd_bench пишет в B_NOTE_prefill_100k); max_tokens 16
#   фиксирован по дизайну сценария.
#
# @returns integer # всегда 0 (неудачи прогонов — warn, не rc)
bench_prefill() {
  local i out w pt toks dec we rate ok=0
  python3 "$TPL_DIR/python/prefill_gen.py" "$BENCH_TMP/c_code.txt" "$BENCH_TMP/c_prefill.txt"
  log "prefill-100k: промпт ~$(( $(wc -c < "$BENCH_TMP/c_prefill.txt") / 4 )) tok (оценка 4 симв/ток; факт — usage.prompt_tokens)"
  bench_payload "$BENCH_TMP/prefill.json" "$BENCH_TMP/c_prefill.txt" 16
  local start; start=$(date +%s)
  for i in $(seq 1 "$RUNS"); do
    if out=$(bench_req "$BENCH_TMP/prefill.json" "$BENCH_TMP/prefill_resp" 600); then
      read -r w pt toks <<<"$out"
      dec=""; we="$w"
      if [ -n "${MED_SOLO_CODE:-}" ]; then
        dec=$(awk -v m="$MED_SOLO_CODE" 'BEGIN{ if (m+0>0) printf "%.3f", 16/m; else print "" }') || true
        [ -n "$dec" ] && we=$(awk -v s="$w" -v d="$dec" 'BEGIN{ printf "%.3f", (s+0>d+0 ? s-d : s) }') || true
      fi
      rate=$(awk -v t="$pt" -v s="$we" 'BEGIN{ if (s+0>0) printf "%.1f", t/s; else print "" }')
      printf 'prefill-100k\t%s\t%s\t%s\t-\t-\n' "$w" "$pt" "$rate" >> "$BENCH_TMP/runs.tsv"
      ok=$((ok+1))
    else
      warn "prefill-100k: прогон $i не удался — пропущен"
    fi
  done
  [ "$ok" -gt 0 ] || warn "prefill-100k: все прогоны не удались — сценарий пропущен"
  return 0
}

# Назначение: сценарий long-gen: RUNS генераций по 4096 токенов (таймаут
#   600 с); стабильность движка «первая → последняя tok/s» из логов за прогон
#   (best-effort) — в экспорт B_NOTE_long_gen для таблицы отчётника.
#
# Побочные эффекты: RUNS РЕАЛЬНЫХ длинных генераций (сеть, много токенов,
#   минуты времени); ПЕРЕЗАПИСЬ $BENCH_TMP/long.json и long_resp; допись
#   строк long-gen в runs.tsv; подпроцессы podman logs + grep/cut/sed/tail;
#   EXPORT глобала B_NOTE_long_gen; warn в stderr.
#
# Ограничения/допущения: сервер ready; требует $BENCH_TMP/c_long.txt (создаёт
#   cmd_bench) и глобалы RUNS, BENCH_TMP, PORT, CONTAINER, TPL_DIR; нет
#   tok/s-строк в логах → note «движковый tok/s в логах нет», не ошибка;
#   движковые tok/s — только заметка таблицы, в runs.tsv не попадает.
#
# @returns integer # всегда 0 (неудачи прогонов — warn, не rc)
bench_longgen() {
  local i out w pt toks tk ok=0 first last vals start
  bench_payload "$BENCH_TMP/long.json" "$BENCH_TMP/c_long.txt" 4096
  start=$(date +%s)
  for i in $(seq 1 "$RUNS"); do
    if out=$(bench_req "$BENCH_TMP/long.json" "$BENCH_TMP/long_resp" 600); then
      read -r w pt toks <<<"$out"
      tk=$(awk -v t="$toks" -v s="$w" 'BEGIN{ if (s+0>0) printf "%.2f", t/s; else print "" }')
      printf 'long-gen\t%s\t%s\t%s\t-\t-\n' "$w" "$toks" "$tk" >> "$BENCH_TMP/runs.tsv"
      ok=$((ok+1))
    else
      warn "long-gen: прогон $i не удался — пропущен"
    fi
  done
  vals=$(podman logs --since "$(( $(date +%s) - start + 2 ))s" "$CONTAINER" 2>&1 \
         | grep -oE "tok/s=[0-9.]+" | cut -d= -f2) || true
  first=$(printf '%s\n' "$vals" | sed -n '1p')
  last=$(printf '%s\n' "$vals" | tail -1)
  if [ -n "$first" ] && [ -n "$last" ]; then
    export B_NOTE_long_gen="движок: $first → $last tok/s (первая → последняя)"
  else
    export B_NOTE_long_gen="движковый tok/s в логах нет (best-effort)"
  fi
  [ "$ok" -gt 0 ] || warn "long-gen: все прогоны не удались — сценарий пропущен"
  return 0
}

# Назначение: сценарий parallel-N: N одновременных curl (чередование
#   проза/код, max_tokens 300); в runs.tsv строка parallel-$n: wall всего
#   батча, Σ completion_tokens, aggregate tok/s; в stdout — интерпретация по
#   роуту (lanes: aggregate/solo в %; multi-slot: очередь слотов; иначе:
#   FIFO «aggregate ≈ solo»), per-request wall — в экспорт
#   B_NOTE_parallel_$n.
#
# Побочные эффекты: N РЕАЛЬНЫХ параллельных генераций (сеть, токены; таймаут
#   300 с на запрос, N параллельных subshell'ов curl+date+awk); удаляет
#   старые $BENCH_TMP/par_resp_* и par_wall_*, пишет par$i.json,
#   par_resp_$i, par_wall_$i; допись parallel-$n в runs.tsv (колонка 7 —
#   per-request wall по позиции запуска через запятую, только валидные i);
#   EXPORT B_NOTE_parallel_$n; строки интерпретации в stdout, warn в stderr;
#   подпроцессы python3 (par_usage.py), awk, curl, date; читает глобалы
#   ROUTE, MED_SOLO_CODE, BENCH_TMP, TPL_DIR (через bench_med/bench_slots).
#
# Ограничения/допущения: сервер ready; требует $BENCH_TMP/c_prose.txt и
#   c_code.txt (создаёт cmd_bench) и глобалы ROUTE (интерпретация),
#   BENCH_TMP, PORT; MED_SOLO_CODE опционален — без него процент
#   масштабирования не считается; запрос без ответа/usage — warn и вне суммы
#   И вне walls; нулевая сумма — сценарий пропущен (всё равно 0);
#   интерпретация зовёт bench_slots (ещё один GET /health) на multi-slot;
#   порядок walls = порядок запуска (позиция в FIFO), НЕ сортируется.
#
# @param 1: /\d+/      # N — число одновременных запросов (cmd_bench даёт PAR_LIST 1..8)
# @returns integer     # всегда 0 (частичные неудачи — warn, не rc)
bench_parallel() {
  local n="$1" i t0 t1 tw sum tk fails=0 pw="" walls=""
  for i in $(seq 1 "$n"); do
    if [ $((i % 2)) = 1 ]; then
      bench_payload "$BENCH_TMP/par$i.json" "$BENCH_TMP/c_prose.txt" 300
    else
      bench_payload "$BENCH_TMP/par$i.json" "$BENCH_TMP/c_code.txt" 300
    fi
  done
  rm -f "$BENCH_TMP"/par_resp_* "$BENCH_TMP"/par_wall_*
  t0=$(date +%s.%N)
  for i in $(seq 1 "$n"); do
    (
      w0=$(date +%s.%N)
      curl -fsS -m 300 "http://127.0.0.1:$PORT/v1/chat/completions" \
        -H 'Content-Type: application/json' --data-binary @"$BENCH_TMP/par$i.json" \
        > "$BENCH_TMP/par_resp_$i" 2>/dev/null || true
      w1=$(date +%s.%N)
      awk -v a="$w0" -v b="$w1" 'BEGIN{printf "%.1f\n", b-a}' > "$BENCH_TMP/par_wall_$i"
    ) &
  done
  wait
  t1=$(date +%s.%N)
  tw=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')
  sum=0
  for i in $(seq 1 "$n"); do
    tk=""
    if [ -s "$BENCH_TMP/par_resp_$i" ]; then
      tk=$(python3 "$TPL_DIR/python/par_usage.py" "$BENCH_TMP/par_resp_$i" 2>/dev/null || true)
    fi
    case "$tk" in
      ''|*[!0-9]*) fails=$((fails+1)) ;;
      *) sum=$((sum+tk))
         # walls — только валидные i, порядок запуска (= позиция в FIFO), не сортируем
         [ -s "$BENCH_TMP/par_wall_$i" ] && walls="${walls}${walls:+,}$(cat "$BENCH_TMP/par_wall_$i")" ;;
    esac
  done
  [ "$fails" = 0 ] || warn "parallel-$n: $fails из $n запросов не удались (curl/usage)"
  if [ "$sum" -eq 0 ]; then
    warn "parallel-$n: ни одного ответа с usage — сценарий пропущен"
    return 0
  fi
  printf 'parallel-%s\t%s\t%s\t%s\t-\t-\t%s\n' "$n" "$tw" "$sum" \
    "$(awk -v s="$sum" -v s2="$tw" 'BEGIN{printf "%.2f", s/s2}')" "${walls:--}" >> "$BENCH_TMP/runs.tsv"
  if [ -n "$walls" ]; then
    pw=$(printf '%s' "$walls" | awk -F',' '
      { s=""; mn=$1; mx=$1
        for (i=1; i<=NF; i++) { s = s (i > 1 ? " " : "") $i "с"
          if ($i+0 < mn+0) mn=$i; if ($i+0 > mx+0) mx=$i }
        if (NF > 1) s = s sprintf(" (разброс %s–%s с)", mn, mx)
        printf "%s", s }')
    export B_NOTE_parallel_$n="per-request wall (curl, по позиции запуска): $pw"
  else
    export B_NOTE_parallel_$n="per-request wall (curl): нет данных"
  fi
  case "$ROUTE" in
    lanes)
      if [ -n "${MED_SOLO_CODE:-}" ]; then
        awk -v a="$(bench_med "parallel-$n" 4)" -v s="$MED_SOLO_CODE" -v n="$n" \
          'BEGIN{ if (s+0>0) printf "parallel-%s: масштабирование: aggregate/solo = %.0f%%\n", n, a/s*100 }'
      else
        echo "parallel-$n: aggregate $(bench_med "parallel-$n" 4) tok/s (соло-рейт неизвестен — процент не посчитать)"
      fi ;;
    multi-slot)
      echo "parallel-$n: очередь слотов (слотов=$(bench_slots)): N>$(bench_slots) ждут свободный слот" ;;
    *)
      echo "parallel-$n: FIFO: aggregate ≈ solo — норма для serial-роута" ;;
  esac
  return 0
}

# Назначение: сценарий hol (head-of-line): длинный запрос (800 токенов) в
#   фоне, через 2 с короткий (8 токенов); wall короткого — строка runs.tsv;
#   отдельно снятый сольный референс короткого (вне таблицы) — глобал
#   BENCH_HOL_REF, по нему cmd_bench считает % изоляции (tpl/awk/hol_note.awk).
#
# Побочные эффекты: 2 РЕАЛЬНЫХ запроса за прогон (длинный — фоновый curl с
#   таймаутом 600 с, короткий — через bench_req с таймаутом 120 с) +
#   background curl subshell, sleep 2; ПЕРЕЗАПИСЬ $BENCH_TMP/hol_long.json,
#   hol_short.json и hol_*_resp-файлов; допись строк hol в runs.tsv (wall
#   короткого — колонка 2); присваивание глобала BENCH_HOL_REF ('' — сольный
#   референс не удался); warn в stderr.
#
# Ограничения/допущения: сервер ready; требует $BENCH_TMP/c_long.txt и
#   c_ttft.txt (создаёт cmd_bench) и глобалы RUNS, BENCH_TMP, PORT; длинный
#   доигрывает wait'ом до следующего прогона (его rc проигнорирован); смысл
#   цифр зависит от ROUTE: FIFO — короткий ждёт длинный целиком, slots/lanes
#   дают изоляцию; сольный референс в runs.tsv НЕ пишется.
#
# @returns integer # всегда 0 (неудачи прогонов — warn, не rc)
bench_hol() {
  local i out ok=0 ref_w="" w0 lpid
  bench_payload "$BENCH_TMP/hol_long.json" "$BENCH_TMP/c_long.txt" 800
  bench_payload "$BENCH_TMP/hol_short.json" "$BENCH_TMP/c_ttft.txt" 8
  # сольный референс короткого (1 прогон, вне таблицы)
  if out=$(bench_req "$BENCH_TMP/hol_short.json" "$BENCH_TMP/hol_ref_resp" 120); then
    read -r ref_w _ <<<"$out"
  fi
  BENCH_HOL_REF="$ref_w"
  for i in $(seq 1 "$RUNS"); do
    curl -fsS -m 600 "http://127.0.0.1:$PORT/v1/chat/completions" \
      -H 'Content-Type: application/json' --data-binary @"$BENCH_TMP/hol_long.json" \
      > "$BENCH_TMP/hol_long_resp" 2>/dev/null &
    lpid=$!
    sleep 2
    if out=$(bench_req "$BENCH_TMP/hol_short.json" "$BENCH_TMP/hol_short_resp" 120); then
      read -r w0 _ <<<"$out"
      printf 'hol\t%s\t-\t-\t-\t-\n' "$w0" >> "$BENCH_TMP/runs.tsv"
      ok=$((ok+1))
    else
      warn "HOL: короткий запрос не удался — прогон пропущен"
    fi
    wait "$lpid" 2>/dev/null || true   # длинный доигрывает до следующего прогона
  done
  [ "$ok" -gt 0 ] || warn "HOL: все прогоны не удались — сценарий пропущен"
  return 0
}

# Назначение: обработчик прерывания bench (INT/TERM-трап cmd_bench): заглушить
#   трапы, убить дочерние процессы (foreground curl/python + фоновые subshell'ы
#   параллельного блока И curl'ы внутри них — последние наследуют SIGINT
#   «ignored» и сами не умирают), дождаться их, напечатать сообщение и выйти
#   с rc 130/143; temp чистится существующим EXIT-trap'ом при exit.
#
# Побочные эффекты: SIGTERM всем прямым детям cmd_bench и детям его фоновых
#   заданий (pkill -P); stdout — ничего, stderr — строка «прервано …»;
#   завершает процесс (exit 130/143), чем запускает EXIT-trap (rm -rf BENCH_TMP).
#   Артефакт не пишется (его запись — после всех сценариев, сюда мы не доходим).
#
# Ограничения/допущения: вызывается ТОЛЬКО как trap-команда cmd_bench после
#   создания BENCH_TMP (иначе rc-выход без temp не страшен, а EXIT-trap
#   справится с пустым каталогом). SIGTERM выбран для убийства детей, т.к.
#   фоновые джобы игнорируют INT. Если сам cmd_bench стартовал с SIGINT
#   «ignored» на входе (фоновый запуск из скрипта — грабля EXP-102), bash
#   trap INT не поставит (POSIX) — прерываемость гарантирована при обычной
#   диспозиции (терминал Ctrl-C, kill группы нормально запущенного процесса).
#   Пока bash ждёт foreground-ребёнка, трап откладывается до его смерти — при
#   Ctrl-C/kill ГРУППЫ curl получает сигнал тоже и умирает сразу.
#
# @param 1: 'INT' | 'TERM'  # имя сигнала для сообщения
# @param 2: '130' | '143'   # rc (128+signum)
# @returns integer          # не возвращается — завершает процесс через exit
bench_abort() {
  local sig="$1" rc="$2" p
  trap - INT TERM
  # Порядок важен: сначала ВНУТРЕННИЕ дети фоновых subshell'ов (curl'ы), пока
  # их родители живы и PPid совпадает, — иначе после гибели subshell'а curl
  # переописывается и -P его не находит.
  for p in $(jobs -p 2>/dev/null); do
    pkill -TERM -P "$p" 2>/dev/null || true        # curl/process-group-потомки внутри них
  done
  pkill -TERM -P $$ 2>/dev/null || true            # foreground-дети + фоновые subshell'ы
  wait 2>/dev/null || true
  printf 'bench: прервано (%s) — незавершённый прогон НЕ сохранён\n' "$sig" >&2
  exit "$rc"
}

# Назначение: `hfctl bench` — локальный бенч производительности живого
#   сервера: фикстуры + md5-гейт → health (с --fresh — recreate+wait_health)
#   → прогрев → сценарии (quick: solo-code, solo-prose, ttft; full: ещё
#   prefill-100k, long-gen, parallel из --parallel (дефолт 2/4), HOL;
#   ar-baseline печатается пропущенным) → артефакт JSON, таблица
#   (bench_report.py report) и дельта --compare. quick с --parallel —
#   параллельные батчи поверх quick-тройки (после снятия MED_SOLO_CODE).
#
# Побочные эффекты:
#   Файлы: mktemp-каталог BENCH_TMP с trap 'rm -rf' на EXIT (runs.tsv,
#     payload-*.json, *_resp, c_*.txt, artifact.json); INT/TERM-трап
#     (bench_abort) — прерывание с rc 130/143 без артефакта, см. bench_help;
#     артефакт
#     $OUT/<timestamp>.json (default $STACK_DIR/bench-runs, mkdir -p) —
#     база будущих --compare; копирование фикстуры tpl/bench в c_code.txt
#     (байты-в-байты, md5-гейт — warn при несовпадении, НЕ die) и трёх
#     ad-hoc промптов (prose/ttft/long/warm); чтение .env через env_val
#     (HIPFIRE_PORT переопределяет глобал PORT, HIPFIRE_IMAGE уходит в
#     артефакт).
#   Сеть/сервер: РЕАЛЬНЫЕ генерации — прогрев + (quick) 2×RUNS генераций и
#     RUNS стримингов; (full) ещё RUNS×(prefill ~100K токенов, long-gen
#     4096 токенов, параллельные батчи из PAR_LIST за батч, HOL-пары;
#     quick с --parallel — те же параллельные батчи поверх тройки); GET /health +
#     wait_health 900 при незавершенной загрузке модели; с --fresh —
#     compose up -d --force-recreate (ЕДИНСТВЕННЫЙ режим, трогающий сервер)
#     и повторный wait_health 900.
#   Глобалы/окружение: RUNS, OUT, ROUTE, BENCH_TMP, MED_SOLO_CODE,
#     BENCH_HOL_REF; EXPORT B_RUNS/B_TS/B_PROFILE/B_MODEL/B_ROUTE/B_IMAGE/
#     B_MD5/B_FULL и B_NOTE_* (контракт python-отчётника bench_report.py);
#     при --json перенаправление fd: человеческий вывод в stderr, JSON
#     артефакта в исходный stdout через fd 4.
#
# Ограничения/допущения: стек установлен (.env — иначе die) и сервер отвечает
#   (die при отказе GET /health); модель ждём до готовности (до 900 с);
#   конфиг сервера НЕ меняется (ar-baseline — пропуск, сравнение рук через
#   'hfctl use'); фикстуру не редактировать: md5 ≠ BENCH_FIXTURE_MD5 → warn;
#   все запросы идут через bench_payload (temperature 0, reasoning_effort
#   none — защита коротких max_tokens от thinking-бюджета); неизвестный флаг
#   или --runs вне 1–20 → die (процесс завершается, функция не
#   возвращается); --compare без файла берёт свежайший json $OUT ДО записи
#   текущего артефакта. Локалы одной строкой: mode — 'quick' | 'full',
#   runs — целое 1–20, json_out/fresh — '0' | '1', out_dir/compare — пути
#   ('' — не задан; compare «auto» — режим автовыбора бейслайна).
#
# @param 1..N: string[]           # режим и флаги: 'quick' | 'full' (default quick),
#   --runs <целое 1–20> (default 3), --parallel <N[,M…]> (целые 1..8 через
#   запятую; дефолт quick — без параллельного блока, full — «2 4»; флаг
#   ЗАМЕНЯЕТ список в любом режиме), --out <каталог>, --json,
#   --compare [<файл>] (default свежайший json в --out), --fresh, --help
# @returns integer                # всегда 0 при возврате — отказы завершают процесс через die
cmd_bench() {
  local mode="quick" runs=3 out_dir="" json_out=0 compare="" fresh=0 par_list="" pn
  while [ $# -gt 0 ]; do
    case "$1" in
      full|quick) mode="$1"; shift ;;
      --runs)
        case "${2:-}" in ''|*[!0-9]*) die "--runs: целое 1–20 (получено '${2:-}')" ;; esac
        [ "$2" -ge 1 ] && [ "$2" -le 20 ] || die "--runs: целое 1–20 (получено '$2')"
        runs="$2"; shift 2 ;;
      --parallel)
        [[ "${2:-}" =~ ^[0-9]+(,[0-9]+)*$ ]] \
          || die "--parallel: целые 1..8 через запятую (получено '${2:-}')"
        for pn in ${2//,/ }; do
          if [ "$pn" -lt 1 ] || [ "$pn" -gt 8 ]; then
            die "--parallel: целые 1..8 через запятую (получено '$2')"
          fi
        done
        par_list=${2//,/ }; shift 2 ;;
      --out) [ -n "${2:-}" ] || die "--out: укажи каталог"; out_dir="$2"; shift 2 ;;
      --json) json_out=1; shift ;;
      --fresh) fresh=1; shift ;;
      --compare)
        if [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then compare="$2"; shift 2
        else compare="auto"; shift; fi ;;
      --help|-h) bench_help; return 0 ;;
      *) die "неизвестный флаг bench: $1 (см. hfctl bench --help)" ;;
    esac
  done

  # Параллельные батчи: явный --parallel перезадает список в любом режиме
  # (порядок пользователя сохраняется); дефолт — только у full («2 4»).
  if [ -z "$par_list" ] && [ "$mode" = full ]; then par_list="2 4"; fi

  [ -f "$STACK_DIR/.env" ] || die "стек не установлен — сначала 'hfctl install'"
  local v
  v=$(env_val HIPFIRE_PORT); [ -n "$v" ] && PORT="$v"

  # --json: человеческий вывод уходит в stderr, артефакт печатается в конце
  # в ИСХОДНЫЙ stdout (fd 4) — можно piping'нуть в jq.
  [ "$json_out" = 1 ] && exec 4>&1 1>&2

  BENCH_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hfctl-bench.XXXXXX")"
  trap 'rm -rf "$BENCH_TMP"' EXIT
  # Прерываемость (bench/interrupt): INT/TERM — явный трап (bench_parallel
  # прерывался только «наполовину»: фоновые curl игнорируют SIGINT по POSIX).
  trap 'bench_abort INT 130' INT
  trap 'bench_abort TERM 143' TERM
  : > "$BENCH_TMP/runs.tsv"
  OUT="${out_dir:-$STACK_DIR/bench-runs}"
  RUNS="$runs"

  local prof model md5_real body img ts_iso fname artifact base=""
  prof=$(cur_profile); model=$(cur_model)
  # Фикстура solo-code: канон — tpl/bench/merge_sort_thinking_off.txt
  # (байты-в-байты, md5-гейт ниже). НЕ редактировать: любая правка
  # меняет md5 и сравнимость замеров.
  cp "$TPL_DIR/bench/merge_sort_thinking_off.txt" "$BENCH_TMP/c_code.txt"
  md5_real=$(md5sum "$BENCH_TMP/c_code.txt" | cut -d' ' -f1)
  [ "$md5_real" = "$BENCH_FIXTURE_MD5" ] || \
    warn "md5 встроенной фикстуры $md5_real ≠ эталону $BENCH_FIXTURE_MD5 — сравнимость замеров под вопросом"
  printf '%s\n' "Напиши развёрнутое эссе о истории письменности" > "$BENCH_TMP/c_prose.txt"
  printf '%s\n' "Скажи ровно: ок" > "$BENCH_TMP/c_ttft.txt"
  printf '%s\n' "Напиши длинный рассказ о мореплавателе" > "$BENCH_TMP/c_long.txt"
  printf '%s\n' "Ответь одним предложением: прогрев бенча" > "$BENCH_TMP/c_warm.txt"

  if ! body=$(curl -fsS -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null); then
    die "сервер не отвечает (http://127.0.0.1:$PORT) — подними: hfctl up"
  fi
  if ! printf '%s' "$body" | python3 "$TPL_DIR/python/health_ok.py" 2>/dev/null; then
    log "модель ещё не готова — жду (как после 'hfctl up')"
    wait_health 900 || die "сервер так и не готов — смотри 'hfctl logs'"
  fi

  if [ "$fresh" = 1 ]; then
    log "--fresh: пересоздаю контейнер (recreate) — движок перечитает конфиг"
    compose up -d --force-recreate 2>&1 | tail -2
    wait_health 900 || die "сервер не поднялся после recreate — смотри 'hfctl logs'"
  fi

  local route rdesc
  route=$(bench_route "$prof")
  case "$route" in
    lanes)            rdesc="VMM fn-lanes" ;;
    multi-slot)       rdesc="multi-slot ($(bench_slots) слота)" ;;
    singleton-dflash) rdesc="singleton+DFlash" ;;
    *)                rdesc="singleton (serial)" ;;
  esac
  ROUTE="$route"

  log "bench ($mode): профиль $prof | модель $model | роут: $rdesc"
  echo "повторов на сценарий: $RUNS | артефакты: $OUT"

  log "прогрев (1 незамеряемый запрос)"
  bench_payload "$BENCH_TMP/warm.json" "$BENCH_TMP/c_warm.txt" 16
  bench_req "$BENCH_TMP/warm.json" "$BENCH_TMP/warm_resp" 120 >/dev/null || \
    warn "прогрев не удался — цифры первого сценария могут быть занижены"

  log "сценарии quick"
  bench_solo solo-code "$BENCH_TMP/c_code.txt" 400
  MED_SOLO_CODE=$(bench_med solo-code 4 || true)
  bench_solo solo-prose "$BENCH_TMP/c_prose.txt" 400
  bench_ttft
  if [ "$mode" = quick ] && [ -n "$par_list" ]; then
    log "параллельные батчи: $par_list"
    for pn in $par_list; do bench_parallel "$pn"; done
  fi

  if [ "$mode" = full ]; then
    log "сценарии full"
    bench_prefill
    bench_longgen
    for pn in $par_list; do bench_parallel "$pn"; done
    bench_hol
    echo "ar-baseline: пропущен (сравнение спекуляция/нет — через use разных профилей)"
    local med_hol note_hol=""
    med_hol=$(bench_med hol 2 || true)
    if [ -n "$med_hol" ] && [ -n "${BENCH_HOL_REF:-}" ]; then
      note_hol=$(awk -v m="$med_hol" -v r="$BENCH_HOL_REF" -f "$TPL_DIR/awk/hol_note.awk")
    elif [ -n "$med_hol" ]; then
      note_hol="сольный референс не удался — % изоляции не посчитать"
    fi
    [ -n "$note_hol" ] && export B_NOTE_hol="$note_hol" || true
  fi

  if [ -n "${MED_SOLO_CODE:-}" ]; then
    export B_NOTE_prefill_100k="decode 16 tok вычтен (соло-рейт $MED_SOLO_CODE tok/s)"
  else
    export B_NOTE_prefill_100k="decode 16 tok НЕ вычтен (соло-рейт неизвестен)"
  fi

  # ── артефакт, таблица, compare ──
  ts_iso=$(date +%Y-%m-%dT%H:%M:%S%z)
  fname="$(date +%Y-%m-%dT%H%M%S).json"
  base=$(ls -1t "$OUT"/*.json 2>/dev/null | head -1 || true)
  img=$(env_val HIPFIRE_IMAGE); [ -n "$img" ] || img="$IMAGE"
  export B_RUNS="$BENCH_TMP/runs.tsv" B_TS="$ts_iso" B_PROFILE="$prof" B_MODEL="$model"
  export B_ROUTE="$route" B_IMAGE="$img" B_MD5="$md5_real"
  if [ "$mode" = full ]; then B_FULL=1; else B_FULL=0; fi
  export B_FULL
  python3 "$TPL_DIR/python/bench_report.py" artifact > "$BENCH_TMP/artifact.json"
  mkdir -p "$OUT"   # каталог создаётся только под реальную запись (битый health = чисто в песочнице)
  cp "$BENCH_TMP/artifact.json" "$OUT/$fname"
  artifact=$(cat "$BENCH_TMP/artifact.json")

  python3 "$TPL_DIR/python/bench_report.py" report
  echo
  if [ -n "$compare" ]; then
    if [ "$compare" = "auto" ]; then
      if [ -n "$base" ]; then
        B_ARTIFACT="$artifact" python3 "$TPL_DIR/python/bench_report.py" compare "$base"
      else
        echo "первый прогон — бейслайн (в $OUT нет прошлых json)"
      fi
    else
      [ -f "$compare" ] || die "нет файла сравнения: $compare"
      B_ARTIFACT="$artifact" python3 "$TPL_DIR/python/bench_report.py" compare "$compare"
    fi
  fi
  echo
  echo "артефакт: $OUT/$fname"
  echo "повторное сравнение: hfctl bench --compare $OUT/$fname"
  [ "$json_out" = 1 ] && printf '%s\n' "$artifact" >&4
  return 0
}
