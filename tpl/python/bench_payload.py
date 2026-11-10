import json, sys
out, cfile, mt, stream = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] == "1"
d = {"model": sys.argv[5], "messages": [{"role": "user", "content": open(cfile, encoding="utf-8").read()}],
     "max_tokens": mt, "temperature": 0, "reasoning_effort": "none"}
if stream:
    d["stream"] = True
json.dump(d, open(out, "w", encoding="utf-8"), ensure_ascii=False)
