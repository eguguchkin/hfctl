import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if d.get("status") == "ok" and d.get("model") and not d.get("loading_model") else 1)
