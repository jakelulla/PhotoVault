#!/bin/bash
# Live indexing progress. Reads index/status.json (works whether or not the
# server is running). Ctrl-C to stop watching — it does NOT affect the build.
cd "$(dirname "${BASH_SOURCE[0]}")"

start_epoch=$(date +%s); start_done=""
while :; do
  read -r proc total done < <(
    ./venv/bin/python - <<'PY'
import json
try:
    s = json.load(open("index/status.json"))
    print(s.get("processed",0), s.get("total",0), s.get("done",False))
except Exception:
    print(0, 0, False)
PY
  )
  [ -z "$start_done" ] && start_done=$proc && start_epoch=$(date +%s)

  if [ "$done" = "True" ]; then
    printf "\r✅ index built: %s photos. Server should be coming up...           \n" "$proc"
    break
  fi
  if [ "${total:-0}" -gt 0 ]; then
    pct=$(( proc * 100 / total ))
    # rate + ETA from this watch session
    now=$(date +%s); elapsed=$(( now - start_epoch ))
    rate=0; eta="?"
    if [ "$elapsed" -gt 5 ] && [ "$proc" -gt "$start_done" ]; then
      rate=$(( (proc - start_done) / (elapsed>0?elapsed:1) ))
      [ "$rate" -gt 0 ] && eta=$(( (total - proc) / rate / 60 ))"m"
    fi
    printf "\r%5s%%  %6s / %-6s photos   (~%s/s, ETA %s)        " "$pct" "$proc" "$total" "$rate" "$eta"
  else
    printf "\rwaiting for indexer to start...        "
  fi
  sleep 5
done
