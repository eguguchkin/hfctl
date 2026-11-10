import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(3)
u = d.get("usage") or {}
ct = u.get("completion_tokens")
print("" if ct is None else ct)
