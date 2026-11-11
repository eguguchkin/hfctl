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
#
# Побочные эффекты: всё, что делает podman compose подкоманда: lifecycle
#   контейнеров и томов (up/stop/down), одноразовые run-контейнеры, подтяжка
#   образа, чтение compose-троек из $STACK_DIR. cwd вызывающего не меняется
#   (cd выполняется в субшелле).
#
# Ограничения/допущения: требуются глобал STACK_DIR (диспетчер) и CF этого
#   файла. Имя функции затеняет внешний одноимённый бинарь compose. stdout
#   pass-through: живые вызывающие сами tail-ят вывод или заглушают rc
#   (`|| true` в autostart.sh watchdog/boot). Сбой cd при отсутствующем
#   STACK_DIR даёт rc субшелла без вывода.
#
# @param 1: string[] # rest от $1: подкоманда и флаги podman compose (живые:
#   run, up -d [--force-recreate], stop, down)
# @stdout string     # вывод podman compose как есть (stderr НЕ слит —
#   сливают вызывающие через 2>&1)
# @returns integer   # rc podman compose либо rc cd при недоступном STACK_DIR
compose() { ( cd "$STACK_DIR" && podman compose "${CF[@]}" "$@" ); }

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
# Ограничения/допущения: ветка отказа `|| echo "$(profile_field
#   "$(cur_profile)" 1)"` НЕдостижима: env_val всегда возвращает 0
#   (`|| true` внутри), поэтому при отсутствии ключа HIPFIRE_MODEL в .env
#   stdout пустой — модель профиля по умолчанию НЕ подставляется. Отсутствие
#   .env даёт тот же пустой stdout; живые вызывающие (health.sh smoke,
#   commands.sh status/use, bench.sh) die-ят на отсутствующий .env заранее.
#
# @stdout /^[\w.-]+:[\w.-]+$/ | '' # HIPFIRE_MODEL verbatim из .env; '' —
#   ключа нет (fallback недостижим, см. Ограничения)
# @returns integer                 # всегда 0 — rc env_val (всегда 0),
#   fallback-ветка не выполняется
cur_model()   { env_val HIPFIRE_MODEL || echo "$(profile_field "$(cur_profile)" 1)"; }

# ── префлайт и хост-подготовка ──────────────────────────────────────────────
# Назначение: проверка окружения и разовая подготовка хоста перед
#   install/use: не-root, дистрибутив Ubuntu/Debian, AMD GPU (/dev/kfd),
#   объём RAM, podman + podman-compose + curl, группа render, memlock из
#   limits.d для NPU-trunk, linger для жизни сервера без логина и при boot.
#
# Побочные эффекты: sudo точечно — apt-get install podman/podman-compose и
#   curl (при отсутствии), usermod -aG render $USER, создание
#   /etc/security/limits.d/99-hipfire-memlock.conf (две строки memlock для
#   $USER через tee/tee -a), loginctl enable-linger $USER. Читает
#   /etc/os-release, /proc/meminfo, группы юзера, свой ulimit -Hl,
#   loginctl-свойство Linger. В stdout — log-строки, в stderr — warn().
#   .env и файлы стека не трогает.
#
# Ограничения/допущения: запуск от root — die. Требуются глобалы MEMLOCK
#   (диспетчер) и log/warn/die. Локалы: id — $ID из os-release (ubuntu и
#   debian проходят, прочее die, затеняет утилиту id), mem_kb — MemTotal в
#   КиБ (порог 57671680 КиБ ≈ 58 GB decimal, в тексте предупреждения
#   назван ~58 GiB), lim — фиксированный путь limits.d-файла. Два
#   намеренных exit 42 — группа render ещё не действует и limits.d только
#   что записан при низком memlock текущей сессии — завершают процесс
#   диспетчера с требованием повторить install после перезахода/ребута;
#   прочие отказы — die (exit 1). Живые вызовы — cmd_install и cmd_use
#   (commands.sh) до любых изменений системы.
#
# @returns integer # всегда 0 при возврате — exit 42 (перезаход/ребут) и
#   die (exit 1) завершают процесс, не возвращаясь вызывающему
preflight() {
  [ "$(id -u)" != 0 ] || die "не запускай от root — работай от своего имени (sudo hfctl не нужен)"
  local id
  id=$(. /etc/os-release && echo "$ID")
  case "$id" in ubuntu|debian) ;; *) die "дистрибутив '$id' не поддерживается (нужен Ubuntu/Debian)" ;; esac
  [ -e /dev/kfd ] || die "/dev/kfd нет: AMD GPU не виден (проверь драйвер amdgpu)"
  local mem_kb; mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  [ "$mem_kb" -ge 57671680 ] || warn "RAM ${mem_kb}kB < ~58 GiB: 27B@262K может не влезть (нужна Halo 60 GiB+)"
  if ! command -v podman >/dev/null || ! command -v podman-compose >/dev/null; then
    log "установка podman + podman-compose (sudo точечно)"
    sudo apt-get update -qq && sudo apt-get install -y -qq podman podman-compose
  fi
  command -v curl >/dev/null || sudo apt-get install -y -qq curl
  # группа render для /dev/kfd rootless
  if ! id -nG | grep -qw render; then
    log "добавляю $USER в группу render (sudo точечно)"
    sudo usermod -aG render "$USER"
    warn "группа применится только после перезахода. Выйди и зайди снова, затем повтори install."
    exit 42
  fi
  # memlock для NPU-trunk (limits.d; требует ребута/пересоздания сессий)
  local lim="/etc/security/limits.d/99-hipfire-memlock.conf"
  if [ ! -f "$lim" ]; then
    log "пишу $lim (memlock $MEMLOCK)"
    echo "$USER soft memlock $MEMLOCK" | sudo tee "$lim" >/dev/null
    echo "$USER hard memlock $MEMLOCK" | sudo tee -a "$lim" >/dev/null
    if [ "$(ulimit -Hl)" != "unlimited" ] && [ "$(ulimit -Hl)" -lt "$MEMLOCK" ]; then
      warn "текущая сессия ещё с memlock=$(ulimit -Hl). Требуется ребут (или перезаход+сервис-менеджер). Повтори install после ребута."
      exit 42
    fi
  fi
  # linger: сервер должен жить без активного логина и при boot
  if [ "$(loginctl show-user "$USER" --property=Linger 2>/dev/null | cut -d= -f2)" != "yes" ]; then
    log "включаю linger для $USER (сервер переживает logout и стартует при boot)"
    sudo loginctl enable-linger "$USER"
  fi
}
