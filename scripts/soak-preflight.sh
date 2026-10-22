#!/bin/bash
# 8h soak pre-flight. Run on the CLIENT machine (the MacBook Pro) right before
# starting the run. Fails closed: any blocking check that fails exits non-zero.
#
#   scripts/soak-preflight.sh --host <mini> [--port 7474] [--seconds 28800]
#
# Creates a run directory (~/soak/<date-time>) and prints the exact commands
# for both ends plus the log path to hand to soak-monitor.sh.

set -u

HOST=""
PORT=7474
SECONDS_ARG=28800
OUTBASE="$HOME/soak"

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --port) PORT="${2:-7474}"; shift 2 ;;
    --seconds) SECONDS_ARG="${2:-28800}"; shift 2 ;;
    --outdir) OUTBASE="${2:-$HOME/soak}"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$HOST" ]; then
  echo "usage: $0 --host <mini-host-or-ip> [--port 7474] [--seconds 28800]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/release/boltkvm"
RUN="$OUTBASE/$(date +%Y-%m-%d-%H%M)"
LOG="$RUN/client.log"
FAIL=0

say()  { printf '%-42s %s\n' "$1" "$2"; }
ok()   { say "$1" "OK   $2"; }
warn() { say "$1" "WARN $2"; }
bad()  { say "$1" "FAIL $2"; FAIL=1; }

echo "== boltkvm 8h soak pre-flight =="
echo "run dir : $RUN"
echo "client  : $(hostname -s)"
echo "server  : $HOST:$PORT"
echo

# 1. binary
if [ -x "$BIN" ]; then ok "release binary" "$BIN"; else bad "release binary" "missing, run: swift build -c release"; fi

# 1b. pre-shared key (the server refuses to start without one)
KEYFILE="$HOME/.boltkvm-key"
if [ -s "$KEYFILE" ]; then
  KMODE="$(stat -f '%Lp' "$KEYFILE")"
  if [ "$KMODE" = "600" ]; then ok "psk file" "$KEYFILE (600)"; else warn "psk file" "$KEYFILE mode $KMODE, want 600 (chmod 600)"; fi
elif [ -n "${BOLTKVM_KEY:-}" ]; then
  ok "psk" "from \$BOLTKVM_KEY"
else
  bad "psk" "no ~/.boltkvm-key and no \$BOLTKVM_KEY; server will refuse to start"
fi

# 2. caffeinate with the right flags
CAF="$(pgrep -x caffeinate | head -1 || true)"
if [ -n "$CAF" ]; then
  CARGS="$(ps -o args= -p "$CAF" | tr -d '\n')"
  # Flags may be clustered (-imsd), so look for d inside any dash token.
  CFLAGS="$(printf '%s\n' $CARGS | grep '^-' | tr -d '\n')"
  case "$CFLAGS" in
    *d*) ok "caffeinate" "pid $CAF ($CARGS)" ;;
    *)   warn "caffeinate" "pid $CAF lacks -d, display may sleep ($CARGS)" ;;
  esac
else
  bad "caffeinate" "not running; start: caffeinate -imsd &"
fi

# 3. power assertions actually held
ASSERT="$(pmset -g assertions 2>/dev/null)"
if echo "$ASSERT" | grep -q "PreventUserIdleDisplaySleep *1"; then
  ok "display sleep assertion" "held"
else
  warn "display sleep assertion" "not held (lock screen would stall the render leg)"
fi
if echo "$ASSERT" | grep -q "PreventSystemSleep *1"; then
  ok "system sleep assertion" "held"
else
  warn "system sleep assertion" "not held"
fi
PWR="$(pmset -g ps 2>/dev/null | head -1)"
case "$PWR" in
  *AC*) ok "power" "on AC (caffeinate -s only works on AC)" ;;
  *)    warn "power" "on battery: $PWR" ;;
esac

# 4. old processes
LEFT="$(pgrep -fl 'boltkvm (client|server)' | grep -v pgrep || true)"
if [ -z "$LEFT" ]; then ok "no leftover boltkvm" "-"; else bad "no leftover boltkvm" "$(echo "$LEFT" | tr '\n' ' ')"; fi

# 5. server reachable
if command -v nc >/dev/null 2>&1; then
  if nc -z -G 3 -w 3 "$HOST" "$PORT" >/dev/null 2>&1; then ok "server TCP" "$HOST:$PORT reachable"; else bad "server TCP" "$HOST:$PORT unreachable"; fi
else
  if (exec 3<>"/dev/tcp/$HOST/$PORT") 2>/dev/null; then ok "server TCP" "reachable"; else bad "server TCP" "unreachable (no nc, tried /dev/tcp)"; fi
fi

# 6. disk for logs (8h of 60s lines is small, but tee + warnings add up)
FREE_MB=$(( $(df -m "$HOME" | tail -1 | awk '{print $4}') ))
if [ "$FREE_MB" -gt 2048 ]; then ok "free disk" "${FREE_MB}MB"; else warn "free disk" "${FREE_MB}MB"; fi

mkdir -p "$RUN"
cat > "$RUN/README.txt" <<EOF
run     : $RUN
started : $(date '+%Y-%m-%d %H:%M:%S %Z')
client  : $(hostname -s)
server  : $HOST:$PORT
seconds : $SECONDS_ARG
binary  : $BIN
EOF

echo
echo "-- server (mini, terminal there) ----------------------------------------"
echo "pgrep -fl 'boltkvm server' && pkill -f 'boltkvm server'   # leftovers wedge SCStream"
echo "~/boltkvm server --width 3840 --height 2160 --port $PORT --seconds 0 \\"
echo "  2>&1 | tee ~/soak-server-\$(date +%F).log"
echo
echo "-- client (this machine) ------------------------------------------------"
echo "nohup $BIN client --host $HOST --port $PORT --seconds $SECONDS_ARG \\"
echo "  --render --switch-mode --input --reconnect 2>&1 | tee $LOG &"
echo
echo "-- sampler (start right after the client) -------------------------------"
echo "nohup $ROOT/scripts/soak-monitor.sh --client-log $LOG \\"
echo "  --out $RUN/monitor.tsv --interval 300 >/dev/null 2>&1 &"
echo
echo "-- first 20 minutes -----------------------------------------------------"
echo "grep -E 'render.win|loop.win|input.win|WARNING|error' $LOG | tail -20"
echo

if [ "$FAIL" -ne 0 ]; then
  echo "RESULT: NOT READY (see FAIL above)"
  exit 1
fi
echo "RESULT: READY"
