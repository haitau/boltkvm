#!/bin/bash
# Nightly sampler for an unattended boltkvm soak. Every --interval seconds it
# appends one TSV row so the morning review does not depend on anyone watching
# the terminal. Exits by itself ~1 minute after the client process disappears.
#
#   scripts/soak-monitor.sh --client-log ~/soak/<run>/client.log \
#                           [--out ~/soak/<run>/monitor.tsv] \
#                           [--interval 300] [--client-name boltkvm]

set -u

LOG=""
OUT=""
INTERVAL=300
PNAME="boltkvm"

while [ $# -gt 0 ]; do
  case "$1" in
    --client-log) LOG="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --interval) INTERVAL="${2:-300}"; shift 2 ;;
    --client-name) PNAME="${2:-boltkvm}"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$LOG" ] || { echo "usage: $0 --client-log <path> [--out <tsv>] [--interval 300]" >&2; exit 2; }
[ -n "$OUT" ] || OUT="$(dirname "$LOG")/monitor.tsv"
mkdir -p "$(dirname "$OUT")"

HDR="ts	epoch	client_alive	rss_kb	reconnects	read_errors	warnings	zero_frame_windows	last_fps	last_p95_ms	loop_packets"

if [ ! -s "$OUT" ]; then
  printf '%s\n' "$HDR" >> "$OUT"
fi

running=1
trap 'running=0' INT TERM

sample() {
  local ts epoch pid alive rss reconnects errors warns zero fps p95 packets last
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  epoch="$(date +%s)"
  pid="$(pgrep -f "boltkvm client" | head -1 || true)"
  if [ -n "$pid" ]; then alive=1; rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo 0)"; else alive=0; rss=0; fi
  [ -n "${rss:-}" ] || rss=0

  if [ -f "$LOG" ]; then
    # A reconnect is logged as "connected to host:port"; the initial connect is
    # one of them, so subtract 1 and clamp at zero.
    # grep -c prints 0 but exits 1 on no match, so never add an || echo fallback.
    connects=$(grep -c "connected to " "$LOG" 2>/dev/null); connects=${connects:-0}
    reconnects=$((connects - 1))
    [ "$reconnects" -lt 0 ] && reconnects=0
    errors=$(grep -c "client render error\|client read error" "$LOG" 2>/dev/null); errors=${errors:-0}
    warns=$(grep -c "WARNING" "$LOG" 2>/dev/null); warns=${warns:-0}
    zero=$(grep -c "render.win elapsed=[0-9.]*s frames=0 " "$LOG" 2>/dev/null); zero=${zero:-0}
    last=$(grep "render.win" "$LOG" 2>/dev/null | tail -1 || true)
    fps=$(printf '%s' "$last" | sed -n 's/.*fps=\([0-9.]*\).*/\1/p')
    p95=$(printf '%s' "$last" | sed -n 's/.*p95=\([0-9.]*\)ms.*/\1/p')
    packets=$(grep "loop.win" "$LOG" 2>/dev/null | tail -1 | sed -n 's/.*packets=\([0-9]*\).*/\1/p')
  else
    reconnects=0; errors=0; warns=0; zero=0; fps=""; p95=""; packets=""
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$epoch" "$alive" "${rss:-0}" "$reconnects" "${errors:-0}" "${warns:-0}" \
    "${zero:-0}" "${fps:-}" "${p95:-}" "${packets:-}" >> "$OUT"
}

sample
while [ "$running" -eq 1 ]; do
  sleep "$INTERVAL" &
  wait $! 2>/dev/null
  [ "$running" -eq 1 ] || break
  sample
  # client gone for one full interval -> final sample and stop
  if ! pgrep -f "boltkvm client" >/dev/null 2>&1; then
    sleep 5
    sample
    printf '%s\t%s\tEND\t\t\t\t\t\t\t\t\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(date +%s)" >> "$OUT"
    exit 0
  fi
done
