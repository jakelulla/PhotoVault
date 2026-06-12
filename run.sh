#!/bin/bash
# Boot the simulator, install the built app, and launch it.
# Run build.sh first (or use go.sh to do both).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

if [ ! -d "$APP_PATH" ]; then
  echo "error: app not found at $APP_PATH" >&2
  echo "       run ./build.sh first." >&2
  exit 1
fi

echo "==> Opening Simulator..."
open -a Simulator

echo "==> Booting \"$SIM_DEVICE\"..."
xcrun simctl boot "$SIM_DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_DEVICE"

echo "==> Installing app..."
xcrun simctl install "$SIM_DEVICE" "$APP_PATH"

echo "==> Launching $BUNDLE_ID..."
xcrun simctl launch "$SIM_DEVICE" "$BUNDLE_ID"

echo "==> Done. The app is running in the Simulator."
