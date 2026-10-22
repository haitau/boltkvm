#!/bin/bash
# Rescue-channel check for a headless boltkvm host.
#
# Run from the controlling Mac. Verifies, without needing a password, that the
# three independent channels are reachable: SSH (start/repair), VNC (unlock a
# locked session), and the boltkvm port (screen/input).
#
#   scripts/rescue.sh --host <bridge-ip> [--port 7474]
#
# Exit code: 0 if every channel answers, 1 otherwise.

set -u

HOST=""
PORT=7474
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$HOST" ]; then
  echo "usage: $0 --host <bridge-ip> [--port 7474]" >&2
  exit 2
fi

FAIL=0
ok()   { printf '  %-28s OK   %s\n' "$1" "$2"; }
bad()  { printf '  %-28s FAIL %s\n' "$1" "$2"; FAIL=1; }
warn() { printf '  %-28s WARN %s\n' "$1" "$2"; }

# TCP reachability. macOS nc has no --wait; -G is the connect timeout.
probe() {
  nc -z -G 3 "$1" "$2" >/dev/null 2>&1
}

# Read the first bytes a server sends, to prove it is the service we expect.
banner() {
  (printf '' | nc -G 3 "$1" "$2" 2>/dev/null | head -c 32) 2>/dev/null
}

echo "== boltkvm rescue check: $HOST =="

# 1. SSH — the channel you repair everything else with.
if probe "$HOST" 22; then
  B=$(banner "$HOST" 22)
  case "$B" in
    SSH-*) ok "ssh (22)" "banner ${B%%$'\n'*}" ;;
    *)     warn "ssh (22)" "port open but no SSH banner" ;;
  esac
else
  bad "ssh (22)" "closed — host down, or Remote Login off (needs physical access)"
fi

# 2. VNC — unlock a session that rebooted into the lock screen.
if probe "$HOST" 5900; then
  B=$(banner "$HOST" 5900)
  case "$B" in
    RFB*) ok "vnc (5900)" "banner ${B%%$'\n'*}" ;;
    *)    warn "vnc (5900)" "port open but no RFB banner" ;;
  esac
else
  bad "vnc (5900)" "closed — Screen Sharing off; enable it over ssh if you still have ssh"
fi

# 3. boltkvm — the video/input channel itself.
if probe "$HOST" "$PORT"; then
  ok "boltkvm ($PORT)" "accepting connections"
else
  bad "boltkvm ($PORT)" "closed — start the server over ssh: open -a Terminal ~/soak-start.sh"
fi

echo
if [ "$FAIL" -ne 0 ]; then
  cat <<'EOF'
Recovery order:
  1. ssh:   ssh <host>                      # if this fails you need physical access
  2. unlock: open Screen Sharing to the host, type the login password
  3. start:  ssh <host> 'open -a Terminal ~/soak-start.sh'
  4. verify: scripts/rescue.sh --host <host>

A rebooted host lands on the login window with the screen locked; SSH and VNC
are both available before and after login, which is why the rescue path does not
depend on boltkvm running.
EOF
  exit 1
fi
echo "RESULT: all channels reachable"
