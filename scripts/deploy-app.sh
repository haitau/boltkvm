#!/bin/bash
# Switches the controlled machine from the CLI supervisor (~/soak-start.sh) to
# BoltKVM.app in server role: builds, installs to /Applications, stops the CLI
# loop, starts the app.
#
#   scripts/deploy-app.sh 10.0.20.2
#
# Precondition: BoltKVM.app must have Screen Recording permission on the target.
# TCC cannot be scripted; grant it once in System Settings → Privacy & Security →
# Screen Recording, then run this. Re-running is safe (idempotent).
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
rm -rf /Applications/BoltKVM.app
tar -xzf /tmp/BoltKVM.app.tgz -C /Applications
codesign --verify --deep --strict /Applications/BoltKVM.app
defaults write io.github.boltkvm role -string server

# Hand over from the CLI loop. Bracket patterns keep these from matching the
# shell that is running them (heredoc text is part of its own argv).
pkill -f 'soak-star[t]' 2>/dev/null || true
pkill -f 'boltkvm serve[r]' 2>/dev/null || true
pkill -f 'BoltKVM.app/Contents/MacOS/BoltKVM' 2>/dev/null || true
sleep 2

open -a /Applications/BoltKVM.app
sleep 4
tail -3 "$HOME/Library/Logs/BoltKVM.log" 2>/dev/null || true
echo "--- 进程 ---"
pgrep -fl 'BoltKVM.app/Contents/MacOS/BoltKVM' || echo "(没有在跑：多半是屏幕录制权限没给)"
REMOTE
