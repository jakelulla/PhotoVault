#!/bin/bash
# Shared configuration for build.sh / run.sh / go.sh
# Override the simulator with:  SIM_DEVICE="iPhone 17" ./go.sh

# Directory this repo lives in (works regardless of where the script is called from)
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_DIR="$ROOT_DIR/PhotoSearch"
PROJECT="$PROJECT_DIR/PhotoSearch.xcodeproj"
TARGET="PhotoSearch"
CONFIGURATION="Debug"
BUNDLE_ID="com.jakelulla.PhotoSearch"

# Simulator to use (override via SIM_DEVICE env var)
SIM_DEVICE="${SIM_DEVICE:-iPhone 17 Pro}"

# Build output goes here so run.sh can find the .app
DERIVED_DATA="$PROJECT_DIR/build"
APP_PATH="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphonesimulator/${TARGET}.app"
