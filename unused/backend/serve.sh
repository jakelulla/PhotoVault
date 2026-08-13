#!/bin/bash
# Start the PhotoSearch backend API (http://127.0.0.1:8000).
# Starts even with no index — the app can upload photos and /api/reindex to build one.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [ ! -f index/photos.json ]; then
  echo "note: no index yet — starting blank. Add photos (app or test_images) and reindex."
fi

PORT="${PORT:-8000}"
echo "==> PhotoSearch API on http://127.0.0.1:$PORT  (Ctrl-C to stop)"
# Wrap in caffeinate so the Mac never idle/disk-sleeps while the server (and the
# build_index child it spawns) are running — sleep mid-index was killing the
# build and leaving a stale lock. caffeinate exits when uvicorn does.
#   -i no idle sleep   -s no sleep on AC power   -m no disk sleep
exec caffeinate -ism ./venv/bin/uvicorn server:app --host 0.0.0.0 --port "$PORT"
