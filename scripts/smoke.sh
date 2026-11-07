#!/bin/bash
# hfbox: смоуксервера — 3 запроса (код/проза/математика) + health + логи.
set -euo pipefail
here="$(dirname "$0")"
source "$here/lib.sh"
hf_require_ssh
hfssh_run "$here/remote/_smoke.sh"
