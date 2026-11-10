# shellcheck shell=bash
# ── стек: обёртка compose, чтение .env, префлайт ────────────────────────────
CF=( -f compose.yml -f compose.halo.yml -f compose.local.yml )
compose() { ( cd "$STACK_DIR" && podman compose "${CF[@]}" "$@" ); }
env_val() { [ -f "$STACK_DIR/.env" ] && grep -E "^$1=" "$STACK_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2- || true; }
cur_profile() { local p; p=$(env_val HFCTL_PROFILE); echo "${p:-$PROFILE_DEFAULT}"; }
cur_model()   { env_val HIPFIRE_MODEL || echo "$(profile_field "$(cur_profile)" 1)"; }

# ── префлайт и хост-подготовка ──────────────────────────────────────────────
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
