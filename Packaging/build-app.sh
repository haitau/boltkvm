#!/bin/bash
# Assembles dist/BoltKVM.app from the SwiftPM build. No Xcode project: the
# bundle is just Info.plist + a Mach-O + (optionally) an icon.
#
# Signing identity: BOLTKVM_CODESIGN_IDENTITY, default "-" (ad-hoc). Ad-hoc
# signing changes the cdhash on every build, which makes macOS treat the app as
# new for TCC — grant Screen Recording once per build, or sign with a stable
# self-signed certificate ("BoltKVM Local") and keep the permission.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${BOLTKVM_CODESIGN_IDENTITY:--}"
APP="dist/BoltKVM.app"

echo "==> swift build -c release --product BoltKVMApp"
swift build -c release --product BoltKVMApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BoltKVMApp "$APP/Contents/MacOS/BoltKVM"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
if [ -f Packaging/AppIcon.icns ]; then
  cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Hardened runtime keeps Gatekeeper happy if this ever ships; --options runtime
# is harmless for local ad-hoc builds too.
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

echo "==> $APP"
echo "    $(codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Authority|Signature' | tr '\n' ' ')"
