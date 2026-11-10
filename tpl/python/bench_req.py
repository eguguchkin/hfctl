import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(3)
u = d.get("usage") or {}
ct, pt = u.get("completion_tokens"), u.get("prompt_tokens")
if ct is None:
    sys.exit(4)
w = sys.stdin.read().strip()
print("%s %s %s" % (w, 0 if pt is None else pt, ct))
