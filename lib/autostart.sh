# shellcheck shell=bash
# ── автозапуск: юниты (render из tpl), on/off/up/down, boot-юнит, вотчдог ───
cmd_up()   { rm -f "$STOP_MARKER"; hf_up_locked; wait_health 600; }
cmd_down() { touch "$STOP_MARKER"; compose stop 2>&1 | tail -2; echo "остановлен (контейнеры/файлы/образ целы; вотчдог молчит до 'hfctl up')"; }

cmd_on()  { cmd_autostart; cmd_up; }
cmd_off() {
  # Юнит oneshot контейнеры не держит (compose up -d отсоединён) — останавливаем
  # стек напрямую, иначе ExecStop не выполнится для уже завершённого юнита.
  mkdir -p "$STACK_DIR"
  compose stop >/dev/null 2>&1 || true
  touch "$STOP_MARKER"
  systemctl --user disable "$UNIT_NAME.service" "$UNIT_NAME-watchdog.timer" 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/$UNIT_NAME.service" \
        "$HOME/.config/systemd/user/$UNIT_NAME-watchdog.service" \
        "$HOME/.config/systemd/user/$UNIT_NAME-watchdog.timer"
  systemctl --user daemon-reload
  # linger глушим: в выключенном состоянии сервер не должен вскакивать при boot.
  sudo loginctl disable-linger "$USER"
  echo "ВЫКЛ: сервер остановлен, с автозапуска снят (юниты удалены, linger off)."
  echo "Файлы, модели и образ целы. Вернуть: hfctl on"
}

cmd_autostart() {
  local unit_dir="$HOME/.config/systemd/user" bin
  bin="$(command -v podman)"
  mkdir -p "$unit_dir"
  # юниты ссылаются на $STACK_DIR/hfctl — убедимся, что копия на месте
  sync_tree
  render_tpl "$TPL_DIR/systemd/hipfire-compose.service.tpl" "$unit_dir/$UNIT_NAME.service" \
    PODMAN_BIN="$bin" STACK_DIR="$STACK_DIR" CF="${CF[*]}"
  # вотчдог крашей: rootless podman не оставляет живого наблюдателя после
  # `compose up -d` (проверено kill-тестом), поэтому раз в минуту проверяем,
  # что контейнер жив, если только стек не остановлен ЯВНО (hfctl down / off
  # пишут marker).
  render_tpl "$TPL_DIR/systemd/hipfire-compose-watchdog.service.tpl" "$unit_dir/$UNIT_NAME-watchdog.service" \
    STACK_DIR="$STACK_DIR"
  # таймер — статичный (плейсхолдеров нет)
  install -m 0644 "$TPL_DIR/systemd/hipfire-compose-watchdog.timer.tpl" "$unit_dir/$UNIT_NAME-watchdog.timer"
  systemctl --user daemon-reload
  systemctl --user enable "$UNIT_NAME.service" "$UNIT_NAME-watchdog.timer"
  systemctl --user start "$UNIT_NAME-watchdog.timer"
  rm -f "$STOP_MARKER"
  sudo loginctl enable-linger "$USER"
  echo "автозапуск ВКЛ (unit + watchdog-таймер 1м, linger=yes)"
}

# общий lock: параллельные `compose up -d` (вотчдог + boot + ручной up) дерутся
# за netns — пускаем только один одновременно
hf_up_locked() {
  ( flock -n 9 || { echo "up уже выполняется — пропуск"; return 0; }
    compose up -d 2>&1 | tail -2
  ) 9>"$STACK_DIR/.hfctl.lock"
}

# внутренняя команда загрузочного юнита: GPU-ноды (/dev/dri/card0) при boot
# появляются позже юзера — стучимся до появления/успеха (до ~4 мин)
cmd_boot() {
  local i
  for i in $(seq 1 24); do
    # ядро ROCm — renderD*; у Halo может не быть card0 вообще (нумерация с 1)
    if ! compgen -G "/dev/dri/renderD*" >/dev/null || [ ! -e /dev/kfd ]; then sleep 10; continue; fi
    if hf_up_locked; then :; fi
    if [ "$(podman inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" = running ]; then
      return 0
    fi
    # не поднялся: возможно,devices востребовались иначе (перенумерация
    # /dev/dri между загрузками) — пересоздаём контейнер раз в 3 попытки
    [ $((i % 3)) -eq 0 ] && ( flock -n 9 || true; compose up -d --force-recreate 2>&1 | tail -1 ) 9>"$STACK_DIR/.hfctl.lock" || true
    sleep 10
  done
  echo "boot: контейнер так и не запущен за 4 мин" >&2
  return 1
}

# внутренняя команда вотчдога (не для ручного запуска)
cmd_watchdog() {
  [ -f "$STOP_MARKER" ] && return 0
  local st
  st=$(podman inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)
  if [ "$st" != running ]; then
    echo "$(date -Is) watchdog: container state=$st -> up" >> "$STACK_DIR/.hfctl-watchdog.log" 2>/dev/null || true
    hf_up_locked || true
  fi
}
