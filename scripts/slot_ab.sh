#!/bin/bash
# hfctl: A/B «параллель vs сериал» (только для multi-slot экспериментов).
set -euo pipefail
here="$(dirname "$0")"
source "$here/lib.sh"
hf_require_ssh
hfssh_run "$here/remote/_slot_ab.sh"
