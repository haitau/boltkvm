#!/bin/bash
# Switches the controlled machine from the CLI supervisor (~/soak-start.sh) to
# BoltKVM.app in server role: builds, installs to /Applications, stops the CLI
# loop, starts the app.
#
#   scripts/deploy-app.sh <被控端地址>
#
# Precondition: BoltKVM.app must have Screen Recording permission on the target.
# TCC cannot be granted by a script, but this script clears stale TCC entries when
# the signing requirement changes; grant Screen Recording and Accessibility once
# in System Settings, then run this. Re-running with the same signature keeps the
# grants.
set -euo pipefail
HOST="${1:?usage: deploy-app.sh <host>}"
cd "$(dirname "$0")/.."

# Prefer the stable local identity: re-signing with a different one would look
# like a different app to TCC and throw away the Screen Recording grant.
if [ -z "${BOLTKVM_CODESIGN_IDENTITY:-}" ] \
   && security find-identity -v -p codesigning 2>/dev/null | grep -q "BoltKVM Local"; then
  export BOLTKVM_CODESIGN_IDENTITY="BoltKVM Local"
fi
./Packaging/build-app.sh
tar -czf /tmp/BoltKVM.app.tgz -C dist BoltKVM.app
scp -q /tmp/BoltKVM.app.tgz "$HOST:/tmp/BoltKVM.app.tgz"

ssh "$HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
BACKUP=/Applications/BoltKVM.app.bak
OLD_REQ=""
if [ -e /Applications/BoltKVM.app ]; then
  OLD_REQ=$(codesign -d -r- /Applications/BoltKVM.app 2>&1 | sed -n '/^designated/p' || true)
  rm -rf "$BACKUP"
  mv /Applications/BoltKVM.app "$BACKUP"
fi
if ! tar -xzf /tmp/BoltKVM.app.tgz -C /Applications; then
  if [ -e "$BACKUP" ]; then
    rm -rf /Applications/BoltKVM.app
    mv "$BACKUP" /Applications/BoltKVM.app
  fi
  echo "解包失败，已恢复旧版本。" >&2
  exit 1
fi
if ! codesign --verify --deep --strict /Applications/BoltKVM.app; then
  rm -rf /Applications/BoltKVM.app
  if [ -e "$BACKUP" ]; then mv "$BACKUP" /Applications/BoltKVM.app; fi
  echo "签名校验失败，已恢复旧版本。" >&2
  exit 1
fi
defaults write io.github.boltkvm role -string server

# Hand over from the CLI loop. Bracket patterns keep these from matching the
# shell that is running them (heredoc text is part of its own argv).
pkill -f 'soak-star[t]' 2>/dev/null || true
pkill -f 'boltkvm serve[r]' 2>/dev/null || true
for pid in $(pgrep -x BoltKVM 2>/dev/null || true); do kill -TERM "$pid" 2>/dev/null || true; done
for pid in $(pgrep -x boltkvm-server 2>/dev/null || true); do kill -TERM "$pid" 2>/dev/null || true; done
sleep 2

NEW_REQ=$(codesign -d -r- /Applications/BoltKVM.app 2>&1 | sed -n '/^designated/p' || true)
if [ -z "$OLD_REQ" ] || [ "$OLD_REQ" != "$NEW_REQ" ]; then
  for service in ScreenCapture Accessibility; do
    /usr/bin/tccutil reset "$service" io.github.boltkvm >/dev/null 2>&1 || true
  done
  echo "签名/权限身份已变化，已清除旧 TCC 条目；请在被控端上重新授予屏幕录制与辅助功能。"
else
  echo "签名身份未变，保留现有 TCC 授权。"
fi

open -a /Applications/BoltKVM.app
sleep 4
tail -3 "$HOME/Library/Logs/BoltKVM.log" 2>/dev/null || true
echo "--- 进程 ---"
pgrep -fl 'BoltKVM.app/Contents/MacOS/BoltKVM' || echo "(没有在跑：多半是屏幕录制权限没给)"
REMOTE
