#!/bin/bash
# hfctl: ждать, пока hipfire на цели станет healthy (loading_model == null).
# Использование: scripts/wait_health.sh [таймаут_сек=300]
set -euo pipefail
here="$(dirname "$0")"
source "$here/lib.sh"
hf_require_ssh
hfssh_run "$here/remote/_wait_health.sh" "${1:-300}"
