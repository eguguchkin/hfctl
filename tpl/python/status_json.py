import json, sys, os
try: h = json.loads(sys.stdin.read())
except Exception: h = None
print(json.dumps({
  "profile": os.environ["PROFILE"],
  "autostart": os.environ["AUTO"] == "enabled",
  "watchdog": os.environ["WDOG"] == "enabled",
  "health": h,
}, ensure_ascii=False))
