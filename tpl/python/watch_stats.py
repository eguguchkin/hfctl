import json, sys
try: d = json.loads(sys.stdin.read())
except Exception: d = {}
v = lambda k: "-" if d.get(k) is None else d.get(k)
print(v("queue_depth"), v("requests_served"), v("recent_tok_s"), v("retries_attempted"))
