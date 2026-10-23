#!/bin/bash
# Regression tests. XCTest ships with Xcode, not with the Command Line Tools, so
# a machine that only has CLT (or has Xcode installed but not selected — common
# on a headless Mac) cannot run `swift test`. In that case fall back to the two
# dependency-free self-tests in the CLI, which cover the same wire/crypto paths.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  # Pointing DEVELOPER_DIR at Xcode is enough; no sudo xcode-select switch needed.
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if xcrun --find xctest >/dev/null 2>&1; then
  exec swift test "$@"
fi

echo "==> XCTest not available (Command Line Tools only); running CLI self-tests"
swift build -c release --product boltkvm
.build/release/boltkvm selftest
.build/release/boltkvm cryptotest
