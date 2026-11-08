#!/bin/bash
# hfctl: разовая подготовка удалённого хоста (чистая машина).
# Точечный sudo: apt-пакеты, группа render, limits.d memlock, linger, unit.
# Всё идемпотентно — можно запускать повторно.
set -euo pipefail
here="$(dirname "$0")"
source "$here/lib.sh"
hf_require_ssh
hfssh_run "$here/remote/_host_prep.sh"
