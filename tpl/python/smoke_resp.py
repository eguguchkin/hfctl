import json, sys
d = json.load(sys.stdin)
c = d["choices"][0]["message"]["content"]
print("ответ:", (c or "")[:60].strip() or "(ПУСТО)")
sys.exit(0 if (c or "").strip() else 1)
