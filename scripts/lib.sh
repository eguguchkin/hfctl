# hfbox: общий слой для скриптов — цель, ключ, ssh-хелперы.
# Переопределяется переменными окружения: HF_HOST / HF_KEY / HF_STACK.

HF_HOST=${HF_HOST:-hipfire@192.168.1.254}
HF_KEY=${HF_KEY:-$HOME/.ssh/strix_halo_key}
# Директория стека на УДАЛЁННОМ хосте (используется скриптами, которые
# подставляют её в удалённые heredoc'и — там она видна как $HOME-относный путь).
HF_STACK=${HF_STACK:-"hipfire"}

hfssh() {
  ssh -i "$HF_KEY" -o BatchMode=yes -o ConnectTimeout=10 "$HF_HOST" "$@"
}

# hfssh_run <local-script-file> [args...] — исполнить файл как bash -s на хосте.
# Дополнительные пробрасываемые переменные: HF_DFLASH_DRAFT (выбор DFlash
# draft'а в compose.local.yml) — пустое/unset на хосте = дефолт скрипта.
hfssh_run() {
  local script="$1"; shift
  local extra=()
  [ -n "${HF_DFLASH_DRAFT:-}" ] && extra+=(HF_DFLASH_DRAFT="$HF_DFLASH_DRAFT")
  [ -n "${HF_ARMS:-}" ] && extra+=(HF_ARMS="$HF_ARMS")
  ssh -i "$HF_KEY" -o BatchMode=yes -o ConnectTimeout=10 "$HF_HOST" \
    env HF_STACK="$HF_STACK" "${extra[@]}" bash -s -- "$@" < "$script"
}

hf_die() { echo "hfbox: ERROR: $*" >&2; exit 1; }

hf_have() { command -v "$1" >/dev/null 2>&1; }

hf_require_ssh() {
  [ -f "$HF_KEY" ] || hf_die "SSH-ключ не найден: $HF_KEY (HF_KEY=path)"
  hfssh 'true' || hf_die "нет SSH-доступа к $HF_HOST (ключ $HF_KEY)"
}
