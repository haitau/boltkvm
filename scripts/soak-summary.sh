#!/bin/bash
# Summarise an input-continuity run directory (see scripts/input-continuity.sh).
#
#   scripts/soak-summary.sh ~/soak/2026-10-22-night-8h
#
# Prints the numbers the report needs, and fails loudly when something is off:
# a dead client, reconnects, a disabled tap, or probe events that never arrived.
set -u
DIR="${1:-}"
if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
  echo "usage: $0 <run-dir>" >&2
  exit 2
fi

posted=$(grep -o 'posted=[0-9]*' "$DIR/probe.log" 2>/dev/null | tail -1 | cut -d= -f2)
sent=$(grep -o 'input.win sent=[0-9]*' "$DIR/client.log" 2>/dev/null | tail -1 | cut -d= -f2)
reconnects=$(grep -o 'reconnects=[0-9]*' "$DIR/client.log" 2>/dev/null | tail -1 | cut -d= -f2)
tap=$(grep -o 'tapDisabled=[0-9]*' "$DIR/client.log" 2>/dev/null | tail -1 | cut -d= -f2)
samples=$(awk -F'\t' 'NR>1' "$DIR/monitor.tsv" 2>/dev/null | wc -l | tr -d ' ')
dead=$(awk -F'\t' 'NR>1 && $3 != 1' "$DIR/monitor.tsv" 2>/dev/null | wc -l | tr -d ' ')
rss_first=$(awk -F'\t' 'NR==2 {print $4}' "$DIR/monitor.tsv" 2>/dev/null)
rss_last=$(awk -F'\t' 'END {print $4}' "$DIR/monitor.tsv" 2>/dev/null)
fps_last=$(awk -F'\t' 'END {print $9}' "$DIR/monitor.tsv" 2>/dev/null)
zero_last=$(awk -F'\t' 'END {print $8}' "$DIR/monitor.tsv" 2>/dev/null)
p95_last=$(awk -F'\t' 'END {print $10}' "$DIR/monitor.tsv" 2>/dev/null)
first=$(awk -F'\t' 'NR==2 {print $1" "$2}' "$DIR/monitor.tsv" 2>/dev/null)
last=$(awk -F'\t' 'END {print $1" "$2}' "$DIR/monitor.tsv" 2>/dev/null)

echo "run:            $DIR"
echo "window:         $first .. $last"
echo "probe posted:   ${posted:-?}"
echo "input sent:     ${sent:-?}"
echo "reconnects:     ${reconnects:-?}"
echo "tapDisabled:    ${tap:-?}"
echo "samples:        $samples (client dead in $dead)"
echo "rss kb:         ${rss_first:-?} -> ${rss_last:-?}"
echo "last fps/p95:   ${fps_last:-?} / ${p95_last:-?}   zero-frame windows: ${zero_last:-?}"

status=0
[ "$dead" != "0" ] && { echo "FAIL: client was not alive in $dead samples"; status=1; }
[ "${reconnects:-0}" != "0" ] && { echo "FAIL: reconnects=$reconnects"; status=1; }
[ "${tap:-1}" != "0" ] && { echo "FAIL: tapDisabled=$tap"; status=1; }
if [ -n "${posted:-}" ] && [ -n "${sent:-}" ] && [ "$sent" -lt "$posted" ]; then
  echo "FAIL: probe posted $posted but client sent only $sent"
  status=1
fi
exit $status
