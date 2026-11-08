#!/bin/bash
# hfctl: батарея конкурентности (solo/parallel/short-behind-long) на цели.
# Перед запуском зафиксируй, в каком режиме сервер — вывод помечай сам.
set -euo pipefail
here="$(dirname "$0")"
source "$here/lib.sh"
hf_require_ssh
hfssh_run "$here/remote/_conc_bench.sh"
