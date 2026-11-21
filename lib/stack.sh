# shellcheck shell=bash
# ── стек: обёртка compose, чтение .env, префлайт ────────────────────────────
# Модуль определяет глобал CF (каноническая тройка -f compose-файлов) и
# читает глобалы диспетчера STACK_DIR, MEMLOCK и хелперы log/warn/die,
# PROFILE_DEFAULT и profile_field — из lib/profiles.sh. Вызывается из
# commands.sh, autostart.sh, bench.sh, engine.sh, health.sh, stack_files.sh.
# .env этот модуль только читает (env_val); вся запись .env — write_env в
# stack_files.sh.
CF=( -f compose.yml -f compose.halo.yml -f compose.local.yml )

# Назначение: единая обёртка `podman compose` над канонической тройкой -f
#   (CF: compose.yml + compose.halo.yml + compose.local.yml) с рабочим
#   каталогом $STACK_DIR — podman-compose не читает COMPOSE_FILE, поэтому
#   -f перечисляются при каждом вызове (здесь и собрано это «каждом»).
#   При наличии $STACK_DIR/.hfctl-containers.conf — CONTAINERS_CONF скоупится
#   на стек (slirp4netns вместо pasta, обход AppArmor-бага teardown netns,
#   §14 SPEC); файла нет (старый стек до обновления) → env чист, поведение
#   как прежде. Глобальный ~/.config/containers не трогается никогда.
#
# Побочные эффекты: всё, что делает podman compose подкоманда: lifecycle
#   контейнеров и томов (up/stop/down), одноразовые run-контейнеры, подтяжка
#   образа, чтение compose-троек из $STACK_DIR; экспорт CONTAINERS_CONF в
#   окружение субшелла (только когда файл стека на месте). cwd вызывающего
#   не меняется (cd выполняется в субшелле).
#
# Ограничения/допущения: требуются глобал STACK_DIR (диспетчер) и CF этого
#   файла. Имя функции затеняет внешний одноимённый бинарь compose. stdout
#   pass-through: живые вызывающие сами tail-ят вывод или заглушают rc
#   (`|| true` в autostart.sh watchdog/boot). Сбой cd при отсутствующем
#   STACK_DIR даёт rc субшелла без вывода. Прямые podman-вызовы hfctl
#   (inspect/stop/rm) env не получают — сетевой бэкенд значим только при
#   create/netns, storage общий (EXP-013: graphRoot идентичен с env и без).
#
# @param 1: string[] # rest от $1: подкоманда и флаги podman compose (живые:
#   run, up -d [--force-recreate], stop, down)
# @stdout string     # вывод podman compose как есть (stderr НЕ слит —
#   сливают вызывающие через 2>&1)
# @returns integer   # rc podman compose либо rc cd при недоступном STACK_DIR
compose() { ( cd "$STACK_DIR" || exit
  # скоуп containers.conf только для стека (файл нет → env чист, как прежде)
  if [ -f "$STACK_DIR/.hfctl-containers.conf" ]; then export CONTAINERS_CONF="$STACK_DIR/.hfctl-containers.conf"; fi   # fix:containers-conf
  podman compose "${CF[@]}" "$@" ); }

# Назначение: значение ключа из $STACK_DIR/.env — первая строка вида
#   КЛЮЧ=...; значение берётся справа от первого '=' целиком (значение может
#   содержать '=').
#
# Побочные эффекты: только печать в stdout; читает файл .env; НЕ меняет
#   файлов (вся запись .env — write_env в stack_files.sh).
#
# Ограничения/допущения: требуется глобал STACK_DIR. Ключ подставляется в
#   шаблон grep -E без экранирования — безопасны только заглавные буквы,
#   цифры и подчёркивание (живые ключи: HFCTL_PROFILE, HIPFIRE_MODEL,
#   HIPFIRE_PORT, HIPFIRE_BIND, HIPFIRE_MODELS_PATH, HIPFIRE_IMAGE).
#   Отсутствие .env или ключа даёт пустой stdout и rc 0: сбой grep глушится
#   `|| true`, так что «ключа нет» неотличимо от «пустое значение» —
#   вызывающие проверяют вывод через [ -n "$v" ].
#
# @param 1: /^[A-Z][A-Z0-9_]*$/ # имя ключа .env (живые ключи — в Ограничениях)
# @stdout string                # значение справа от первого '=' (первое
#   совпадение); '' — ключа или .env нет
# @returns integer              # всегда 0 — отказ grep без совпадения
#   заглушён `|| true`
env_val() { [ -f "$STACK_DIR/.env" ] && grep -E "^$1=" "$STACK_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2- || true; }

# Назначение: id профиля развёрнутого стека — HFCTL_PROFILE из
#   $STACK_DIR/.env; при пустом/отсутствующем ключе — PROFILE_DEFAULT
#   (profiles.sh).
#
# Побочные эффекты: только печать в stdout; читает .env (через env_val) и
#   глобал PROFILE_DEFAULT; файлов и глобалов не меняет.
#
# Ограничения/допущения: значение из .env берётся КАК ЕСТЬ — канонический
#   id гарантирован только когда .env писан write_env (stack_files.sh);
#   нормализация resolve_profile на совести вызывающих. Живые вызовы:
#   commands.sh (install/use/status), stack_files.sh (draft для
#   compose.local.yml), bench.sh, cur_model этого файла.
#
# @stdout '27b-single' | '27b-slots' | 'flash-multi' # активный профиль
#   (verbatim из .env — см. Ограничения)
# @returns integer                                   # всегда 0 — финальный echo
cur_profile() { local p; p=$(env_val HFCTL_PROFILE); echo "${p:-$PROFILE_DEFAULT}"; }

# Назначение: модель, которую сервер использует по умолчанию (для smoke,
#   статуса и bench) — HIPFIRE_MODEL из $STACK_DIR/.env.
#
# Побочные эффекты: только печать в stdout; читает .env через env_val;
#   глобалы не меняет.
#
# Ограничения/допущения: '' при отсутствии ключа HIPFIRE_MODEL в .env —
#   env_val всегда возвращает 0 (`|| true` внутри), поэтому дефолт профиля
#   НЕ подставляется; прежний fallback `|| echo "$(profile_field …)"` был
#   недостижим и удалён (поведение не меняется). Отсутствие .env даёт тот
#   же пустой stdout; живые вызывающие (health.sh smoke, commands.sh
#   status/use, bench.sh) die-ят на отсутствующий .env заранее.
#
# @stdout /^[\w.-]+:[\w.-]+$/ | '' # HIPFIRE_MODEL verbatim из .env; '' — ключа нет
# @returns integer                 # всегда 0 — rc env_val (всегда 0)
cur_model()   { env_val HIPFIRE_MODEL; }

# ── префлайт и хост-подготовка ──────────────────────────────────────────────
# Назначение: GPU-подготовка хоста (И1 «Инварианты поставки») —
#   самодостаточный шаг preflight (отдельная функция = единица переезда в
#   bootstrap этапа 14): гейт по наличию устройств (/dev/kfd ИЛИ /dev/dri),
#   группы render,video для rootless-доступа к GPU, limits.d memlock из
#   шаблона tpl/etc для NPU-trunk. На машине без GPU-устройств —
#   info-пропуск и НОЛЬ мутаций (die по §6.3 остаётся в preflight после
#   этого шага).
#
# Побочные эффекты: при наличии устройств — возможно sudo usermod -aG
#   render,video $USER (когда какой-то из групп нет в id -nG; затем честный
#   warn и exit 42 — группы действуют только после перезахода) и возможно
#   sudo install -m 0644 limits-файла (рендер
#   tpl/etc/99-hipfire-memlock.conf.tpl с __USER__/__MEMLOCK__; пишется
#   только когда файла нет ИЛИ содержимое отличается от рендера — cmp;
#   сразу после записи при низком ulimit -Hl текущей сессии — прежний warn
#   и exit 42). Временный файл рендера удаляется во всех ветках. Читает
#   id -nG, ulimit -Hl. В stdout — log-строки, в stderr — warn().
#
# Ограничения/допущения: требует глобалы MEMLOCK, TPL_DIR (диспетчер),
#   render_tpl (stack_files.sh) и log/warn/die. env-крючки — только
#   selfcheck, прод не переопределяет: HFCTL_KFD/HFCTL_DRI — пути гейта
#   (дефолты /dev/kfd, /dev/dri; шапка autostart.sh использует те же имена
#   с другими дефолтами — glob renderD*; конфликтов нет: разные сценарии,
#   в проде env пуст), HFCTL_LIMITS — путь limits-файла (дефолт
#   /etc/security/limits.d/99-hipfire-memlock.conf; doctor и uninstall
#   продолжают хардкодить фактическое имя — прод-путь одинаков). Нет
#   группы render/video в системе → usermod умирает по set -e со своим rc —
#   громкий честный отказ (Ubuntu/Debian обе группы имеют). Крайний случай
#   kfd-нет + dri-есть (полусломанный драйвер): шаг применится, затем
#   preflight умрёт по §6.3 — мутации идемпотентны и безвредны.
#
# @returns integer # всегда 0 при возврате — exit 42 (перезаход/ребут)
#   завершает процесс, не возвращаясь вызывающему
gpu_prep() {
  local kfd="${HFCTL_KFD:-/dev/kfd}" dri="${HFCTL_DRI:-/dev/dri}"
  # GPU-подготовка хоста (И1): только при наличии устройств; не-GPU — info-пропуск
  if [ -e "$kfd" ] || [ -e "$dri" ]; then
    if ! id -nG | grep -qw render || ! id -nG | grep -qw video; then
      log "добавляю $USER в группы render,video (sudo точечно)"
      sudo usermod -aG render,video "$USER"                        # fix:gpu-groups
      warn "группы применятся только после перезахода. Выйди и зайди снова, затем повтори install."
      exit 42
    fi
    # memlock для NPU-trunk (limits.d; требует ребута/пересоздания сессий)
    local lim="${HFCTL_LIMITS:-/etc/security/limits.d/99-hipfire-memlock.conf}"
    local tmp; tmp=$(mktemp)
    render_tpl "$TPL_DIR/etc/99-hipfire-memlock.conf.tpl" "$tmp" \
      MEMLOCK="$MEMLOCK" USER="$USER"
    if ! cmp -s "$tmp" "$lim"; then
      log "пишу $lim (memlock $MEMLOCK)"
      sudo install -m 0644 "$tmp" "$lim"                           # fix:gpu-limits
      if [ "$(ulimit -Hl)" != "unlimited" ] && [ "$(ulimit -Hl)" -lt "$MEMLOCK" ]; then
        warn "текущая сессия ещё с memlock=$(ulimit -Hl). Требуется ребут (или перезаход+сервис-менеджер). Повтори install после ребута."
        rm -f "$tmp"; exit 42
      fi
    fi
    rm -f "$tmp"
  else
    log "GPU-устройства не найдены ($kfd, $dri) — GPU-подготовка пропущена"   # fix:gpu-gate
  fi
}

# Назначение: проверка окружения и разовая подготовка хоста перед
#   install/use: не-root, дистрибутив Ubuntu/Debian, GPU-подготовка хоста
#   (gpu_prep выше; на не-GPU машине — info-пропуск), AMD GPU (/dev/kfd —
#   железный гейт §6.3, отказ до apt/скачиваний), объём RAM, apt-пятёрка
#   (podman, podman-compose, containers-storage, psmisc, curl — одним
#   need-списком), linger для жизни сервера без логина и при boot. Живые
#   вызовы — cmd_install и cmd_use (commands.sh) до любых изменений системы.
#
# Побочные эффекты: sudo точечно — apt-get update + install (один вызов при
#   непустом need-списке; всё на месте — apt не вызывается вовсе),
#   usermod -aG render,video и limits-файл (см. gpu_prep),
#   loginctl enable-linger $USER. Читает /etc/os-release, /proc/meminfo,
#   группы юзера, свой ulimit -Hl, loginctl-свойство Linger. В stdout —
#   log-строки, в stderr — warn(). .env и файлы стека не трогает.
#
# Ограничения/допущения: запуск от root — die. Требуются глобалы MEMLOCK,
#   TPL_DIR (диспетчер), gpu_prep, render_tpl и log/warn/die. Локалы: id —
#   $ID из os-release (ubuntu и debian проходят, прочее die, затеняет
#   утилиту id), mem_kb — MemTotal в КиБ (порог 57671680 КиБ ≈ 58 GB
#   decimal, в тексте предупреждения назван ~58 GiB), need — строка имён
#   пакетов (разбиение намеренное: имена без пробелов). Порядок: GPU-шаг до
#   железного гейта и apt — не-GPU машина получает info-пропуск, затем die,
#   ноль мутаций до отказа; GPU-машина с неполными группами получает
#   exit 42 раньше apt (меньше sudo-работы до перезахода). Два намеренных
#   exit 42 — группы ещё не действуют и limits.d только что записан при
#   низком memlock текущей сессии — завершают процесс диспетчера с
#   требованием повторить install после перезахода/ребута; прочие отказы —
#   die (exit 1).
#
# @returns integer # всегда 0 при возврате — exit 42 (перезаход/ребут) и
#   die (exit 1) завершают процесс, не возвращаясь вызывающему
preflight() {
  [ "$(id -u)" != 0 ] || die "не запускай от root — работай от своего имени (sudo hfctl не нужен)"
  local id
  id=$(. /etc/os-release && echo "$ID")
  case "$id" in ubuntu|debian) ;; *) die "дистрибутив '$id' не поддерживается (нужен Ubuntu/Debian)" ;; esac
  gpu_prep
  # железный гейт §6.3: путь через хук (см. Ограничения gpu_prep), текст прежний
  [ -e "${HFCTL_KFD:-/dev/kfd}" ] || die "/dev/kfd нет: AMD GPU не виден (проверь драйвер amdgpu)"
  local mem_kb; mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  [ "$mem_kb" -ge 57671680 ] || warn "RAM ${mem_kb}kB < ~58 GiB: 27B@262K может не влезть (нужна Halo 60 GiB+)"
  # apt-пятёрка одним need-списком: containers-storage — inspect storage-сироты
  # (13.1 Ф2), psmisc даёт fuser для реклейма лока (13.1 Ф3)
  local need=""
  command -v podman >/dev/null             || need+=" podman"
  command -v podman-compose >/dev/null     || need+=" podman-compose"
  command -v containers-storage >/dev/null || need+=" containers-storage"   # fix:preflight-pkgs
  command -v fuser >/dev/null              || need+=" psmisc"               # fix:preflight-pkgs
  command -v curl >/dev/null               || need+=" curl"
  if [ -n "$need" ]; then
    log "установка пакетов:$need (sudo точечно)"
    sudo apt-get update -qq && sudo apt-get install -y -qq $need
  fi
  # linger: сервер должен жить без активного логина и при boot
  if [ "$(loginctl show-user "$USER" --property=Linger 2>/dev/null | cut -d= -f2)" != "yes" ]; then
    log "включаю linger для $USER (сервер переживает logout и стартует при boot)"
    sudo loginctl enable-linger "$USER"
  fi
}
