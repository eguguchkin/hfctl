#!/usr/bin/env bash
# EXP-002 — plain-стрим hfctl watch в пайпе на живой машине (DoD 6, 10)
#
# Цель: доказать, что `hfctl watch --interval 2 | tee f` на живом сервере
#   даёт строку БЕСУСЛОВНО раз в ~2 c (по timestamp'ам, ±0.5 c), каждая —
#   полный срез (очередь/обслужено/кэш/prefill/decode/mem/swap/gpu/cpu).
#
# Prerequisites (проверяются скриптом): запуск НА целевой машине;
#   hfctl (PATH или ~/hipfire/hfctl), python3; контейнер hipfire_hipfire_1
#   running; /stats на :$PORT отвечает.
#
# Команда запуска:
#   ssh -t <host> 'bash -s' < flow/external/EXP-002-plain-pipe.sh
#
# Что есть PASS: ≥5 строк за ~12 c; Δ между последовательными HH:MM:SS ∈
#   [1.5; 2.5] c; каждая строка содержит поля queue/served/cache/prefill/
#   decode/mem/swap/gpu/cpu. Вывод + файл стрима — в
#   EXP-002-plain-pipe.result.txt.
set -uo pipefail
cd "$(dirname "$0")"
RES="EXP-002-plain-pipe.result.txt"
: > "$RES"
say() { printf '%s\n' "$*" | tee -a "$RES"; }
fail() { say "RESULT: BLOCKED — $*"; exit 2; }

HFCTL_BIN="$(command -v hfctl || echo "$HOME/hipfire/hfctl")"
[ -x "$HFCTL_BIN" ] || fail "hfctl не найден"
command -v python3 >/dev/null || fail "python3 не найден"
command -v podman >/dev/null || fail "podman не найден"
ENVCFG="$HOME/hipfire/.env"
PORT="$(sed -n 's/^HIPFIRE_PORT=//p' "$ENVCFG" 2>/dev/null | head -n1)"
PORT="${PORT:-11435}"
CONTAINER="${HFCTL_EXP_CONTAINER:-hipfire_hipfire_1}"
podman ps --format '{{.Names}}' | grep -qx "$CONTAINER" || fail "контейнер $CONTAINER не running"
curl -fsS -m 5 "http://127.0.0.1:$PORT/stats" >/dev/null 2>&1 || fail "/stats на :$PORT не отвечает"

OUT="$RES.stream.txt"
say "запуск: hfctl watch --interval 2 | tee (12 c, живой сервер :$PORT)"
HFCTL_PORT="$PORT" timeout 12 "$HFCTL_BIN" watch --interval 2 | tee "$OUT" >>"$RES" 2>&1
say "--- конец стрима ---"

python3 - "$OUT" >>"$RES" 2>&1 <<'PYEOF' || true
import re, sys
lines = [l for l in open(sys.argv[1]) if re.match(r'^\d\d:\d\d:\d\d ', l)]
fails = []
def ts(s):
    h, m, sec = map(int, s[:8].split(':'))
    return h * 3600 + m * 60 + sec
times = [ts(l) for l in lines]
if len(lines) < 5:
    fails.append('мало строк: %d (ожидалось >=5 за 12 c)' % len(lines))
deltas = [b - a for a, b in zip(times, times[1:])]
bad = [d for d in deltas if not (1.5 <= d <= 2.5)]
if bad:
    fails.append('Δ вне [1.5;2.5] c: %s' % bad)
need = ('queue:', 'served:', 'cache:', 'prefill:', 'decode:', 'mem:', 'swap:', 'gpu:', 'cpu:')
for l in lines:
    missing = [k for k in need if k not in l]
    if missing:
        fails.append('строка без полей %s: %s' % (missing, l[:80]))
        break
if fails:
    print('АНАЛИЗ: FAIL — ' + '; '.join(fails))
else:
    print('АНАЛИЗ: %d строк, Δ=%s c, все поля присутствуют' % (len(lines), deltas))
PYEOF

if grep -q '^АНАЛИЗ:' "$RES" && ! grep -q '^АНАЛИЗ: FAIL' "$RES"; then
  say "RESULT: PASS — plain-стрим: интервалы ~2 c, полный срез в каждой строке"
elif grep -q '^АНАЛИЗ: FAIL' "$RES"; then
  say "RESULT: FAIL — см. АНАЛИЗ в $RES"
else
  say "RESULT: ERROR — анализ не выполнен"
fi
