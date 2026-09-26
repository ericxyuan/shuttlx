#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo "Checking selected Apple toolchain"
xcodebuild -version
major="$(xcodebuild -version | awk '/Xcode/ {print $2}' | cut -d. -f1)"
if [[ "$major" -lt 26 ]]; then
  echo "Select Xcode 26 or newer before building native Liquid Glass APIs." >&2
  exit 1
fi
swift test --package-path Packages/ShuttlXCore
python3 scripts/prepare_transport_tests.py
swift test --package-path .build/TransportChecks
xcodebuild -project ShuttlX.xcodeproj -scheme ShuttlX \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/apple CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ShuttlX.xcodeproj -scheme ShuttlXWatch \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath .build/watch CODE_SIGNING_ALLOWED=NO build
echo "Package tests and both simulator builds passed. Device and visual validation are separate."
