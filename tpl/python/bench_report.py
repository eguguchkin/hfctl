import json, os, re, statistics, sys

def _f(x):
    x = (x or "").strip()
    return None if x in ("", "-") else float(x)

def _n(x):
    v = _f(x)
    if v is None:
        return None
    return int(v) if float(v).is_integer() else v

def load_runs():
    runs = {}
    for line in open(os.environ["B_RUNS"], encoding="utf-8"):
        p = line.rstrip("\n").split("\t")
        if len(p) < 6 or not p[0]:
            continue
        e = {"wall": _f(p[1]), "tokens": _n(p[2]), "tok_s": _f(p[3]),
             "tau": _f(p[4]), "ttft_ms": _f(p[5])}
        if len(p) > 6 and p[6] not in ("", "-"):  # колонка 7 — additive (parallel-N)
            e["walls"] = [float(x) for x in p[6].split(",")]
        runs.setdefault(p[0], []).append(e)
    return runs

ORDER = ["solo-code", "solo-prose", "ttft", "prefill-100k", "long-gen",
         "parallel-2", "parallel-4", "hol", "ar-baseline"]
UNITS = {"ttft": "мс", "hol": "с", "prefill-100k": "tok/s",
         "parallel-2": "tok/s agg", "parallel-4": "tok/s agg"}
RE_PAR = re.compile(r"^parallel-\d+$")

def scen_order(keys):
    """Порядок сценариев: известные из ORDER + любые parallel-<N> после них
    по возрастанию N (динамический --parallel)."""
    return list(ORDER) + sorted((k for k in keys if RE_PAR.match(k) and k not in ORDER),
                                key=lambda k: int(k.split("-")[1]))

def unit_of(sc):
    return "tok/s agg" if RE_PAR.match(sc) else UNITS.get(sc, "tok/s")
# главная метрика сценария (для сводки и сравнения): tok_s у скоростных,
# ttft у отзывчивости, wall у HOL
MAIN = {"ttft": ("ttft_ms", "мс"), "hol": ("wall", "с")}

def main_vals(sc, rs):
    key, unit = MAIN.get(sc, ("tok_s", unit_of(sc)))
    return unit, [e.get(key) for e in rs if e.get(key) is not None]

def summary_of(runs):
    sm = {}
    for sc in scen_order(runs):
        rs = runs.get(sc) or []
        if not rs:
            continue
        unit, vals = main_vals(sc, rs)
        if not vals:
            continue
        sm[sc] = {"median": round(statistics.median(vals), 3),
                  "min": round(min(vals), 3), "max": round(max(vals), 3),
                  "unit": unit}
    if os.environ.get("B_FULL") == "1":
        sm["ar-baseline"] = {"unit": "—", "median": None, "min": None, "max": None,
                             "note": "пропущен (сравнение спекуляция/нет — через use разных профилей)"}
    return sm

def fmt_med(vals, unit, sc, nd=2):
    med = statistics.median(vals)
    s = "%g %s" % (round(med, nd), unit)
    if len(vals) > 1:
        s += " (%g–%g)" % (round(min(vals), nd), round(max(vals), nd))
        if med:
            sp = (max(vals) - min(vals)) / med * 100.0
            if sp > 5:
                print("WARN: %s: разброс прогонов %.0f%% > 5%% — система занята?" % (sc, sp),
                      file=sys.stderr)
    return s

def do_report(runs):
    print()
    print("%-18s %-30s %-9s %-18s %s" % ("сценарий", "decode", "τ", "TTFT", "примечание"))
    for sc in scen_order(runs):
        rs = runs.get(sc) or []
        if not rs:
            continue
        dec = ttft = tau = "—"
        if sc == "ttft":
            vals = [e["ttft_ms"] for e in rs if e.get("ttft_ms") is not None]
            if vals:
                ttft = fmt_med(vals, "мс", sc)
        elif sc == "hol":
            vals = [e["wall"] for e in rs if e.get("wall") is not None]
            if vals:
                ttft = fmt_med(vals, "с", sc) + " (короткий)"
        elif sc != "ar-baseline":
            vals = [e["tok_s"] for e in rs if e.get("tok_s") is not None]
            if vals:
                dec = fmt_med(vals, unit_of(sc), sc)
        taus = [e["tau"] for e in rs if e.get("tau") is not None]
        if taus:
            tau = "%.2f" % statistics.median(taus)
        print("%-18s %-30s %-9s %-18s %s" % (
            "%s (×%d)" % (sc, len(rs)), dec, tau, ttft,
            os.environ.get("B_NOTE_" + sc.replace("-", "_"), "")))
    print()

def do_artifact(runs):
    print(json.dumps({
        "timestamp": os.environ["B_TS"],
        "profile": os.environ["B_PROFILE"],
        "model": os.environ["B_MODEL"],
        "route": os.environ["B_ROUTE"],
        "image": os.environ["B_IMAGE"],
        "fixture_md5": os.environ["B_MD5"],
        "hfctl_version_placeholder": "",
        "runs": runs,
        "summary": summary_of(runs),
    }, ensure_ascii=False, indent=1))

def do_compare(basefile):
    base = json.load(open(basefile, encoding="utf-8"))
    cur = json.loads(os.environ["B_ARTIFACT"])
    bsm, csm = base.get("summary") or {}, cur.get("summary") or {}
    print("сравнение с прошлым прогоном (%s):" % os.path.basename(basefile))
    n = 0
    for sc in scen_order(set(csm) | set(bsm)):
        c, b = csm.get(sc) or {}, bsm.get(sc) or {}
        cm, bm = c.get("median"), b.get("median")
        if cm is None or bm is None or not bm:
            continue
        d = (cm - bm) / bm * 100.0
        unit = c.get("unit") or b.get("unit") or ""
        verdict = ""
        if abs(d) >= 1.0:
            good = (d > 0) == ("tok/s" in unit)
            verdict = " — " + ("лучше" if good else "хуже")
        print("  %s: %+.1f%% (%g → %g %s)%s" % (sc, d, bm, cm, unit, verdict))
        n += 1
    if not n:
        print("  общих сценариев с цифрами нет")

cmd = sys.argv[1] if len(sys.argv) > 1 else ""
runs = load_runs()
if cmd == "report":
    do_report(runs)
elif cmd == "artifact":
    do_artifact(runs)
elif cmd == "compare":
    do_compare(sys.argv[2])
