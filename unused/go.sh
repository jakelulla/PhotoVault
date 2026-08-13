#!/bin/bash
# Build and run PhotoSearch in one step.
# Also starts the backend API in the background if it isn't already up.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

API_URL="http://127.0.0.1:8000/"

if ! curl -fsS "$API_URL" >/dev/null 2>&1; then
  echo "==> Backend not running — starting it in the background..."
  ( cd "$DIR/backend" && nohup ./serve.sh >/tmp/photosearch_backend.log 2>&1 & )
  printf "==> Waiting for backend"
  for _ in $(seq 1 30); do
    if curl -fsS "$API_URL" >/dev/null 2>&1; then echo " — up."; break; fi
    printf "."; sleep 1
  done
  if ! curl -fsS "$API_URL" >/dev/null 2>&1; then
    echo
    echo "error: backend didn't come up. See /tmp/photosearch_backend.log" >&2
    echo "       (did you build the index? cd backend && ./index.sh)" >&2
    exit 1
  fi
else
  echo "==> Backend already running."
fi

"$DIR/build.sh"
"$DIR/run.sh"
