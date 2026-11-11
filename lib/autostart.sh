# shellcheck shell=bash
# ── автозапуск: юниты (render из tpl), on/off/up/down, boot-юнит, вотчдог ───

# Назначение: `hfctl up` (скрытый алиас): поднять стек, сняв явный маркер
#   остановки, и дождаться готовности сервера.
#
# Побочные эффекты: rm -f маркера $STACK_DIR/.hfctl-stopped (отсутствие —
#   беззвучно); через hf_up_locked — создание/усечение lock-файла
#   $STACK_DIR/.hfctl.lock и `podman compose up -d` (контейнеры, подтяжка
#   образа, init-pull моделей); через wait_health (health.sh) — поллинг
#   GET /health (curl/python3), log-строки и stdout до 300 байт тела
#   /health; sleep по 5 с за итерацию ожидания.
#
# Ограничения/допущения: требует глобалы STACK_DIR, STOP_MARKER, CONTAINER
#   (диспетчер), CF (stack.sh) и функцию wait_health (health.sh). Таймаут
#   600 с жёсткий (install/use ждут 900 сами). Сбой `compose up -d` внутри
#   hf_up_locked (rc проходит через pipefail) завершает процесс по set -e
#   ещё до wait_health. Живые вызовы: диспетчер (`up`) и cmd_on этого
#   файла.
#
# @stdout string   # сообщение hf_up_locked + вывод wait_health (строка
#   ожидания, тело /health до 300 байт, «HEALTHY после Nс»)
# @returns integer # 0 — стек поднят и сервер здоров; 1 — таймаут wait_health
#   или pre-warm-отказ (по set -e процесс завершается этим rc)
cmd_up()   { rm -f "$STOP_MARKER"; hf_up_locked; wait_health 600; }

# Назначение: единая реализация остановки стека — явный маркер остановки +
#   `podman compose stop` (последние 2 строки вывода наружу).
#
# Побочные эффекты: mkdir -p $STACK_DIR; touch маркера
#   $STACK_DIR/.hfctl-stopped (ДО stop — вотчдог оглушён даже при сбое
#   остановки); `podman compose stop` — остановка контейнеров (тома, файлы
#   стека и образ НЕ удаляются; stderr слит в stdout, хвост — последние 2
#   строки).
#
# Ограничения/допущения: требует глобалы STACK_DIR, STOP_MARKER и CF
#   (stack.sh). Заглушивание/печать — на совести вызывающего: cmd_down
#   печатает вывод и терпит rc по set -e, cmd_off заглушает вывод и rc
#   (`|| true`).
#
# @stdout string   # последние 2 строки `podman compose stop`
# @returns integer # 0 — остановлен; ненулевой rc — сбой compose stop
#   (pipefail пропускает его наружу, tail не привносит)
stop_with_marker() { mkdir -p "$STACK_DIR"; touch "$STOP_MARKER"; compose stop 2>&1 | tail -2; }

# Назначение: `hfctl down` (скрытый алиас): ЯВНАЯ остановка стека — с
#   маркером, чтобы вотчдог не поднял его обратно до следующего `hfctl up`.
#
# Побочные эффекты: stop_with_marker (маркер ДО stop + `podman compose
#   stop`); echo итоговой строки. Читает compose-тройку из $STACK_DIR.
#
# Ограничения/допущения: требует глобал STACK_DIR (диспетчер) и
#   stop_with_marker этого файла. Сбой compose stop по set -e завершает
#   процесс без итоговой строки (маркер уже стоит — вотчдог оглушён).
#
# @stdout string   # последние 2 строки `podman compose stop` + строка
#   «остановлен (контейнеры/файлы/образ целы; вотчдог молчит до 'hfctl up')»
# @returns integer # 0 — остановлен, вотчдог молчит; ненулевой rc — сбой
#   compose stop (по set -e процесс завершается до сообщения)
cmd_down() { stop_with_marker; echo "остановлен (контейнеры/файлы/образ целы; вотчдог молчит до 'hfctl up')"; }

# Назначение: `hfctl on` (алиас `autostart`): включить автозапуск (юниты +
#   таймер + linger) и поднять стек прямо сейчас.
#
# Побочные эффекты: всё, что делают cmd_autostart (запись юнит-файлов в
#   ~/.config/systemd/user/, systemctl daemon-reload/enable/start, linger,
#   снятие маркера) и cmd_up (compose up -d, lock-файл, ожидание /health).
#
# Ограничения/допущения: порядок фиксирован — сначала cmd_autostart (юниты
#   должны быть установлены до поднятия), затем cmd_up. Сбой cmd_autostart
#   по set -e завершает процесс до поднятия стека. Требует все глобалы
#   cmd_autostart и cmd_up.
#
# @returns integer # как у cmd_up: 0 — стек поднят и здоров; 1 — сбой
#   wait_health (по set -e — выход процесса с этим rc)
cmd_on()  { cmd_autostart; cmd_up; }

# Назначение: `hfctl off` (алиас `noautostart`): остановить стек и полностью
#   снять автозапуск — юниты удалены, linger выключен; файлы/модели/образ
#   целы.
#
# Побочные эффекты: stop_with_marker (маркер ДО stop + compose stop; вывод
#   и rc заглушены — «вотчдог оглушён даже при сбое остановки», семантика
#   cmd_down); systemctl --user disable hipfire-compose.service и
#   hipfire-compose-watchdog.timer (stderr заглушён, rc — `|| true`); rm -f
#   трёх юнит-файлов ~/.config/systemd/user/{hipfire-compose.service,
#   hipfire-compose-watchdog.service, hipfire-compose-watchdog.timer};
#   systemctl --user daemon-reload; sudo loginctl disable-linger $USER
#   (юнит-менеджер юзера больше не стартует при boot и гаснет после выхода
#   всех сессий); две строки в stdout.
#
# Ограничения/допущения: остановка стека идёт ДО удаления юнитов — oneshot-
#   юнит контейнеры не держит (compose up -d отсоединён), ExecStop уже
#   завершённого юнита не сработает. Требует глобалы UNIT_NAME, STOP_MARKER,
#   STACK_DIR (диспетчер) и CF (stack.sh), stop_with_marker этого файла. Не
#   заглушённые systemctl daemon-reload и sudo disable-linger при `hfctl off`
#   по set -e завершают процесс своим rc (юниты к этому моменту уже удалены);
#   вызов из cmd_uninstall (commands.sh) через `|| true` вешает set -e внутри
#   функции — там отказы терпят и продолжают.
#
# @stdout string   # две итоговые строки («ВЫКЛ: …» и «Файлы, модели и
#   образ целы. Вернуть: hfctl on»)
# @returns integer # 0 — дошёл до конца; сбои daemon-reload/disable-linger
#   наружу не возвращаются (завершают процесс по set -e либо заглушены
#   контекстом uninstall)
cmd_off() {
  # Юнит oneshot контейнеры не держит (compose up -d отсоединён) — останавливаем
  # стек напрямую, иначе ExecStop не выполнится для уже завершённого юнита.
  stop_with_marker >/dev/null 2>&1 || true
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

# Назначение: установить/обновить конфигурацию автозапуска в systemd-user:
#   compose-сервис (ExecStart = bash $STACK_DIR/hfctl _boot), вотчдог-сервис
#   (ExecStart = $STACK_DIR/hfctl _watchdog) и его минутный таймер; enable
#   их и включить linger.
#
# Побочные эффекты: mkdir -p ~/.config/systemd/user; sync_tree
#   (stack_files.sh — самокопия дерева в стек при первом включении);
#   render_tpl записывает ~/.config/systemd/user/$UNIT_NAME.service (из
#   tpl/systemd/hipfire-compose.service.tpl с PODMAN_BIN=$(command -v
#   podman), STACK_DIR и строкой CF-тройки) и …-watchdog.service (tpl,
#   STACK_DIR); install -m 0644 копирует статичный
#   tpl/systemd/hipfire-compose-watchdog.timer.tpl → …-watchdog.timer;
#   systemctl --user daemon-reload, enable ($UNIT_NAME.service +
#   $UNIT_NAME-watchdog.timer), start таймера; rm -f маркера
#   $STACK_DIR/.hfctl-stopped; sudo loginctl enable-linger $USER; строка
#   итога в stdout.
#
# Ограничения/допущения: юниты рендерятся из tpl/systemd/ через render_tpl
#   (die при нераскрытых плейсхолдерах) и исполняют $STACK_DIR/hfctl —
#   поэтому sync_tree строго до рендера; к моменту enable compose-тройка и
#   .env уже должны лежать в $STACK_DIR (install/use пишут их раньше).
#   enable ≠ немедленный пуск compose-сервиса: он стартует при boot (или
#   cmd_up поднимает стек сейчас), таймер же активен сразу (первый тик
#   OnBootSec=2min). Локалы одной строкой: unit_dir — фиксированный путь
#   ~/.config/systemd/user; bin — абсолютный путь podman (command -v).
#   Требует глобалы UNIT_NAME, STACK_DIR, TPL_DIR, HOME (диспетчер), CF
#   (stack.sh), рендер-хелперы sync_tree/render_tpl и die. По set -e сбой
#   любого незащищённого шага (mkdir/render_tpl-die/systemctl/sudo)
#   завершает процесс. Живые вызовы: cmd_on этого файла и cmd_install
#   (commands.sh, без --no-autostart).
#
# @stdout string   # строка «автозапуск ВКЛ (unit + watchdog-таймер 1м,
#   linger=yes)»
# @returns integer # всегда 0 при возврате — отказы это die (render_tpl)
#   или завершение процесса по set -e
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

# Назначение: `podman compose up -d` под файловым lock'ом: параллельные
#   поднятия (вотчдог + boot-юнит + ручной up) дерутся за netns — пускаем
#   только один одновременно.
#
# Побочные эффекты: создание/усечение lock-файла $STACK_DIR/.hfctl.lock
#   (перенаправление fd 9 в субшелле) с неблокирующим flock, отпускаемым
#   по выходе субшелла; `podman compose up -d` — запуск
#   контейнеров (подтяжка образа, init-скачка моделей); stdout — сообщение
#   пропуска или последние 2 строки compose-вывода.
#
# Ограничения/допущения: требует глобалы STACK_DIR (диспетчер), CF и
#   compose (stack.sh). Гонка lock'а НЕ ошибка: «up уже выполняется —
#   пропуск» и return 0 — boot/watchdog намеренно зовут конкурентно. rc
#   compose up проходит наверх через pipefail (tail сам не падает). Живые
#   вызовы этого файла: cmd_up (голый вызов под set -e), cmd_boot (в
#   ветвлении if), cmd_watchdog (через `|| true`).
#
# @stdout string   # «up уже выполняется — пропуск» при занятом lock'е либо
#   последние 2 строки `compose up -d`
# @returns integer # 0 — стек поднят или пропуск по гонке; ненулевой rc —
#   сбой `compose up -d` (pipefail пропускает rc наружу)
hf_up_locked() {
  ( flock -n 9 || { echo "up уже выполняется — пропуск"; return 0; }
    compose up -d 2>&1 | tail -2
  ) 9>"$STACK_DIR/.hfctl.lock"
}

# Назначение: внутренняя команда `_boot` загрузочного юнита
#   hipfire-compose.service (ExecStart = /usr/bin/env bash
#   $STACK_DIR/hfctl _boot): поднять стек при загрузке, когда GPU-ноды
#   появляются позже юнит-менеджера юзера.
#
# Побочные эффекты: через hf_up_locked — lock-файл $STACK_DIR/.hfctl.lock и
#   `compose up -d`; при неудаче (каждая 3-я попытка) то же под lock'ом, но
#   с --force-recreate — пересоздание контейнера (номера /dev/dri меняются
#   между загрузками, путь устройства печатается в конфиг контейнера);
#   podman inspect состояния контейнера; чтение /dev/dri/renderD* и
#   /dev/kfd; sleep 10 между попытками; по истечении бюджета — сообщение в
#   stderr.
#
# Ограничения/допущения: вызывается только из systemd (ExecStart
#   compose-юнита, рендерится из tpl/systemd/hipfire-compose.service.tpl),
#   не пользовательская команда. Бюджет: 24 попытки по 10 с (локал i —
#   номер попытки из seq 1 24, целое 1..24) ≈ 4 мин; юнит со
#   TimeoutStartSec=900 и Restart=on-failure добирает остальное. Гейт нод —
#   renderD* + /dev/kfd (у Halo card0 может не быть вовсе — нумерация с 1,
#   AGENTS-грабля 5). Периодический force-recreate выполняется ВНУТРИ
#   удерживаемого flock: при занятом lock'е пропуск (не ошибка, следующий
#   цикл догонит). rc=1 для юнита — штатный сигнал неудачи
#   (Restart=on-failure).
#   Требует глобалы CONTAINER, STACK_DIR (диспетчер), CF и compose
#   (stack.sh), hf_up_locked этого файла.
#
# @returns integer # 0 — контейнер в состоянии running; 1 — бюджет 4 мин
#   исчерпан (сообщение в stderr)
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
    # /dev/dri между загрузками) — пересоздаём контейнер раз в 3 попытки,
    # ВНУТРИ удерживаемого lock'а (flock -n 9 && … — при занятом lock'е
    # recreate НЕ выполняется: конкурент (watchdog/up) уже что-то делает,
    # следующий цикл догонит; гонка правки 336cd1f снята)
    [ $((i % 3)) -eq 0 ] && ( flock -n 9 && compose up -d --force-recreate 2>&1 | tail -1 || true ) 9>"$STACK_DIR/.hfctl.lock" || true
    sleep 10
  done
  echo "boot: контейнер так и не запущен за 4 мин" >&2
  return 1
}

# Назначение: внутренняя команда `_watchdog` вотчдог-таймера
#   (hipfire-compose-watchdog.service, OnUnitActiveSec=1min, ExecStart =
#   bash $STACK_DIR/hfctl _watchdog): если контейнер не running и стек не
#   остановлен ЯВНО — поднять его.
#
# Побочные эффекты: чтение маркера $STACK_DIR/.hfctl-stopped и состояния
#   контейнера (podman inspect); при необходимости — дописывание строки с
#   ISO-временем в $STACK_DIR/.hfctl-watchdog.log (stderr заглушён, сбой
#   дописи глушится `|| true`) и hf_up_locked (lock-файл + `compose up -d`,
#   rc заглушён `|| true`).
#
# Ограничения/допущения: вызывается только из systemd, не для ручного
#   запуска. Маркер на месте — немедленный return 0 без побочных эффектов
#   (явный `hfctl down`/`off` глушит вотчдог). Локал st — состояние
#   podman (`running`/`exited`/`created`/`paused`…) либо `missing` —
#   fallback-заглушка `|| echo missing` при недоступном inspect; любой
#   st ≠ running считается падением. Требует глобалы CONTAINER, STOP_MARKER,
#   STACK_DIR (диспетчер), CF/compose (stack.sh) и hf_up_locked этого
#   файла.
#
# @returns integer # всегда 0 — все отказные rc заглушены (`|| true`,
#   `[ -f … ] &&`), здоровый контейнер тоже даёт 0
cmd_watchdog() {
  [ -f "$STOP_MARKER" ] && return 0
  local st
  st=$(podman inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)
  if [ "$st" != running ]; then
    echo "$(date -Is) watchdog: container state=$st -> up" >> "$STACK_DIR/.hfctl-watchdog.log" 2>/dev/null || true
    hf_up_locked || true
  fi
}
