#!/bin/bash
# Build PhotoSearch for the iOS Simulator.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

echo "==> Building $TARGET ($CONFIGURATION) for \"$SIM_DEVICE\"..."

xcodebuild \
  -project "$PROJECT" \
  -scheme "$TARGET" \
  -configuration "$CONFIGURATION" \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=$SIM_DEVICE" \
  -derivedDataPath "$DERIVED_DATA" \
  build

echo "==> Build succeeded:"
echo "    $APP_PATH"
