#!/bin/bash
# hfbox: прод .env + compose.local.yml + one-shot прод-конфиг в volume.
# Работает и на чистой машине (стек может быть ещё не поднят — volume-конфиг
# подхватится при первом up -d). Идемпотентен.
set -euo pipefail
here="$(dirname "$0")"
source "$here/lib.sh"
hf_require_ssh
hfssh_run "$here/remote/_config_prod.sh"
