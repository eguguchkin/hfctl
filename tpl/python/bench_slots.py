import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
print(d.get("capabilities", {}).get("multi_slot_slots") or "")
