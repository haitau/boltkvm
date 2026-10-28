#!/bin/bash
# Build the release app and install it into /Applications (local machine).
#
#   ./scripts/install-app.sh              # build, install, launch
#   ./scripts/install-app.sh --no-build   # install the existing dist bundle
#   BOLTKVM_NO_LAUNCH=1 ./scripts/install-app.sh
#
# The previous bundle is kept as /Applications/BoltKVM.app.bak so a bad build
# can be rolled back. Quit BoltKVM before running this; the script also asks the
# app to quit and waits for its capture helper.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="/Applications/BoltKVM.app"
BACKUP="/Applications/BoltKVM.app.bak"
APP="dist/BoltKVM.app"
DO_BUILD=1

for arg in "$@"; do
  case "$arg" in
    --no-build) DO_BUILD=0 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [ "$DO_BUILD" = 1 ]; then
  ./Packaging/build-app.sh
fi

test -d "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
codesign --verify --deep --strict "$APP"

if [ ! -w /Applications ]; then
  echo "无法写入 /Applications；请用管理员账户运行，或用 sudo 执行本脚本。" >&2
  exit 1
fi

quit_app() {
  # Do not use `pkill -f <path>` here: the pattern also matches this script's
  # own command line. Match the exact executable names instead.
  osascript -e 'if application id "io.github.boltkvm" is running then tell application id "io.github.boltkvm" to quit' >/dev/null 2>&1 || true
  sleep 2
  local pid
  for pid in $(pgrep -x BoltKVM 2>/dev/null || true); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in $(pgrep -x boltkvm-server 2>/dev/null || true); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
}

quit_app

STAGE=$(mktemp -d /Applications/.boltkvm-install.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/BoltKVM.app"
codesign --verify --deep --strict "$STAGE/BoltKVM.app"

if [ -e "$DEST" ]; then
  rm -rf "$BACKUP"
  mv "$DEST" "$BACKUP"
fi
if ! mv "$STAGE/BoltKVM.app" "$DEST"; then
  if [ -e "$BACKUP" ]; then mv "$BACKUP" "$DEST"; fi
  echo "安装失败，已尝试恢复旧版本。" >&2
  exit 1
fi
codesign --verify --deep --strict "$DEST"

CODESIGN_INFO=$(codesign -dv --verbose=4 "$DEST" 2>&1 || true)
AUTH=$(printf '%s\n' "$CODESIGN_INFO" | awk -F= '/Authority=/{print $2; exit}')
echo "已安装 $DEST"
echo "版本 $VERSION ($BUILD)，签名 ${AUTH:-ad-hoc}"
if [ -e "$BACKUP" ]; then echo "旧版本保留在 $BACKUP"; fi

if [ "${BOLTKVM_NO_LAUNCH:-0}" != "1" ]; then
  open -a "$DEST"
  cat <<'MSG'
已启动 /Applications/BoltKVM.app。
如果这是新签名第一次运行，macOS 会要求重新授权：
  - 被控端：屏幕录制、辅助功能
  - 主控端：本地网络（macOS 15+）
授权后重开应用即可。
MSG
fi
