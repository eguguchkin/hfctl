# shellcheck shell=bash
# ── автозапуск: юниты (render из tpl), on/off/up/down, boot-юнит, вотчдог ───

# ── константы GPU-гейта (env-переопределение — только для shell-приёмок) ────
KFD_NODE="${HFCTL_KFD:-/dev/kfd}"            # нода ROCm/NPU; env HFCTL_KFD — selfcheck
DRI_GLOB="${HFCTL_DRI:-/dev/dri/renderD*}"   # глоб render-нод; env HFCTL_DRI — selfcheck
GPU_WAIT_TIMEOUT=60  # сек ожидания GPU-нод перед первым up в _boot (gpu_ready_or_die)
GPU_WAIT_INTERVAL=2  # интервал опроса GPU-нод в gpu_ready_or_die

# ── константы самолечения (env-оверрайды — только для selfcheck-батареи,
#    продом не переопределяются) ─────────────────────────────────────────────
LOCK_STALE_SECS="${HFCTL_LOCK_STALE:-900}"   # порог «зависший держатель лока», с
                                             # (= TimeoutStartSec юнита: легитимный
                                             # up ≤ ~7 мин + хвост; дольше — SIGKILL-
                                             # выживший, см. GOTCHAS окна 2026-11-21)
HEAL_MAX="${HFCTL_HEAL_MAX:-2}"              # кап storage-самолечений за процесс
HF_ORPHAN_HEALS=0                            # счётчик storage-самолечений (глобал)

# Назначение: предикат «GPU-ноды на месте» — /dev/kfd И хотя бы одна renderD*;
#   гейт перед любым compose up в _boot/_watchdog: ранний up при полупустом
#   /dev/dri печатает в свежесозданный контейнер неполный device-снэпшот.
#
# Побочные эффекты: ничего не печатает и не меняет — только возвращаемый код.
#
# Ограничения/допущения: пути берёт из KFD_NODE/DRI_GLOB (верх файла; env
#   HFCTL_KFD/HFCTL_DRI — приёмки selfcheck, в проде не переопределяются).
#   compgen — builtin, внешних вызовов нет. У Halo card0 может не быть вовсе
#   (нумерация с 1) — предикат намеренно НЕ смотрит card*.
#
# @returns integer # 0 — kfd есть и renderD* есть; 1 — иначе
gpu_present() { [ -e "$KFD_NODE" ] && compgen -G "$DRI_GLOB" >/dev/null; }

# Назначение: дождаться появления GPU-нод (gpu_present) перед первым compose
#   up в _boot: цикл с интервалом GPU_WAIT_INTERVAL до GPU_WAIT_TIMEOUT секунд;
#   по таймауту — die с диагностикой (kfd есть/нет + вывод ls /dev/dri) —
#   юнит перезапустит _boot сам (Restart=on-failure), причина останется в
#   journal вместо молчаливого цикла.
#
# Побочные эффекты: sleep GPU_WAIT_INTERVAL за итерацию ожидания; date +%s
#   (дедлайн = старт + GPU_WAIT_TIMEOUT); чтение каталога /dev/dri (ls, для
#   диагностики); при таймауте die() завершает весь процесс диспетчера (rc 1).
#
# Ограничения/допущения: требует gpu_present этого файла и die (диспетчер).
#   Бюджет один и тот же для «ноды ещё не появились» и «не появились никогда»
#   (60 с); amdgpu грузится за секунды, EFI-fb-заглушка даёт card* БЕЗ
#   renderD* — гейт по renderD* её отсекает. Живой вызов один: cmd_boot
#   перед циклом попыток up.
#
# @returns integer # 0 — ноды на месте; при таймауте не возвращается
#   (die: exit 1)
gpu_ready_or_die() {
  local deadline dri
  deadline=$(( $(date +%s) + GPU_WAIT_TIMEOUT ))
  while ! gpu_present; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      dri=$(ls /dev/dri 2>/dev/null || true)
      die "boot: GPU-ноды не появились за ${GPU_WAIT_TIMEOUT}с (kfd: $([ -e "$KFD_NODE" ] && echo есть || echo нет); /dev/dri: ${dri:-каталога нет или пуст}) — amdgpu не поднялся?"
    fi
    sleep "$GPU_WAIT_INTERVAL"
  done
}

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
#   cmd_down) + явный podman stop основного контейнера ($CONTAINER, тихо и
#   отказоустойчиво — compose stop при rootless-netns баге бывает неполным,
#   §14 SPEC); systemctl --user disable hipfire-compose.service и
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
  # compose stop при rootless-netns баге (AppArmor pasta denied signal) падает
  # на init-контейнере ДО основного → молчаливо неполный stop; прямой podman stop
  # netns-teardown проекта не делает и доходит всегда (окно 2026-11-21).
  podman stop "$CONTAINER" >/dev/null 2>&1 || true   # fix:off-stop
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
#   STACK_DIR); install -m 0644 копирует статичный tpl/etc/hfctl-
#   containers.conf → $STACK_DIR/.hfctl-containers.conf (строго ДО рендера
#   юнитов — инвариант «юниты рендерятся только при наличии файла», §14);
#   install -m 0644 копирует статичный
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
  # CONTAINERS_CONF стека (скоуп slirp4netns, §14) — файл обязан существовать
  # К моменту рендера юнитов: юнит-шаблоны ссылаются на него через Environment.
  install -m 0644 "$TPL_DIR/etc/hfctl-containers.conf" "$STACK_DIR/.hfctl-containers.conf"   # fix:containers-conf
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

# Назначение: самолечение storage-сироты «already in use by an external
#   entity» (рассинхрон libpod-БД и storage-слоя podman, GOTCHAS окна
#   2026-11-21): вынуть ID контейнера-сироты из вывода up, удалить его
#   containers-storage delete-container и вернуть 0 — вызывающий делает один
#   retry up. Guard'ы: кап HEAL_MAX за процесс (HF_ORPHAN_HEALS); отсутствие
#   бинаря containers-storage → WARN с ручной командой, поведение как прежде
#   (Variant B); ID, видимый libpod, — НЕ сирота, трогать нельзя (страховка
#   от удаления живого контейнера при обратном рассинхроне).
#
# Побочные эффекты: при успехе — containers-storage delete-container <ID>
#   (самолечение засчитано в глобал HF_ORPHAN_HEALS) и log-строка; при отказе
#   хила — warn-строка в stderr. Ничего не удаляет, кроме сироты из текста.
#
# Ограничения/допущения: требует глобалы HF_ORPHAN_HEALS/HEAL_MAX (шапка) и
#   log/warn (диспетчер). Синтаксис хила — containers-storage-delete-container(1)
#   (флагов -f нет; отказ → WARN, поведение = прежнее). ID ищется по
#   сигнатуре «already in use by <12..64-hex>»; grep глушен `|| true` —
#   пустой ID = не сирота (rc 1). Вызывается из hf_up_locked и hf_up_devsafe
#   только при контейнере ≠ running (happy-path не зовёт).
#
# @param 1: string  # полный вывод неудачного `compose up` (2>&1)
# @stdout string   # log-строка при успехе; warn-строки при отказе (stderr)
# @returns integer # 0 — сирота найдена и удалена; 1 — сигнатуры нет / кап /
#   бинаря нет / ID видит libpod / delete-container отказался
hf_orphan_heal() {
  local id
  id=$(printf '%s' "$1" | { grep -oE 'already in use by [0-9a-f]{12,64}' || true; } | head -1 | awk '{print $5}')
  [ -n "$id" ] || return 1
  [ "$HF_ORPHAN_HEALS" -lt "$HEAL_MAX" ] || return 1        # кап за процесс
  command -v containers-storage >/dev/null || { warn "containers-storage нет в PATH — самолечение невозможно: sudo apt install containers-storage; вручную: containers-storage delete-container $id"; return 1; }
  podman inspect -f '{{.State.Status}}' "$id" >/dev/null 2>&1 && { warn "ID $id видит libpod — не сирота, самолечение отменено"; return 1; }
  HF_ORPHAN_HEALS=$((HF_ORPHAN_HEALS + 1))
  containers-storage delete-container "$id" || { warn "containers-storage delete-container $id отказался"; return 1; }
  log "storage-сирота $id удалена (external entity) — повторяю up"
}

# Назначение: реклейм зависших держателей $STACK_DIR/.hfctl.lock — при неудаче
#   первого `flock -n` (up/_boot/_watchdog голодали на SIGKILL-выживших,
#   GOTCHAS окна 2026-11-21): идентифицировать держателей (fuser), убить
#   kill -9 только если держатель старше LOCK_STALE_SECS И его cmdline
#   матчит `podman|hfctl`. Свежий держатель (здоровый параллельный
#   boot/watchdog/up) не трогается; нет fuser — тихая деградация к прежнему
#   поведению («пропуск»).
#
# Побочные эффекты: чтение /proc через fuser/ps; kill -9 зрелых podman/hfctl-
#   держателей (ядро отпускает flock по закрытию fd); ни одного процесса
#   не порождает в happy-path (зовётся только после неудачи flock -n).
#
# Ограничения/допущения: требует глобал STACK_DIR и LOCK_STALE_SECS (шапка).
#   Порог 900 с = TimeoutStartSec юнита: тик вотчдога/boot держит лок секунды,
#   ручной up > 15 мин легитимно невозможен (образ спиннут, init-pull моделей
#   идёт ВНУТРИ контейнера). Подмена argv (`exec -a`) может ввести в заблуждение
#   cmdline-предикат — окно сужает etimes-порог. Вызывается из обоих up-субшеллов.
#
# @returns integer # всегда 0 — отказы (нет fuser, процесс исчез, kill не взял)
#   глушены; решение «реклейм не удался» принимает вызывающий вторым flock -n
hf_lock_reclaim() {
  local pids p age args
  pids=$(fuser "$STACK_DIR/.hfctl.lock" 2>/dev/null) || return 0
  # нет fuser — пробуем lsof; нет ни того ни другого → тихая деградация
  for p in $pids; do
    kill -0 "$p" 2>/dev/null || continue
    age=$(ps -o etimes= -p "$p" 2>/dev/null || true); [ -n "$age" ] || continue
    [ "$age" -gt "$LOCK_STALE_SECS" ] || continue             # свежий — не трогать
    args=$(ps -o args= -p "$p" 2>/dev/null || true)
    printf '%s' "$args" | grep -qE 'podman|hfctl' || continue  # чужой процесс — не трогать
    kill -9 "$p" 2>/dev/null || true                           # ядро отпустит flock
  done
}

# Назначение: pristine-проверка pod'а проекта перед up — pod_hipfire в
#   состоянии Created с ПУСТЫМ InfraContainerID (наследие эпохи падавших up,
#   GOTCHAS окна 2026-11-21) переживает всё и ломает каждый create:
#   podman pod rm -f → штатный up пересоздаст pod сам. Pod нет / inspect
#   отказал (свежий стек) → no-op.
#
# Побочные эффекты: podman pod inspect (чтение); при пустом INFRA ID —
#   warn-строка и podman pod rm -f pod_hipfire (вывод заглушён, отказ
#   глушен `|| true`).
#
# Ограничения/допущения: имя pod_hipfire захардкожено так же, как CONTAINER и
#   лейбл io.podman.compose.project (проект compose = имени каталога стека).
#   Зовётся ВНУТРИ лока обоих up-субшеллов до первого compose up — не гоняется
#   с вотчдогом. Требует warn (диспетчер).
#
# @returns integer # всегда 0 — inspect-отказ (no-op) и удачный rm дают 0
hf_pod_pristine() {
  local infra
  infra=$(podman pod inspect pod_hipfire --format '{{.InfraContainerID}}' 2>/dev/null) || return 0
  [ -n "$infra" ] || { warn "pod_hipfire с пустым INFRA ID — пересоздаю"; podman pod rm -f pod_hipfire >/dev/null 2>&1 || true; }
}

# Назначение: `podman compose up -d` под файловым lock'ом: параллельные
#   поднятия (вотчдог + boot-юнит + ручной up) дерутся за netns — пускаем
#   только один одновременно. При занятом локе — попытка реклейма зависших
#   держателей (hf_lock_reclaim, §14) и второй flock -n; при storage-сироте
#   в выводе up (уже running-контейнер ≠ и сигнатура «external entity») —
#   hf_orphan_heal + один retry up (максимум ДВЕ попытки up на вызов).
#
# Побочные эффекты: создание/усечение lock-файла $STACK_DIR/.hfctl.lock
#   (перенаправление fd 9 в субшелле) с неблокирующим flock, отпускаемым
#   по выходе субшелла; при занятом локе — hf_lock_reclaim (kill -9 зрелых
#   podman/hfctl-держателей); hf_pod_pristine (возможный podman pod rm -f
#   pod_hipfire при пустом INFRA ID); до двух `podman compose up -d` — запуск
#   контейнеров (подтяжка образа, init-скачка моделей); podman inspect
#   статуса контейнера; stdout — сообщение пропуска или последние 2 строки
#   compose-вывода.
#
# Ограничения/допущения: требует глобалы STACK_DIR, CONTAINER (диспетчер),
#   CF/compose (stack.sh) и hf_lock_reclaim/hf_pod_pristine/hf_orphan_heal
#   этого файла. Гонка lock'а НЕ ошибка: «up уже выполняется — пропуск» и
#   return 0 — boot/watchdog намеренно зовут конкурентно; реклейм трогает
#   только зрелых (LOCK_STALE_SECS) podman/hfctl-держателей. rc финального up
#   проходит наверх (return rc): happy-path/вылеченный up → 0, невылеченный
#   отказ → rc 1 (cmd_up умирает по set -e до wait_health — как прежде).
#   Лечение запускается ТОЛЬКО при контейнере ≠ running (happy-path без
#   лишних inspect-веток). Живой вызов этого файла: cmd_up (cmd_on поднимает
#   через cmd_up).
#
# @stdout string   # «up уже выполняется — пропуск» при занятом lock'е либо
#   последние 2 строки последнего `compose up -d`
# @returns integer # 0 — стек поднят (сразу или после самолечения) или
#   пропуск по гонке; ненулевой rc — финальный сбой `compose up -d`
hf_up_locked() {
  ( if ! flock -n 9; then
      hf_lock_reclaim              # fix:lock-reclaim
      flock -n 9 || { echo "up уже выполняется — пропуск"; return 0; }
    fi
    hf_pod_pristine                # fix:pod-infra
    local out rc=0
    out=$(compose up -d 2>&1) || rc=$?
    if [ -n "$out" ]; then printf '%s\n' "$out" | tail -2; fi
    [ "$(podman inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" = running ] || { hf_orphan_heal "$out" && { rc=0; out=$(compose up -d 2>&1) || rc=$?; if [ -n "$out" ]; then printf '%s\n' "$out" | tail -2; fi; }; }   # fix:orphan-heal
    return "$rc"
  ) 9>"$STACK_DIR/.hfctl.lock"
}

# Назначение: `compose up -d` под неблокирующим lock'ом с авто-лечением
#   device-mismatch и storage-сироты: podman запечатывает снэпшот /dev/dri в
#   OCI-спеку при create, а нумерация карточек меняется между загрузками →
#   старт СТАРОГО контейнера в новом буте падает «cannot stat …» / «Failed to
#   create container», и обычный up никогда не лечится; рассинхрон libpod-БД
#   и storage-слоя даёт «already in use by … external entity» (GOTCHAS окна
#   2026-11-21). Если после up контейнер проекта не running, диагноз выбирает
#   ОДНО лечение: девайс-ветка (сигнатура cannot stat/Failed to create
#   container → podman rm -f по лейблу io.podman.compose.project) либо
#   hf_orphan_heal (сигнатура сироты → containers-storage delete-container),
#   затем один retry up: свежий create запечатывает актуальную нумерацию /
#   чистый storage. Максимум ДВЕ попытки up на вызов. До первого up —
#   hf_lock_reclaim при занятом локе и hf_pod_pristine.
#
# Побочные эффекты: создание/усечение lock-файла $STACK_DIR/.hfctl.lock
#   (неблокирующий flock, отпускается субшеллом; при занятом — реклейм
#   зрелых держателей); hf_pod_pristine (возможный podman pod rm -f
#   pod_hipfire); до двух `compose up -d` (в stdout — последние 2 строки
#   вывода последнего); при сигнатуре — podman ps -aq --filter label=… и
#   podman rm -f найденных контейнеров, либо containers-storage
#   delete-container сироты (оба — вывод заглушён); два podman inspect
#   статуса контейнера.
#
# Ограничения/допущения: требует глобалы STACK_DIR, CONTAINER (диспетчер),
#   CF/compose (stack.sh) и hf_lock_reclaim/hf_pod_pristine/hf_orphan_heal
#   этого файла. rc compose-вызовов заглушен (`|| true`): падение
#   распознаётся по паре «статус ≠ running + сигнатура в выводе», не по rc —
#   иные отказы up (pull, сеть) НЕ лечатся (rm не вызывается), хелпер
#   возвращает 1, дальше решает вызывающий (цикл _boot / тихий уход
#   вотчдога). Девайс-сигнатура проверяется первой — при ней hf_orphan_heal
#   не зовётся (одно лечение на вызов); кап хилов — HEAL_MAX за процесс.
#   Гонка lock'а — не ошибка: «пропуск» и 0 (как hf_up_locked). Лейбл
#   проекта «hipfire» от каталога стека; если будущий podman-compose сменит
#   лейбл, rm не найдёт целей и деградация равна прежнему поведению (юнит
#   перезапустит _boot по rc 1). Не проверяет здоровье движка — только
#   статус контейнера. Живые вызовы: cmd_boot (в цикле) и cmd_watchdog
#   (через `|| true`) этого файла.
#
# @stdout string   # «up уже выполняется — пропуск» при занятом lock'е либо
#   последние 2 строки последнего `compose up -d`
# @returns integer # 0 — контейнер проекта running (сразу или после
#   rm+повторного up / хила сироты); 1 — не running (отказ не девайсный и
#   не сирота, либо retry не спас)
hf_up_devsafe() {
  ( if ! flock -n 9; then
      hf_lock_reclaim              # fix:lock-reclaim
      flock -n 9 || { echo "up уже выполняется — пропуск"; return 0; }
    fi
    hf_pod_pristine                # fix:pod-infra
    local out
    out=$(compose up -d 2>&1) || true
    if [ -n "$out" ]; then printf '%s\n' "$out" | tail -2; fi
    if [ "$(podman inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" != running ]; then
      if printf '%s' "$out" | grep -qE 'cannot stat|Failed to create container'; then
        podman rm -f $(podman ps -aq --filter label=io.podman.compose.project=hipfire) >/dev/null 2>&1 || true
        out=$(compose up -d 2>&1) || true
        if [ -n "$out" ]; then printf '%s\n' "$out" | tail -2; fi
      elif hf_orphan_heal "$out"; then
        out=$(compose up -d 2>&1) || true   # fix:orphan-heal
        if [ -n "$out" ]; then printf '%s\n' "$out" | tail -2; fi
      fi
    fi
    [ "$(podman inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" = running ]
  ) 9>"$STACK_DIR/.hfctl.lock"
}

# Назначение: внутренняя команда `_boot` загрузочного юнита
#   hipfire-compose.service (ExecStart = /usr/bin/env bash
#   $STACK_DIR/hfctl _boot): поднять стек при загрузке; перед первым up —
#   дождаться GPU-нод (gpu_ready_or_die, die с диагностикой по таймауту);
#   каждый up идёт через hf_up_devsafe — при девайс-отказе create/start
#   («cannot stat», «Failed to create container») контейнер проекта
#   удаляется и создаётся заново (запечатанный в OCI-спеке снэпшот /dev/dri
#   обновляется до актуальной нумерации).
#
# Побочные эффекты: gpu_ready_or_die — sleep по GPU_WAIT_INTERVAL, до 60 с,
#   die по таймауту; в цикле — hf_up_devsafe (rc заглушен `|| true`,
#   результат решает inspect ниже; lock-файл, до двух
#   `compose up -d` и `podman rm -f` за итерацию — см. его контракт),
#   podman inspect состояния контейнера; чтение KFD_NODE и DRI_GLOB,
#   /dev/dri (ls в диагностике); date +%s (дедлайн); sleep 10 между
#   попытками; по исчерпании бюджета — сообщение в stderr и rc 1 (юнит
#   перезапускается самим systemd).
#
# Ограничения/допущения: вызывается только из systemd (ExecStart
#   compose-юнита, рендерится из tpl/systemd/hipfire-compose.service.tpl),
#   не пользовательская команда. Бюджет: gpu_ready_or_die ≤ 60 с + цикл
#   deadline = старт + 420 с (локал deadline — целые unix-секунды
#   `date +%s`), проверка в начале каждой попытки; потолок 48 попыток
#   (локал i — номер из seq 1 48) — страховка от стоящих часов; хвост
#   попытки, начатой до дедлайна: два compose-вызова + rm + sleep 10 ≈
#   ≤2–3 мин → итог ≤ ~10 мин, в пределах TimeoutStartSec=900 юнита
#   (внешняя крышка systemd для зависшего compose). Гейт нод повторяется
#   в начале каждой попытки (gpu_present): EFI-fb-заглушка даёт card*
#   БЕЗ renderD* — гейт по renderD*+kfd отсекает её; у Halo card0 может
#   не быть вовсе (нумерация с 1, AGENTS-грабля 5). rc=1 для юнита —
#   штатный сигнал неудачи (Restart=on-failure, RestartSec=30). Требует
#   глобалы CONTAINER, STACK_DIR (диспетчер), CF/compose (stack.sh),
#   gpu_present/gpu_ready_or_die/hf_up_devsafe этого файла.
#
# @returns integer # 0 — контейнер в состоянии running; 1 — бюджет ~7 мин
#   исчерпан (сообщение в stderr; systemd перезапустит юнит)
cmd_boot() {
  local i deadline
  gpu_ready_or_die
  # бюджет цикла: 420 с + хвост ≤ ~3 мин, плюс ≤60 с GPU-wait < TimeoutStartSec=900
  deadline=$(( $(date +%s) + 420 ))
  for i in $(seq 1 48); do
    [ "$(date +%s)" -ge "$deadline" ] && break
    if ! gpu_present; then sleep 10; continue; fi
    hf_up_devsafe || true
    if [ "$(podman inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" = running ]; then
      return 0
    fi
    sleep 10
  done
  echo "boot: контейнер так и не запущен за ~7 мин" >&2
  return 1
}

# Назначение: внутренняя команда `_watchdog` вотчдог-таймера
#   (hipfire-compose-watchdog.service, OnUnitActiveSec=1min, ExecStart =
#   bash $STACK_DIR/hfctl _watchdog): если контейнер не running и стек не
#   остановлен ЯВНО — поднять его; поднятие идёт через hf_up_devsafe (тот
#   же класс защиты, что у boot-юнита: девайс-отказ create/start лечится
#   rm+повторным up на месте — вотчдог больше не упирается в мёртвый
#   контейнер с запечатанной старой нумерацией /dev/dri до следующего
#   ребута).
#
# Побочные эффекты: чтение маркера $STACK_DIR/.hfctl-stopped, состояния
#   контейнера (podman inspect) и GPU-нод (gpu_present); при неготовом GPU —
#   тихий немедленный выход (ранний тик таймера после boot: up при
#   полупустом /dev/dri запечатал бы неполный снэпшот в свежий контейнер);
#   при необходимости — дописывание строки с ISO-временем в
#   $STACK_DIR/.hfctl-watchdog.log (stderr заглушён, сбой дописи глушится
#   `|| true`) и hf_up_devsafe (lock-файл + до двух compose up + возможный
#   rm, rc заглушён `|| true`).
#
# Ограничения/допущения: вызывается только из systemd, не для ручного
#   запуска. Маркер на месте — немедленный return 0 без побочных эффектов
#   (явный `hfctl down`/`off` глушит вотчдог); гейт GPU — вторым (маркер
#   старше: явная остановка уважается даже без GPU). Тихий отказ тика при
#   неготовом GPU выбран вместо короткого ожидания: вотчдог минутный, он
#   просто вернётся через минуту, а бюджет тика остаётся секундным.
#   Локал st — состояние podman (`running`/`exited`/`created`/`paused`…)
#   либо `missing` — fallback-заглушка `|| echo missing` при недоступном
#   inspect; любой st ≠ running считается падением. Требует глобалы
#   CONTAINER, STOP_MARKER, STACK_DIR (диспетчер), CF/compose (stack.sh) и
#   gpu_present/hf_up_devsafe этого файла.
#
# @returns integer # всегда 0 — все отказные rc заглушены (`|| true`,
#   `[ … ] &&`), здоровый контейнер и неготовый GPU тоже дают 0
cmd_watchdog() {
  [ -f "$STOP_MARKER" ] && return 0
  gpu_present || return 0
  local st
  st=$(podman inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)
  if [ "$st" != running ]; then
    echo "$(date -Is) watchdog: container state=$st -> up" >> "$STACK_DIR/.hfctl-watchdog.log" 2>/dev/null || true
    hf_up_devsafe || true
  fi
}
