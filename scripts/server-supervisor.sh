#!/bin/bash
# Runs inside Terminal on the controlled Mac (deployed as ~/soak-start.sh and
# invoked by a login item / ~/soak-start.command).
#
# Why Terminal: Screen Recording TCC is bound to the responsible GUI app, so a
# launchd job gets "Screen Recording permission missing" — but a shell loop in
# Terminal can keep the server alive.
#
# Extra server flags come from ~/boltkvm-flags (absent = defaults, audio
# isolated). Killing the server is enough to pick up a change: the loop
# restarts it within 3 s.
#
# Single-instance guard: repeated opens (login item + manual) would otherwise
# fight over port 7474 and spam "Address already in use".
#
# The pkill pattern uses a character class so this script does not match its
# own command line when it runs.
LOG=/Users/shawn/Library/Logs/boltkvm-server.log
PIDFILE=/tmp/boltkvm-server.pid

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "$(date '+%F %T') another supervisor is already running (pid $(cat "$PIDFILE")); this window can be closed" | tee -a "$LOG"
  exit 0
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"; exit 0' EXIT INT TERM

cd /Users/shawn || exit 1
# Extra server flags live in ~/boltkvm-flags so enabling audio does not mean
# editing this script (empty/absent = default, audio isolated).
FLAGS=$(cat /Users/shawn/boltkvm-flags 2>/dev/null)
pkill -f 'boltkvm serve[r]' 2>/dev/null
sleep 1
while true; do
  echo "=== $(date '+%F %T') starting server ===" >> "$LOG"
  ./boltkvm server --width 3840 --height 2160 --port 7474 --seconds 0 $FLAGS >> "$LOG" 2>&1
  rc=$?
  echo "=== $(date '+%F %T') server exited rc=$rc; restarting in 3s ===" >> "$LOG"
  sleep 3
done
