#!/bin/bash
# Input-continuity run: probe + client + sampler in one command.
#
#   scripts/input-continuity.sh --host <bridge-ip> [--seconds 28800] [--out DIR]
#                               [--interval-ms 60000] [--bin .build/release/boltkvm]
#
# Starts the probe first so the tap has events to forward as soon as it comes
# up, then the fullscreen client, then the 5-minute sampler. Everything lands in
# <out>/{probe,client,monitor}.log|tsv; a summary is printed at the end.
#
# The client takes over the screen and swallows keyboard/mouse for the whole
# run — this is meant for an unattended window.

set -u

HOST=""
SECONDS_TOTAL=28800
OUT=""
INTERVAL_MS=60000
BIN=""
PORT=7474

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --port) PORT="${2:-7474}"; shift 2 ;;
    --seconds) SECONDS_TOTAL="${2:-28800}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --interval-ms) INTERVAL_MS="${2:-60000}"; shift 2 ;;
    --bin) BIN="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$HOST" ]; then
  echo "usage: $0 --host <bridge-ip> [--seconds 28800] [--out DIR]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -z "$BIN" ] && BIN="$ROOT/.build/release/boltkvm"
[ -z "$OUT" ] && OUT="$HOME/soak/$(date +%F-%H%M)-input"
mkdir -p "$OUT"
: > "$OUT/client.log"

EXPECTED=$((SECONDS_TOTAL / (INTERVAL_MS / 1000)))

echo "== input continuity =="
echo "  host=$HOST  seconds=$SECONDS_TOTAL  interval=${INTERVAL_MS}ms"
echo "  expected probe events=$EXPECTED  out=$OUT"

# 1) probe first: its events must exist before the tap comes up
"$BIN" inputprobe --seconds "$SECONDS_TOTAL" --interval-ms "$INTERVAL_MS" > "$OUT/probe.log" 2>&1 &
PROBE_PID=$!
sleep 2

# 2) sampler
"$ROOT/scripts/soak-monitor.sh" --client-log "$OUT/client.log" --out "$OUT/monitor.tsv" \
  --interval 300 > "$OUT/monitor.err" 2>&1 &
MON_PID=$!

# 3) client (fullscreen, swallows input)
"$BIN" client --host "$HOST" --port "$PORT" --seconds "$SECONDS_TOTAL" \
  --render --switch-mode --input --reconnect > "$OUT/client.log" 2>&1
CLIENT_RC=$?

kill "$PROBE_PID" 2>/dev/null
sleep 2
kill "$MON_PID" 2>/dev/null

echo
echo "== summary (client rc=$CLIENT_RC) =="
echo -n "probe posted:   "; tail -1 "$OUT/probe.log" | sed 's/.*posted=/posted=/'
echo -n "client sent:    "; grep -o 'input.win sent=[0-9]*' "$OUT/client.log" | tail -1
echo -n "tapDisabled:    "; grep -o 'tapDisabled=[0-9]*' "$OUT/client.log" | tail -1
echo -n "reconnects:     "; grep -o 'reconnects=[0-9]*' "$OUT/client.log" | tail -1
echo -n "motion windows: "; grep -c 'render.win' "$OUT/client.log"
echo "logs: $OUT"
