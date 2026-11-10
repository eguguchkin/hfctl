import json, sys, time, urllib.request

url, pfile = sys.argv[1], sys.argv[2]
payload = json.load(open(pfile, encoding="utf-8"))
req = urllib.request.Request(
    url, data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
    headers={"Content-Type": "application/json"})
t0 = time.perf_counter()
ttft = None
try:
    resp = urllib.request.urlopen(req, timeout=120)
except Exception as e:
    print("ERR", e)
    sys.exit(0)
try:
    for raw in resp:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:"):
            continue
        d = line[5:].strip()
        if d == "[DONE]":
            break
        try:
            obj = json.loads(d)
        except Exception:
            continue
        hit = False
        for ch in obj.get("choices") or []:
            if ((ch.get("delta") or {}).get("content") or "").strip():
                ttft = (time.perf_counter() - t0) * 1000.0
                hit = True
                break
        if hit:
            break
finally:
    try:
        resp.close()
    except Exception:
        pass
print("null" if ttft is None else "%.0f" % ttft)
