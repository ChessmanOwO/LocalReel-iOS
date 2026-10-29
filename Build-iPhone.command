#!/bin/zsh
set -eu
localreel_root="$(cd "$(dirname "$0")" && pwd)"
localreel_build="$(mktemp -d /private/tmp/LocalReelOnDevice.XXXXXX)"
localreel_device="${1:?Usage: ./Build-iPhone.command device-name-or-identifier}"
cd "$localreel_root"
xcodebuild -project LocalReel.xcodeproj -target LocalReel -sdk iphoneos -configuration Debug \
  SYMROOT="$localreel_build" OBJROOT="$localreel_build/Intermediates" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
localreel_app="$localreel_build/Debug-iphoneos/LocalReel.app"
localreel_bundle="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$localreel_app/Info.plist")"
xcrun devicectl device install app --device "$localreel_device" "$localreel_app"
xcrun devicectl device process launch --device "$localreel_device" "$localreel_bundle"
