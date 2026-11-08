#!/bin/bash
# hfctl: параллельный API-тест на цели. Использование: scripts/par_test.sh [N=4]
set -euo pipefail
here="$(dirname "$0")"
source "$here/lib.sh"
hf_require_ssh
hfssh_run "$here/remote/_par_test.sh" "${1:-4}"
