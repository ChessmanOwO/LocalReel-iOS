#!/bin/sh
# Compile on Mac; successful build does not prove live device downloads.
set -eu
cd "$(dirname "$0")"
xcodebuild -project LocalReel.xcodeproj -scheme LocalReel \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
