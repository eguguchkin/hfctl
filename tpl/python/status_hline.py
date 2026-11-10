import json, sys
d = json.load(sys.stdin)
c = d.get("capabilities", {})
st = "ok" if d.get("status") == "ok" and not d.get("loading_model") else ("загрузка: " + str(d.get("loading_model")) if d.get("loading_model") else d.get("status", "?"))
extra = (" | слоты: " + str(c.get("multi_slot_slots"))) if c.get("mode") == "multi-slot" else ""
print("health:", st, "| модель:", d.get("model"), "| режим:", c.get("mode") + extra)
