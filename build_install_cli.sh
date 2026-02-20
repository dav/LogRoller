#!/bin/bash
set -euo pipefail

xcodebuild \
  -project ./LogRoller.xcodeproj \
  -scheme logroller \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
BIN_DIR=$(xcodebuild -project /Users/dav/code/LogRoller/LogRoller.xcodeproj -scheme logroller -configuration Debug -showBuildSettings | awk -F' = ' '/TARGET_BUILD_DIR/ {print $2; exit}')
mkdir -p "$HOME/bin"
cp "$BIN_DIR/logroller" "$HOME/bin/logroller"
