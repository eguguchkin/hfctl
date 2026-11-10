# shellcheck shell=bash
# ── bench (spec Э-2): локальный бенч производительности ─────────────────────
# Принципы: конфиг сервера НЕ трогаем (ar-baseline = пропуск, сравнение рук —
# через use); сервер трогаем только с --fresh; честные цифры — wall curl +
# usage, τ/TTFT — best-effort из логов движка (нет данных = пусто, не выдумываем).
# Python-помощники живут в tpl/python/ (контракты — spec/task-8.md Design §4),
# многострочные awk — в tpl/awk/, фикстура — в tpl/bench/.
BENCH_FIXTURE_MD5=253c7ac50857fe6d0e10fb0d2c5e35c0

bench_help() {
  cat <<EOF
hfctl bench — бенч производительности сервера (локально, без ssh)

  hfctl bench                  quick: 3 сценария (solo-code, solo-prose, ttft), ≤90 c
  hfctl bench full             все 8 сценариев: + prefill-100k, long-gen,
                               parallel N=2/N=4, HOL, ar-baseline
  hfctl bench --runs N         повторов на сценарий (default 3, допустимо 1–20)
  hfctl bench --out DIR        каталог артефактов (default $STACK_DIR/bench-runs)
  hfctl bench --json           машиночитаемый JSON в stdout (артефакт всё равно пишется)
  hfctl bench --compare [FILE] дельта с прошлым прогоном (без FILE — свежайший json)
  hfctl bench --fresh          перед прогоном recreate+wait_health — ЕДИНСТВЕННЫЙ
                               режим, трогающий сервер

Сервер должен работать (hfctl up). Конфиг сервера bench не меняет, поэтому
ar-baseline (без спекуляции) печатается как пропущенный: сравнение рук —
через 'hfctl use' разных профилей.
Артефакт: $STACK_DIR/bench-runs/<timestamp>.json — база для --compare.
EOF
}

bench_route() {  # фактический роут из логов/профиля (best-effort, как check_route)
  local prof="$1" clog
  clog=$(podman logs --tail 400 "$CONTAINER" 2>&1 || true)
  case "$prof" in
    flash-multi)
      if printf '%s' "$clog" | grep -q "fn-lanes staged"; then echo "lanes"; else echo "serial-fallback"; fi ;;
    27b-slots)
      echo "multi-slot" ;;
    *)
      if printf '%s' "$clog" | grep -q "spec: dflash"; then echo "singleton-dflash"; else echo "singleton-serial"; fi ;;
  esac
}

bench_slots() {  # фактическое число слотов (health → fallback на $SLOTS)
  local s
  s=$(curl -fsS -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null | python3 "$TPL_DIR/python/bench_slots.py" 2>/dev/null || true)
  echo "${s:-$SLOTS}"
}

bench_payload() {  # bench_payload <out.json> <content_file> <max_tokens> [stream 0|1]
  python3 "$TPL_DIR/python/bench_payload.py" \
    "$1" "$2" "$3" "${4:-0}" "$(cur_model)"
}

bench_req() {  # bench_req <payload.json> <resp_file> <timeout> → "wall prompt_tokens completion_tokens"
  # curl без ответа/ошибки → rc!=0; usage отсутствует → rc=4 (caller: WARN+пропуск)
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

bench_tau() {  # bench_tau <since_sec> → stdout: tau движка (пусто = нет в логах)
  local tau
  tau=$(podman logs --since "${1}s" "$CONTAINER" 2>&1 | grep -oE "(τ|tau)=[0-9.]+" | tail -1) || true
  printf '%s' "${tau#*=}"
}

bench_med() {  # bench_med <scenario> <field 1..6> — медиана чисел колонки runs.tsv (пусто = нет)
  [ -s "$BENCH_TMP/runs.tsv" ] || return 0
  awk -F'\t' -v s="$1" -v c="$2" '$1==s && $c!="" && $c!="-" {print $c}' "$BENCH_TMP/runs.tsv" \
    | sort -g \
    | awk -f "$TPL_DIR/awk/bench_med.awk"
}

bench_solo() {  # bench_solo <scenario> <content_file> <max_tokens> — decode tok/s по usage
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

bench_ttft() {  # TTFT по streaming-SSE (время до первого content-chunk)
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

bench_prefill() {  # ~100K токенов фикстуры; prefill tok/s = prompt_tokens/wall
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

bench_longgen() {  # 4096 tok decode + стабильность (первая/последняя tok/s= из логов, best-effort)
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

bench_parallel() {  # bench_parallel <N> — N одновременных curl; aggregate + интерпретация по роуту
  local n="$1" i t0 t1 tw sum tk fails=0 pw=""
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
    case "$tk" in ''|*[!0-9]*) fails=$((fails+1)) ;; *) sum=$((sum+tk)) ;; esac
  done
  [ "$fails" = 0 ] || warn "parallel-$n: $fails из $n запросов не удались (curl/usage)"
  if [ "$sum" -eq 0 ]; then
    warn "parallel-$n: ни одного ответа с usage — сценарий пропущен"
    return 0
  fi
  printf 'parallel-%s\t%s\t%s\t%s\t-\t-\n' "$n" "$tw" "$sum" \
    "$(awk -v s="$sum" -v s2="$tw" 'BEGIN{printf "%.2f", s/s2}')" >> "$BENCH_TMP/runs.tsv"
  for i in $(seq 1 "$n"); do
    [ -s "$BENCH_TMP/par_wall_$i" ] && pw="$pw$(cat "$BENCH_TMP/par_wall_$i")с " || true
  done
  export B_NOTE_parallel_$n="per-request wall: ${pw:-нет данных}"
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

bench_hol() {  # длинный в фоне, через 2 c короткий; мера wall короткого vs сольный референс
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

cmd_bench() {
  local mode="quick" runs=3 out_dir="" json_out=0 compare="" fresh=0
  while [ $# -gt 0 ]; do
    case "$1" in
      full|quick) mode="$1"; shift ;;
      --runs)
        case "${2:-}" in ''|*[!0-9]*) die "--runs: целое 1–20 (получено '${2:-}')" ;; esac
        [ "$2" -ge 1 ] && [ "$2" -le 20 ] || die "--runs: целое 1–20 (получено '$2')"
        runs="$2"; shift 2 ;;
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

  [ -f "$STACK_DIR/.env" ] || die "стек не установлен — сначала 'hfctl install'"
  local v
  v=$(env_val HIPFIRE_PORT); [ -n "$v" ] && PORT="$v"
  v=$(env_val HIPFIRE_BIND); [ -n "$v" ] && BIND="$v"

  # --json: человеческий вывод уходит в stderr, артефакт печатается в конце
  # в ИСХОДНЫЙ stdout (fd 4) — можно piping'нуть в jq.
  [ "$json_out" = 1 ] && exec 4>&1 1>&2

  BENCH_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hfctl-bench.XXXXXX")"
  trap 'rm -rf "$BENCH_TMP"' EXIT
  : > "$BENCH_TMP/runs.tsv"
  OUT="${out_dir:-$STACK_DIR/bench-runs}"
  mkdir -p "$OUT"
  RUNS="$runs"

  local prof model md5_real body img ts_iso fname artifact base=""
  prof=$(cur_profile); model=$(cur_model)
  # Фикстура solo-code: shipped-копия benchmarks/prompts/merge_sort_thinking_off.txt
  # (в tpl/bench; байты-в-байты, md5-гейт ниже). НЕ редактировать: любая правка
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

  if [ "$mode" = full ]; then
    log "сценарии full"
    bench_prefill
    bench_longgen
    bench_parallel 2
    bench_parallel 4
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
