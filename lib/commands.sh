# shellcheck shell=bash
# ── подкоманды: install/use/status/logs/watch/doctor/models/pull/uninstall ──

# Назначение: `hfctl install` — полная установка/обновление стека на голом
#   Ubuntu/Debian: миграции → RAM-гейт → префлайт хоста → файлы стека →
#   образ и модели → конфиг профиля → recreate → health → смоук → роут →
#   автозапуск. Идемпотентен (повтор = донастройка поверх существующего).
#
# Побочные эффекты (по фазам):
#   Миграции/чтение: v1-.env без HFCTL_PROFILE — старая модель/порт/bind/
#     база моделей сохраняются в глобалы (MODEL_DEFAULT/PORT/BIND/
#     MODELS_BASE); migrate_models — mv плоских файлов $MODELS_BASE в сеты;
#     migrate_state — cp -a legacy-вольюмов в пустой profiles/<prof>/.
#   Хост (preflight, sudo точечно): apt podman/podman-compose/curl,
#     usermod -aG render, limits.d memlock-файл, enable-linger; exit 42 при
#     свежей группе/лимитах (нужен перезаход/ребут).
#   Файлы: write_stack_files — дерево hfctl (бинарь+lib/+tpl/) в $STACK_DIR,
#     симлинк ~/.local/bin/hfctl, compose-тройка + compose.local.yml;
#     write_env — ПЕРЕЗАПИСЬ .env канона профиля.
#   Обвес движка: podman pull образа (если нет локально); pull_profile_models
#     — сет моделей + draft в активный $MODELS_DIR; compose up -d;
#     apply_profile — cfgset в config.toml профиля; `up -d
#     --force-recreate` (движок перечитывает конфиг только на recreate);
#     wait_health 900 + smoke (2 реальных запроса генерации) + check_route.
#   Финал: cmd_autostart (юниты systemd-user + watchdog-таймер + linger)
#     если не --no-autostart; в stdout — логи фаз, тело /health,
#     смоук-ответы, роут и usage-справка.
#
# Ограничения/допущения: порядок фаз фиксирован (RAM-гейт ДО любого
#   скачивания — spec §6). Неизвестный флаг или профиль → die (exit 1).
#   Env-входы: HFCTL_MODEL — модель по умолчанию поверх профиля;
#   HFCTL_FORCE=1 или --force — FORCE_GATE=1 (обход RAM-гейта с warn);
#   HFCTL_YES=1 или --yes — неинтерактив. Локалы одной строкой:
#   prof — алиас профиля из --profile ('' → PROFILE_DEFAULT);
#   no_autostart/set_port/set_bind/set_models/force — '0' | '1'.
#   exit 42 из preflight прерывает процесс до записи .env.
#
# @param 1..N: string[] # флаги (все опциональны): --profile <алиас> |
#   --port <целое> (default 11435) | --bind <адрес> (default 0.0.0.0) |
#   --models-dir <путь> | --no-autostart | --force | --yes
# @returns integer      # всегда 0 при возврате — отказы завершают процесс:
#   die/profile_gate (1), preflight (42), сбои шагов (set -e)
cmd_install() {
  local prof="" no_autostart=0 set_port=0 set_bind=0 set_models=0 force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile)     prof="$2"; shift 2 ;;
      --port)        PORT="$2"; set_port=1; shift 2 ;;
      --bind)        BIND="$2"; set_bind=1; shift 2 ;;
      --models-dir)  MODELS_DIR="$2"; set_models=1; shift 2 ;;
      --no-autostart) no_autostart=1; shift ;;
      --force)       force=1; shift ;;
      --yes)         ASSUME_YES=1; shift ;;
      *) die "неизвестный флаг install: $1 (доступны: --profile ${PROFILE_LIST// /|} --port --bind --models-dir --no-autostart --yes)" ;;
    esac
  done
  # миграция v1-.env (нет HFCTL_PROFILE): сохраняем текущую модель/порт/bind/путь
  if [ -f "$STACK_DIR/.env" ] && [ -z "$(env_val HFCTL_PROFILE)" ]; then
    local old; old=$(env_val HIPFIRE_MODEL)
    if [ -n "$old" ]; then
      MODEL_DEFAULT="$old"
      warn "миграция: найден старый .env — профиль $PROFILE_DEFAULT, модель по умолчанию остаётся $old"
    fi
    local v
    v=$(env_val HIPFIRE_PORT);        [ -n "$v" ] && [ "$set_port" = 0 ]  && PORT="$v"
    v=$(env_val HIPFIRE_BIND);        [ -n "$v" ] && [ "$set_bind" = 0 ]  && BIND="$v"
    v=$(env_val HIPFIRE_MODELS_PATH); [ -n "$v" ] && [ "$set_models" = 0 ] && MODELS_BASE="$v" && set_models_dir "$prof"
  fi
  prof=$(resolve_profile "${prof:-$PROFILE_DEFAULT}") || die "неизвестный профиль '$prof' (доступны: $PROFILE_LIST)"
  FORCE_GATE="${FORCE_GATE:-}"; [ "${force:-0}" = 1 ] && FORCE_GATE=1
  profile_gate "$prof"          # RAM-гейт: отказ ДО любого скачивания (spec §6)
  # миграция плоского models/ в сеты (один раз; сохраняет скачанное)
  migrate_models
  set_models_dir "$prof"
  preflight
  migrate_state "$prof"        # legacy named volumes → profiles/<prof> (один раз)
  write_stack_files
  # приоритет: HFCTL_MODEL > сохранённая при миграции модель > дефолт профиля
  MODEL_DEFAULT="${HFCTL_MODEL:-${MODEL_DEFAULT:-$(profile_field "$prof" 1)}}"
  write_env "$prof" "$MODEL_DEFAULT"
  log "образ $IMAGE (если ещё не локально)"
  podman image exists "$IMAGE" || podman pull "$IMAGE"
  pull_profile_models "$prof"
  compose up -d 2>&1 | tail -3
  apply_profile "$prof"
  compose up -d --force-recreate 2>&1 | tail -3
  wait_health 900
  smoke
  check_route "$prof"
  if [ "$no_autostart" = 1 ]; then
    echo "(автозапуск не включён — '--no-autostart'; включить: hfctl on)"
  else
    cmd_autostart
  fi
  log "готов. Сервер: http://$BIND:$PORT | профиль: $prof | модель по умолчанию: $(cur_model)"
  cat <<EOF

── как пользоваться ──────────────────────────────────────────────
Клиент (OpenAI-совместимый):  base_url = http://$BIND:$PORT/v1
Список моделей:  curl http://127.0.0.1:$PORT/v1/models
Проверка:
  curl http://127.0.0.1:$PORT/v1/chat/completions -H 'Content-Type: application/json' \\
    -d '{"model":"$(cur_model)","messages":[{"role":"user","content":"привет"}],"max_tokens":400,"reasoning_effort":"none"}'

Сменить профиль:  hfctl use <profile>     (${PROFILE_LIST// /|})
Остановить/вернуть: hfctl off / hfctl on   Снести: hfctl uninstall
Диагностика: hfctl doctor | hfctl status | hfctl logs -f
EOF
}

# Назначение: `hfctl use <profile>` — переключить профиль ЖИВОГО стека:
#   RAM-гейт → докачка сета → .env канона → конфиг движка → recreate →
#   health → смоук → роут; при неподошедшем профиле — откат канона.
#
# Побочные эффекты (по фазам): profile_gate (отказ — exit 1 ДО скачивания);
#   migrate_models + set_models_dir — раскладка по сетам и перестановка
#   глобала MODELS_DIR на сет профиля (нестандартная база из старого .env
#   уважается, сет — новый); preflight (sudo точечно, exit 42);
#   migrate_state (cp -a legacy-вольюмов в profiles/<p>); pull_profile_models
#   — докачка недостающих моделей/драфта; write_env — ПЕРЕЗАПИСЬ .env
#   (HFCTL_PROFILE=новый, порт/bind из прежнего .env); compose up -d +
#   apply_profile (cfgset) + `up -d --force-recreate`. Откатная ветка
#   (wait_health 600 не прошёл): warn + set_models_dir на сет прежнего
#   профиля + write_env(prev_prof, prev_model) — конфиг движка НОВЫМ
#   профилем уже записан и не откатывается; rc 1. Успех: smoke +
#   check_route; юниты автозапуска НЕ переписываются — канон профиля
#   читается из .env при boot/watchdog («переживёт рестарт»).
#
# Ограничения/допущения: стек должен быть установлен (.env есть — иначе
#   die); файл стека write_stack_files НЕ пересоздаёт (в отличие от
#   install). Env-входы: HFCTL_MODEL — модель по умолчанию; HFCTL_FORCE=1
#   или --force — обход RAM-гейта. Локалы: p — алиас/канон профиля
#   (resolve_profile); force — '0' | '1'; prev_prof/prev_model — снимок до
#   смены (для отката, verbatim cur_profile/cur_model); v/mb — строки из
#   .env ('' — ключа нет).
#
# @param 1..N: string[] # <алиас|id профиля> в любом порядке с опциональным
#   --force (обход RAM-гейта); прочий флаг → die
# @returns integer      # 0 — профиль активен; 1 — откат (сервер не поднялся, канон .env возвращён)
cmd_use() {
  local p="${1:-}" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      -*) die "неизвестный флаг use: $1 (доступен --force — обойти RAM-гейт)" ;;
      *) p="$1"; shift ;;
    esac
  done
  [ -n "$p" ] || die "использование: hfctl use <profile> (${PROFILE_LIST// /|})"
  [ -f "$STACK_DIR/.env" ] || die "стек не установлен — сначала 'hfctl install'"
  p=$(resolve_profile "$p") || die "неизвестный профиль '$p' (доступны: $PROFILE_LIST)"
  local prev_prof prev_model
  prev_prof=$(cur_profile); prev_model=$(cur_model)
  [ "${force:-0}" = 1 ] && FORCE_GATE=1
  profile_gate "$p"             # RAM-гейт: отказ ДО любого скачивания (spec §6)
  migrate_models                # плоский models/ (старые версии) → сеты
  set_models_dir "$p"
  # порт/bind — из текущего .env (use не трогает параметры, только профиль);
  # путь моделей: уважаем старую базу (если была нестандартная), сет — новый
  local v mb
  v=$(env_val HIPFIRE_PORT); [ -n "$v" ] && PORT="$v"
  v=$(env_val HIPFIRE_BIND); [ -n "$v" ] && BIND="$v"
  mb=$(env_val HIPFIRE_MODELS_PATH)
  if [ -n "$mb" ] && [ "$mb" != "$MODELS_DIR" ]; then
    # старый путь: если он плоский (не содержит /models/<сет>) — это база
    case "$mb" in
      */models/27b|*/models/flash) MODELS_BASE="$(dirname "$mb")" ;;
      *)                           MODELS_BASE="$mb" ;;
    esac
    set_models_dir "$p"
  fi
  preflight
  migrate_state "$p"           # legacy named volumes → profiles/<p> (один раз)
  pull_profile_models "$p"
  MODEL_DEFAULT="${HFCTL_MODEL:-$(profile_field "$p" 1)}"
  write_env "$p" "$MODEL_DEFAULT"
  compose up -d 2>&1 | tail -2      # контейнеры могут быть остановлены (off)
  apply_profile "$p"
  compose up -d --force-recreate 2>&1 | tail -2
  if ! wait_health 600; then
    # движок отказал в загрузке (admission/refusal): откатываем канон на прежний
    warn "профиль $p НЕ поднялся — откат канона на $prev_prof ($prev_model)"
    set_models_dir "$prev_prof"          # сет прежнего профиля (маунт тоже!)
    write_env "$prev_prof" "$prev_model"
    return 1
  fi
  smoke
  check_route "$p"
  log "профиль $p активен (конфиг автозапуска обновлён — переживёт рестарт)"
}

# Назначение: `hfctl status [--json]` — сводка состояния: профиль,
#   автозапуск/вотчдог, health сервера, список контейнеров; --json — тот же
#   снимок машиночитаемо.
#
# Побочные эффекты: только чтение и отчёт в stdout — systemctl --user
#   is-enabled юнита и вотчдог-таймера (отсутствие считается «disabled»),
#   curl GET /health (5 с таймаут, отказ → пустое тело), python3-рендер
#   (status_json.py в JSON-режиме, status_hline.py в текстовом), podman ps
#   -a по фильтру hipfire. Файлов и стека не меняет.
#
# Ограничения/допущения: требует глобалы PORT, UNIT_NAME, TPL_DIR
#   (диспетчер) и cur_profile (stack.sh). Флаг сверяется только по $1 —
#   лишние аргументы молча игнорируются. Локалы: json — '0' | '1';
#   prof/auto/wdog — строки (auto/wdog: 'enabled' | 'disabled'); body —
#   тело /health ('' — сервер не отвечает); hline — health-строка с
#   заглушкой «health: сервер не отвечает».
#
# @param 1: '--json'    # опциональный флаг JSON-вывода (default — текстовый отчёт)
# @stdout string        # текстовая сводка или JSON (status_json.py) — по флагу
# @returns integer      # текстовый режим — всегда 0 (финальный echo); JSON — rc python3
cmd_status() {
  local json=0; [ "${1:-}" = "--json" ] && json=1
  local prof auto wdog body
  prof=$(cur_profile)
  auto=$(systemctl --user is-enabled "$UNIT_NAME.service" 2>/dev/null || echo disabled)
  wdog=$(systemctl --user is-enabled "$UNIT_NAME-watchdog.timer" 2>/dev/null || echo disabled)
  body=$(curl -fsS -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null || echo "")
  if [ "$json" = 1 ]; then
    PROFILE="$prof" AUTO="$auto" WDOG="$wdog" python3 "$TPL_DIR/python/status_json.py" <<<"$body"
    return
  fi
  local hline
  hline=$(printf '%s' "$body" | python3 "$TPL_DIR/python/status_hline.py" 2>/dev/null || echo "health: сервер не отвечает")
  echo "профиль: $prof | автозапуск: $([ "$auto" = enabled ] && echo вкл || echo выкл) (watchdog: $([ "$wdog" = enabled ] && echo вкл || echo выкл))"
  echo "$hline"
  echo "── контейнеры ──"
  podman ps -a --filter "name=hipfire" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  echo "(живой наблюдатель запросов: hfctl watch)"
}

# Назначение: `hfctl logs [-f] [-n N]` — логи контейнера сервера с метками
#   времени (podman logs -t, stderr слит в stdout).
#
# Побочные эффекты: подпроцесс podman logs (последние n строк
#   hipfire_hipfire_1 в stdout); с -f — не возвращается (follow до сигнала).
#   Файлов и стека не касается.
#
# Ограничения/допущения: требует глобал CONTAINER (диспетчер). Разбор
#   флагов positional-независимый: -f — follow; '-n' отдельно, '-nN' или
#   голое число — размер хвоста. Локалы: n — целое число строк (default 80,
#   из аргумента вида [0-9]*); follow — '' или '-f' (unquoted-раскрытие в
#   команду podman). Неизвестный аргумент → die (exit 1).
#
# @param 1..N: string[] # флаги: -f (follow) | -n N | -nN | N (хвост в строках, default 80)
# @stdout string        # последние n строк логов контейнера с timestamp'ами
# @returns integer      # rc podman logs (при -f — rc на выходе по сигналу)
cmd_logs() {
  local n=80 follow="" a
  for a in "$@"; do
    case "$a" in
      -f) follow="-f" ;;
      -n) ;;
      [0-9]*) n="$a" ;;
      -n[0-9]*) n="${a#-n}" ;;
      *) die "использование: hfctl logs [-f] [-n N]" ;;
    esac
  done
  podman logs $follow -t --tail "$n" "$CONTAINER" 2>&1
}

# Назначение: °C самой горячей AMD-карты (vendor 0x1002) — максимум по
#   temp1_input всех её hwmon-датчиков; чтение /sys — на хосте (в
#   контейнере этих файлов нет).
#
# Побочные эффекты: только печать числа в stdout; читает
#   /sys/class/drm/card*/device/{vendor,hwmon/hwmon*/temp1_input}; ничего
#   не меняет.
#
# Ограничения/допущения: без параметров. Локалы одной строкой: card/hw —
#   пути /sys; v — строка vendor ('' при нечитаемом файле); t/max —
#   миллиградусы целыми ('' — датчик ещё не найден; нечисловые чтения
#   пропускаются). Без доступных AMD-датчиков — пустой stdout и rc 1
#   (вызывающий cmd_watch глушит это `|| true`).
#
# @stdout integer   # целые °C (максимум/1000 вниз); пусто — карта/датчик не видны
# @returns integer  # 0 — число напечатано; 1 — ни одного датчика не найдено
gpu_temp() {
  local card hw v t max=""
  for card in /sys/class/drm/card[0-9]*; do
    [ -r "$card/device/vendor" ] || continue
    case "$(cat "$card/device/vendor" 2>/dev/null || true)" in 0x1002) ;; *) continue ;; esac
    for hw in "$card"/device/hwmon/hwmon*/; do
      [ -r "${hw}temp1_input" ] || continue
      t=$(cat "${hw}temp1_input" 2>/dev/null || true)
      case "$t" in ''|*[!0-9]*) continue ;; esac
      if [ -z "$max" ] || [ "$t" -gt "$max" ]; then max="$t"; fi
    done
  done
  [ -n "$max" ] && echo "$((max / 1000))"
}

# Назначение: `hfctl watch [--interval N]` — живой наблюдатель обработки:
#   /stats + /metrics + температура GPU («агент работает, а в логах
#   тишина» — очередь и виден факт обработки).
#
# Побочные эффекты: бесконечный цикл тиков — на каждый: curl GET /stats и
#   /metrics (по 3 с таймаут), python3 (watch_stats.py) и awk для разбора,
#   gpu_temp (чтение /sys), sleep interval; строки событий и heartbeat в
#   stdout. Файлов и состояния стека не меняет.
#
# Ограничения/допущения: требует глобалы PORT, TPL_DIR (диспетчер), isint
#   и gpu_temp этого файла. Интервал — целое ≥ 1 с (иначе die, exit 1);
#   обе формы: --interval N и --interval=N. Локалы: interval — целые
#   секунды (default 2); now/last_print/last_down — unix-время (last_down
#   -999 = сервер ещё не «падал»); q/served/recent/retries/cache/fails и
#   prev_* — числа строками либо '-'/'' когда данных нет; prev_* при
#   недоступности сервера сбрасываются в '' (после поднятия печатается
#   свежая строка без ложных дельт). read из python заглушён `|| true`:
#   при пустом выводе счётчики остаются '-'.
#
# @param 1..N: string[] # флаги: --interval N | --interval=N (default 2 с, целое ≥ 1)
# @stdout string        # строки событий (очередь/обслужено/кэш/done tok-s/ошибки/GPU) и heartbeat простоя
# @returns integer      # не возвращается — вечный цикл; ошибки аргументов: die (exit 1)
cmd_watch() {
  # Философия тихого стриминга: строка только на ИЗМЕНЕНИИ видимых счётчиков,
  # в простое — heartbeat раз в 60 c; недоступность — каждые 30 c, самолечение.
  local usage="использование: hfctl watch [--interval N]" interval=2
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval=*) interval="${1#*=}" ;;
      --interval)   [ $# -ge 2 ] || die "$usage"; interval="$2"; shift ;;
      *)            die "$usage" ;;
    esac
    shift
  done
  isint "$interval" || die "интервал должен быть целым числом секунд"
  [ "$interval" -ge 1 ] || die "интервал должен быть ≥ 1 с"

  local now ts temp line q served recent retries mval cache fails
  local prev_q="" prev_served="" prev_cache="" prev_fails=""
  local last_print=0 last_down=-999
  while :; do
    now=$(date +%s)
    temp=$(gpu_temp || true)
    q="-"; served="-"; recent="-"; retries="-"; cache=""; fails=""
    mval=$(curl -fsS -m 3 "http://127.0.0.1:$PORT/stats" 2>/dev/null || true)
    if [ -z "$mval" ]; then
      # недоступность: первое сообщение сразу, дальше раз в ~30 c; база
      # сравнения сбрасывается на КАЖДОМ тике простоя — после поднятия
      # всегда печатается свежая строка без ложных дельт
      if [ $((now - last_down)) -ge 30 ]; then
        ts=$(date +%H:%M:%S)
        echo "$ts сервер недоступен (нет /stats на :$PORT); жду…"
        last_down=$now; last_print=$now
      fi
      prev_q=""; prev_served=""; prev_cache=""; prev_fails=""
      sleep "$interval"; continue
    fi
    read -r q served recent retries <<<"$(printf '%s' "$mval" | python3 "$TPL_DIR/python/watch_stats.py" || true)"
    mval=$(curl -fsS -m 3 "http://127.0.0.1:$PORT/metrics" 2>/dev/null || true)
    cache=$(printf '%s\n' "$mval" | awk -v p="hipfire_cached_prompt_tokens_total" '$1==p{print $2; exit}')
    fails=$(printf '%s\n' "$mval" | awk -v p="hipfire_requests_failed_total" '$1==p{print $2; exit}')
    cache=${cache%.*}; fails=${fails%.*}

    if [ "$q" != "$prev_q" ] || [ "$served" != "$prev_served" ] \
       || [ "${cache:-}" != "$prev_cache" ] || [ "${fails:-}" != "$prev_fails" ]; then
      ts=$(date +%H:%M:%S)
      line="$ts  очередь: $q │ обслужено: $served"
      if isint "$served" && isint "$prev_served" && [ "$served" -gt "$prev_served" ]; then
        line+=" (+$((served - prev_served)))"
        # дельта кэша — только ненулевая: гонка тиков (кэш обновился раньше
        # счётчика обслуженных) не порождает «(+0 tokens)»
        if isint "$cache" && isint "$prev_cache" && [ "$((cache - prev_cache))" -gt 0 ]; then
          line+=" │ кэш: $cache (+$((cache - prev_cache)) tokens)"
        elif [ -n "$cache" ]; then
          line+=" │ кэш: $cache"
        fi
      elif [ -n "$cache" ]; then
        line+=" │ кэш: $cache"
      fi
      line+=" │ done: $recent tok/s"
      if isint "$fails" && [ "$fails" -gt 0 ]; then line+=" │ ошибки: $fails"; fi
      if [ -n "$temp" ]; then line+=" │ GPU: ${temp}°C"; else line+=" │ GPU: ?"; fi
      echo "$line"
      last_print=$now
      prev_q="$q"; prev_served="$served"; prev_cache="${cache:-}"; prev_fails="${fails:-}"
    elif [ $((now - last_print)) -ge 60 ]; then
      ts=$(date +%H:%M:%S)
      if [ "$q" = "0" ]; then
        echo "$ts обменов нет (очередь: 0, обслужено: $served, GPU: ${temp:-?}°C)"
      else
        # долгая генерация не меняет счётчик served почти минуту —
        # «тишина» тут значит «работает», и это надо произнести
        echo "$ts обработка идёт (очередь: $q, обслужено: $served, GPU: ${temp:-?}°C)"
      fi
      last_print=$now
    fi
    sleep "$interval"
  done
}

# Назначение: скрытый алиас совместимости `hfctl mode single|slots [N]` ==
#   `hfctl use 27b-*`; N — число слотов, пишется в глобал SLOTS (его читает
#   apply_profile в ветке 27b-slots).
#
# Побочные эффекты: перезапись глобала SLOTS значением $2 (если задан);
#   далее — всё, что делает cmd_use для переданного алиаса (RAM-гейт →
#   докачка сета → .env → конфиг → recreate → health → смоук → роут);
#   проброс --force из mode не предусмотрен (флаг-позиционный разбор cmd_use
#   сюда не доходит — передаётся только "$m").
#
# Ограничения/допущения: требует глобал SLOTS (диспетчер) и cmd_use этого
#   файла. Пустой $1 → die (exit 1). Локал m — алиас/id профиля КАК ЕСТЬ
#   (алиасы single|slots раскрывает resolve_profile внутри cmd_use);
#   нечисловое $2 проходит в SLOTS без валидации и всплывёт в cfgset.
#
# @param 1: string    # алиас профиля (живые: single | slots) или его канонический id
# @param 2: /\d+/     # опционально: число слотов → глобал SLOTS (default — HFCTL_SLOTS/2)
# @returns integer    # как у cmd_use: 0 — профиль активен; 1 — откат канона
cmd_mode() {
  local m="${1:-}"; [ -n "$m" ] || die "использование: hfctl mode single|slots [N]"
  [ -n "${2:-}" ] && SLOTS="$2"
  cmd_use "$m"
}

# Назначение: `hfctl doctor` — диагностика БЕЗ изменений (spec §3): ОС,
#   память, GPU-ноды, RAM-гейт по всем профилям, установка/state, окружение
#   (podman/render/limits.d), gpu-lock-и, health.
#
# Побочные эффекты: только чтение и печать (stdout, warn в stderr):
#   /etc/os-release, /proc/meminfo, наличие /dev/kfd и /dev/dri/renderD*,
#   таблица профилей (RAM-гейт по каждому), .env (cur_profile/cur_model),
#   state-каталоги профиля, podman volume exists (legacy-вольюмы),
#   podman --version, id -nG, limits.d-файл, fuser по
#   /run/lock/hipfire/gpu-pci-*.lock, curl GET /health (первые 200 байт).
#   Ничего не создаёт, не удаляет, sudo не зовёт.
#
# Ограничения/допущения: требует глобалы STACK_DIR, STATE_BASE, PORT,
#   PROFILE_LIST (диспетчер) и warn/ram_pool_gib/profile_field/cur_profile/
#   cur_model. Локалы: have/need — целые GiB; sd/lim/lockdir —
#   фиксированные пути; f — путь lock-файла из glob; p — перебор
#   PROFILE_LIST. Чужой держатель gpu-lock — предупреждение (второй serve
#   не стартует), не ошибка возврата; `. /etc/os-release` засоряет окружение
#   переменными ОС (штатно для diagnosis-only).
#
# @stdout string   # текстовая диагностика секциями («── система ──» … «── health ──»)
# @returns integer # всегда 0 — финальный echo; отказы чтений заглушены ветками «НЕТ»
cmd_doctor() {
  local have; have=$(ram_pool_gib)
  echo "── система ──"
  . /etc/os-release && echo "ОС: $PRETTY_NAME"
  echo "память: пул ${have} GiB (MemTotal); доступно сейчас: $(awk '/MemAvailable/{printf "%d", $2/1048576}' /proc/meminfo) GiB"
  echo "GPU: /dev/kfd $([ -e /dev/kfd ] && echo есть || echo НЕТ), /dev/dri/renderD* $(compgen -G '/dev/dri/renderD*' >/dev/null && echo есть || echo НЕТ)"
  echo "── профили (RAM-гейт) ──"
  local p
  for p in $PROFILE_LIST; do
    local need; need=$(profile_field "$p" 4)
    if [ "$have" -ge "$need" ]; then
      echo "  $p: доступен (нужно ≥${need} GiB)"
    else
      echo "  $p: НЕДОСТУПЕН (нужно ≥${need} GiB, есть ${have})"
    fi
  done
  echo "── установка ──"
  if [ -f "$STACK_DIR/.env" ]; then
    echo "стек: $STACK_DIR (профиль $(cur_profile), модель $(cur_model))"
    local sd="$STATE_BASE/$(cur_profile)"
    if [ -d "$sd/config" ] && [ -w "$sd/config" ] && [ -d "$sd/kernel" ] && [ -w "$sd/kernel" ]; then
      echo "state: $sd (per-профиль config+kernel; disk-тир кэша — внутри config/)"
    else
      warn "state: $sd отсутствует или не записуем — пересоздай стек (hfctl install)"
    fi
    if podman volume exists hipfire_hipfire-config 2>/dev/null; then
      warn "state: legacy-вольюмы (hipfire_hipfire-config/kernels) ещё живут (установка до этапа 7) — удаляются uninstall"
    fi
  else
    echo "стек: НЕ УСТАНОВЛЕН ($STACK_DIR/.env нет) — 'hfctl install'"
  fi
  echo "── окружение ──"
  command -v podman >/dev/null && echo "podman: $(podman --version)" || echo "podman: НЕТ (install поставит)"
  command -v podman-compose >/dev/null && echo "podman-compose: есть" || echo "podman-compose: НЕТ (install поставит)"
  id -nG | grep -qw render && echo "группа render: есть" || echo "группа render: НЕТ (install добавит, перелогин)"
  local lim="/etc/security/limits.d/99-hipfire-memlock.conf"
  [ -f "$lim" ] && echo "memlock limits: есть ($lim)" || echo "memlock limits: НЕТ (install напишет, ребут)"
  # gpu-lock: эксклюзивен — чужой держатель = отказ запуска
  local lockdir="/run/lock/hipfire" f
  if [ -d "$lockdir" ]; then
    for f in "$lockdir"/gpu-pci-*.lock; do
      [ -e "$f" ] || continue
      if fuser -v "$f" 2>&1 | grep -q hipfire; then
        warn "gpu-lock занят: $f ($(fuser -v "$f" 2>&1 | tail -1)) — второй serve не стартует"
      else
        echo "gpu-lock: свободен ($f)"
      fi
    done
  fi
  echo "── health ──"
  curl -fsS -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null | head -c 200 || echo "(сервер не отвечает)"
  echo
}

# Назначение: `hfctl models` — что скачано по сетам в $MODELS_BASE и что
#   требует каждый профиль (spec §3); плюс напоминание про изоляцию сетов.
#
# Побочные эффекты: только чтение и печать в stdout: du -sh каталогов
#   сетов ('27b' | 'flash') в $MODELS_BASE, /proc/meminfo (ram_pool_gib),
#   таблица профилей (поле 4 — порог гейта), model_set по каждому id.
#   Файлов не касается.
#
# Ограничения/допущения: требует глобалы MODELS_BASE, PROFILE_LIST
#   (диспетчер) и ram_pool_gib/profile_field/model_set. Локалы: s —
#   перебор имён сетов; total — человекочитаемый размер du ('' при
#   недоступном du); p — перебор PROFILE_LIST; have/need — целые GiB;
#   avail — 'доступен' | 'НЕДОСТУПЕН …'. Порог здесь тот же (поле 4), что у
#   profile_gate, но без учёта force-обхода.
#
# @stdout string   # размеры сетов + строка доступности на каждый профиль + итог про изоляцию
# @returns integer # всегда 0 — финальный echo; нет каталога — штатная заглушка-строка
cmd_models() {
  echo "── на диске (по сетам профилей, в $MODELS_BASE) ──"
  local s total
  for s in 27b flash; do
    if [ -d "$MODELS_BASE/$s" ]; then
      total=$(du -sh "$MODELS_BASE/$s" 2>/dev/null | cut -f1)
      echo "  $s: $total"
    fi
  done
  [ -d "$MODELS_BASE" ] || echo "(каталога нет — ничего не скачано)"
  echo "── профили: доступность ──"
  local p have; have=$(ram_pool_gib)
  for p in $PROFILE_LIST; do
    local need avail
    need=$(profile_field "$p" 4)
    if [ "$have" -ge "$need" ]; then avail="доступен"; else avail="НЕДОСТУПЕН (RAM: есть ${have} GiB, нужно ≥${need})"; fi
    echo "  $p → сет models/$(model_set "$p") [$avail]"
  done
  echo "изоляция: монтируется только сет активного профиля — запрос с моделью"
  echo "чужого сета получит 404 (молчаливый swap невозможен)"
}

# Назначение: `hfctl pull <profile>` — скачать сет моделей профиля БЕЗ
#   переключения (прогрев/бэкап-сет на слабой машине легален).
#
# Побочные эффекты: mkdir -p базы $MODELS_BASE и каталога целевого сета;
#   migrate_models (mv плоских файлов в сеты); pull_profile_models с
#   env-префиксом MODELS_DIR=целевой сет (глобал MODELS_DIR НЕ сдвигается)
#   — подтяжка образа и докачка недостающих моделей/драфта по сети; log и
#   две итоговые строки в stdout. .env, конфиг движка, контейнеры и
#   автозапуск НЕ трогаются.
#
# Ограничения/допущения: стек должен быть установлен (.env есть — иначе
#   die, exit 1); RAM-гейт НЕ применяется — скачивание ≠ запуск, ёмкость
#   оценивается при use. Локалы: p — алиас/id после resolve_profile (пустой
#   или неизвестный → die); target — путь каталога-сета назначения.
#
# @param 1: string      # алиас или канонический id профиля (нормализует resolve_profile)
# @returns integer      # всегда 0 при возврате — die (exit 1) и сетевые сбои pull завершают процесс (set -e)
cmd_pull() {
  local p="${1:-}"
  [ -n "$p" ] || die "использование: hfctl pull <profile> (${PROFILE_LIST// /|})"
  p=$(resolve_profile "$p") || die "неизвестный профиль '$p' (доступны: $PROFILE_LIST)"
  # скачивание ≠ запуск: RAM-гейт НЕ применяем (бэкап-сет на слабой машине легален)
  [ -f "$STACK_DIR/.env" ] || die "стек не установлен — сначала 'hfctl install'"
  [ -d "$MODELS_BASE" ] || mkdir -p "$MODELS_BASE"
  migrate_models
  local target="$MODELS_BASE/$(model_set "$p")"
  mkdir -p "$target"
  log "тяну сет '$(model_set "$p")' профиля $p в $target (без переключения профиля)"
  MODELS_DIR="$target" pull_profile_models "$p"
  echo "готово: $target"
  echo "(активация — 'hfctl use $p'; RAM-гейт оценивается при use)"
}

# Назначение: `hfctl uninstall` — снять стек: контейнеры и сеть проекта,
#   state-каталоги и файлы стека, юниты автозапуска и limits.d; модели и
#   образ удаляются только по явным флагам.
#
# Побочные эффекты (по порядку): подтверждение ask (не-TTY или без --yes —
#   авто-нет → «отменено», exit 0 без изменений); cmd_off || true (стоп
#   контейнеров, маркер остановки, юниты ~/.config/systemd/user/* удалены,
#   daemon-reload, linger off); compose down (контейнеры + сеть проекта);
#   podman volume rm legacy-вольюмов hipfire_hipfire-config/-kernels.
#   Границы rm -rf: $STACK_DIR ЦЕЛИКОМ (бинарь hfctl, lib/, tpl/,
#   compose-файлы, .env, модели и state по путям по умолчанию), поэтому при
#   сохранении моделей база УВОЗИТСЯ целиком (mv $MODELS_BASE →
#   $STACK_DIR.hfctl-models-$$, возврат после rm) — иначе сносились бы чужие
#   сеты; с --purge-models база не увозится и уходит вместе со стеком.
#   Далее: sudo rm /etc/security/limits.d/99-hipfire-memlock.conf (если
#   есть); с --purge-image — podman rmi образа (отказ заглушён). Итог
#   «uninstall DONE». Не трогаем: podman, группу render, чужие каталоги.
#
# Ограничения/допущения: по умолчанию STATE_BASE/MODELS_BASE лежат внутри
#   $STACK_DIR и удаляются вместе с ним; кастомные пути вне стека rm -rf
#   стека не достанет (вывоз базы при сохранении делает это явно). Локалы
#   purge_models/purge_image — '0' | '1'; keep — ГЛОБАЛ (local объявить
#   забыто): путь-временя вывезенной базы либо ''. Сбои остановки/снятия
#   вешает на `|| true` (uninstall доходит до конца); незащищённые sudo rm
#   и mv завершают процесс по set -e. Неинтерактив без --yes — штатный
#   отказ (ask авто-нет).
#
# @param 1..N: string[] # флаги (все опциональны): --purge-models | --purge-image | --yes
# @returns integer      # всегда 0 при возврате («uninstall DONE»); отказ по вопросу — exit 0
cmd_uninstall() {
  local purge_models=0 purge_image=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge-models) purge_models=1; shift ;;
      --purge-image)  purge_image=1; shift ;;
      --yes)          ASSUME_YES=1; shift ;;
      *) die "неизвестный флаг uninstall: $1 (доступны: --purge-models --purge-image --yes)" ;;
    esac
  done
  echo "uninstall снимет: контейнеры, сеть проекта, state-каталоги $STATE_BASE"
  echo "(конфиг/disk-тир кэша/kernels на профиль) + legacy-вольюмы,"
  echo "юниты+таймер автозапуска, limits.d, каталог стека $STACK_DIR (включая hfctl)."
  echo "Модели $MODELS_DIR: $([ "$purge_models" = 1 ] && echo 'УДАЛЯЮТСЯ (--purge-models)' || echo 'СОХРАНЯЮТСЯ (переезжают в стеке)')"
  echo "Образ $IMAGE: $([ "$purge_image" = 1 ] && echo 'УДАЛЯЕТСЯ (--purge-image)' || echo 'остаётся (--purge-image — удалить)')"
  echo "Не трогаем: podman, группа render, чужие каталоги."
  ask "Продолжить? [y/N] " || { echo "отменено"; exit 0; }
  cmd_off || true
  ( cd "$STACK_DIR" 2>/dev/null && compose down 2>&1 | tail -2 ) || true
  podman volume rm hipfire_hipfire-config hipfire_hipfire-kernels 2>/dev/null || true
  # модели живут в базе (models/<сет>/ на ВСЕ сеты!) — при сохранении
  # переезжает БАЗА целиком: иначе rm -rf $STACK_DIR сносит чужие сеты
  keep=""
  if [ "$purge_models" != 1 ] && [ -d "$MODELS_BASE" ]; then
    keep="$STACK_DIR.hfctl-models-$$"
    mkdir -p "$(dirname "$keep")"
    mv "$MODELS_BASE" "$keep"
  fi
  rm -rf "$STACK_DIR"
  if [ -n "$keep" ]; then mkdir -p "$(dirname "$MODELS_BASE")"; mv "$keep" "$MODELS_BASE"; fi
  if [ -f /etc/security/limits.d/99-hipfire-memlock.conf ]; then
    sudo rm -f /etc/security/limits.d/99-hipfire-memlock.conf
  fi
  if [ "$purge_models" = 1 ]; then echo "модели удалены"; fi
  if [ "$purge_image" = 1 ];  then podman rmi "$IMAGE" 2>/dev/null || true; echo "образ удалён"; fi
  echo "uninstall DONE"
}
