#!/bin/bash
# hfctl: bench AR vs DFlash на цели (3 прогона каждая рука, JSON в ~/bench-runs).
# Во время bench контейнер serve стопается и поднимается обратно в конце.
set -euo pipefail
here="$(dirname "$0")"
source "$here/lib.sh"
hf_require_ssh
hfssh_run "$here/remote/_bench_arms.sh"
