#!/bin/bash
# hfctl (remote): bench AR vs DFlash (каждая рука ×3 прогона) + md5 бинариов.
# Фикстура prompt: /prompts/merge_sort_thinking_off.txt (маунт compose.local.yml),
# bare-режим bench: --prompt-file --backend noslots --workload stateless.
# JSON-артефакты: ~/bench-runs/<arm>_<i>.json; итоговая сводка в stdout.
set -euo pipefail
STACK="$HF_STACK"
cd "$HOME/$STACK"
F="podman compose -f compose.yml -f compose.halo.yml -f compose.local.yml"
OUT="$HOME/bench-runs"
mkdir -p "$OUT"
PROMPT=${HF_PROMPT_FILE:-/prompts/merge_sort_thinking_off.txt}
MODEL=${HF_MODEL:-qwen3.8:27b-mq6-xt}
IMAGE=ghcr.io/warpfront/hipfire:0.4.5

echo "=== md5 binaries + prompt ==="
podman run --rm --entrypoint md5sum "$IMAGE" /usr/local/bin/hipfire /opt/hipfire/bin/daemon

$F stop hipfire >/dev/null 2>&1 || true
trap '$F start hipfire >/dev/null 2>&1 || true' EXIT

for arm in ${HF_ARMS:-off dflash}; do
  for i in 1 2 3; do
    $F run --rm --no-deps hipfire hipfire bench "$MODEL" --spec "$arm" \
      --runs 3 --warmups 1 --max-tokens 256 --backend noslots --workload stateless \
      --prompt-file "$PROMPT" --json \
      > "$OUT/${arm}_${i}.json" 2> "$OUT/${arm}_${i}.err"
    echo "== arm=$arm run=$i exit=$? =="
    python3 - "$OUT" "${arm}_${i}" <<'PY'
import json, re, sys
# hipfire печатает лог-баннер в stdout до JSON — вырезаем префикс
raw = open(f"{sys.argv[1]}/{sys.argv[2]}.json").read()
m = re.search(r"^\{", raw, re.M)
d, _ = json.JSONDecoder().raw_decode(raw[m.start():])
s = d.get("samples", {})
print("prompt_md5:", d.get("prompt_md5"),
      "| decode tok/s:", s.get("decode"),
      "| tau:", d.get("spec_tau"),
      "| prefill tok/s:", s.get("prefill"),
      "| ttft_ms:", s.get("ttft_ms"))
PY
  done
done
echo BENCH_ALL_DONE
