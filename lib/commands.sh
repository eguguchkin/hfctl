# shellcheck shell=bash
# ── подкоманды: install/use/status/logs/watch/doctor/models/pull/uninstall ──
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

gpu_temp() {  # °C самой горячей AMD-карты ('' если не видно); чтение /sys — на хосте
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

cmd_watch() {  # живой наблюдатель обработки: /stats + /metrics + температура GPU
  # («агент работает, а в логах тишина» — очередь и виден факт обработки).
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

# скрытый алиас совместимости: mode single|slots [N] == use 27b-*
cmd_mode() {
  local m="${1:-}"; [ -n "$m" ] || die "использование: hfctl mode single|slots [N]"
  [ -n "${2:-}" ] && SLOTS="$2"
  cmd_use "$m"
}

cmd_doctor() {  # диагностика без изменений (spec §3): gейты + что мешает
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

cmd_models() {  # что скачано и что требует каждый профиль (spec §3)
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

cmd_pull() {  # hfctl pull <profile> — скачать сет модели БЕЗ переключения
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
