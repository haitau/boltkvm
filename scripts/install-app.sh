#!/bin/bash
# Build the release app and install it into /Applications (local machine).
#
#   ./scripts/install-app.sh                    # build, install, launch
#   ./scripts/install-app.sh --no-build         # install the existing dist bundle
#   ./scripts/install-app.sh --reset-permissions # also clear old TCC entries
#   BOLTKVM_NO_LAUNCH=1 ./scripts/install-app.sh
#
# The previous bundle is staged inside a hidden temporary directory under
# /Applications only for the duration of the swap. It is restored on failure and
# deleted on success; this script does not leave a .bak bundle behind.
#
# Quit BoltKVM before running this; the script also asks the app to quit and
# waits for its capture helper.
#
# If the signing requirement changes (for example an old ad-hoc build is
# replaced by a stable-certificate build), the old Screen Recording and
# Accessibility TCC rows no longer match the new app: System Settings can show
# the switches ON while preflight still returns false. The script compares the
# designated requirements and resets only those two entries when they differ.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="/Applications/BoltKVM.app"
APP="dist/BoltKVM.app"
DO_BUILD=1
FORCE_RESET=0

for arg in "$@"; do
  case "$arg" in
    --no-build) DO_BUILD=0 ;;
    --reset-permissions) FORCE_RESET=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
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

# TCC stores a code requirement with each grant. Read the old and new
# requirements before replacing the bundle so an identity change can be
# detected; stable-certificate rebuilds have the same requirement and keep
# their grants, while ad-hoc -> stable transitions get a clean slate.
OLD_REQ=""
if [ -d "$DEST" ]; then
  OLD_REQ=$(codesign -d -r- "$DEST" 2>&1 | sed -n '/^designated/p' || true)
fi
NEW_REQ=$(codesign -d -r- "$APP" 2>&1 | sed -n '/^designated/p' || true)
NEED_RESET=0
if [ "$FORCE_RESET" = 1 ] || [ -z "$OLD_REQ" ] || [ "$OLD_REQ" != "$NEW_REQ" ]; then
  NEED_RESET=1
fi

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
  mv "$DEST" "$STAGE/old.app"
fi
if ! mv "$STAGE/BoltKVM.app" "$DEST"; then
  if [ -e "$STAGE/old.app" ]; then mv "$STAGE/old.app" "$DEST"; fi
  echo "安装失败，已尝试恢复旧版本。" >&2
  exit 1
fi
if ! codesign --verify --deep --strict "$DEST"; then
  rm -rf "$DEST"
  if [ -e "$STAGE/old.app" ]; then mv "$STAGE/old.app" "$DEST"; fi
  echo "签名校验失败，已恢复旧版本。" >&2
  exit 1
fi

if [ "$NEED_RESET" = 1 ]; then
  # Same effect as the user running these two commands manually. Do it after the
  # old app is stopped and before launch so the first check sees a clean slate.
  for service in ScreenCapture Accessibility; do
    /usr/bin/tccutil reset "$service" io.github.boltkvm >/dev/null 2>&1 || true
  done
  if [ "$FORCE_RESET" = 1 ] && [ -n "$OLD_REQ" ] && [ "$OLD_REQ" = "$NEW_REQ" ]; then
    echo "已按 --reset-permissions 清除旧 TCC 条目；请重新授予屏幕录制与辅助功能。"
  else
    echo "签名/权限身份已变化，已清除旧 TCC 条目；首次启动请重新授予屏幕录制与辅助功能。"
  fi
else
  echo "签名身份未变，保留现有 TCC 授权。"
fi

CODESIGN_INFO=$(codesign -dv --verbose=4 "$DEST" 2>&1 || true)
AUTH=$(printf '%s\n' "$CODESIGN_INFO" | awk -F= '/Authority=/{print $2; exit}')
echo "已安装 $DEST"
echo "版本 $VERSION ($BUILD)，签名 ${AUTH:-ad-hoc}"

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
