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

echo "==> swift build -c release"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BoltKVMApp "$APP/Contents/MacOS/BoltKVM"
# The capture loop runs as this CLI: a GUI process cannot reliably create a
# CGVirtualDisplay, a plain binary can (same reason vdscreen ships a helper).
cp .build/release/boltkvm "$APP/Contents/MacOS/boltkvm-server"   # not "boltkvm": APFS is case-insensitive and would overwrite BoltKVM
cp Packaging/Info.plist "$APP/Contents/Info.plist"

# Stamp the bundle so Finder -> Get Info always answers "which build is this".
# CI passes BOLTKVM_VERSION (tag) and BOLTKVM_BUILD (run number); a local build
# falls back to git describe, which keeps the exact tag/commit and adds
# "-dirty" when the working tree has uncommitted edits.
DEFAULT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DEFAULT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
VERSION="${BOLTKVM_VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo "$DEFAULT_VERSION")}"
VERSION="${VERSION#v}"
BUILD="${BOLTKVM_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo "$DEFAULT_BUILD")}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
echo "==> version $VERSION ($BUILD)"

if [ -f Packaging/AppIcon.icns ]; then
  cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# Localization tables: macOS picks the .lproj by the user's preferred languages
# and falls back to CFBundleDevelopmentRegion (en).
for lproj in Packaging/Resources/*.lproj; do
  [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done

# Hardened runtime is only needed for notarization, and it appears to break
# CGVirtualDisplay creation inside a GUI bundle (measured 2026-10-22: the same
# code creates the display fine as a CLI binary, refuses under hardened runtime).
# Opt in with BOLTKVM_HARDENED_RUNTIME=1 when shipping.
RUNTIME_FLAG=""
if [ "${BOLTKVM_HARDENED_RUNTIME:-0}" = "1" ]; then
  RUNTIME_FLAG="--options runtime"
fi
# Sign the nested helper first, then the bundle that contains it.
codesign --force --timestamp=none --sign "$IDENTITY" "$APP/Contents/MacOS/boltkvm-server" >/dev/null
codesign --force $RUNTIME_FLAG --timestamp=none --sign "$IDENTITY" "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

echo "==> $APP"
echo "    $(codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Authority|Signature' | tr '\n' ' ')"
