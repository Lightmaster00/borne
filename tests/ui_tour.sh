#!/usr/bin/env bash
# Walks through every screen of a running Borne with the debug pad (BORNE_DEBUG_INPUT=1) and fails
# on any QML error in its log: library and its tabs, game page, search, quick menu, downloads,
# every Settings section row by row. Needs a paired profile (see integration_romm.py).
#
#   tests/ui_tour.sh <log of the running Borne>
set -uo pipefail
LOG="$1"
API=$(grep -ao 'API http://[^ ]*' "$LOG" | head -1 | cut -d' ' -f2)
[ -n "$API" ] || { echo "FAILED: no API in $LOG"; exit 1; }
pad() { for a in "$@"; do case $a in sleep:*) sleep "${a#sleep:}" ;; *) curl -sf -X POST "$API/api/v1/debug/pad?action=$a" >/dev/null || { echo "FAILED: debug pad closed"; exit 1; }; sleep 0.3 ;; esac; done; }
start=$(wc -l < "$LOG")
pad a sleep:4                                   # profile
pad rb rb rb rb rb rb lb lb lb lb lb lb lt rt   # tabs, letters
pad right right left a sleep:2 down down up up b sleep:1   # game page
pad y sleep:1 b select sleep:1 b              # search, quick menu
pad start sleep:2                                # settings
for section in 1 2 3 4 5 6 7 8; do
  pad right; for _ in $(seq 1 14); do pad down; done; pad b down sleep:0.5
done
pad b sleep:1
errors=$(tail -n +"$start" "$LOG" | grep -aE "TypeError|ReferenceError|\.qml:[0-9]+: |Unable to assign" | sort | uniq -c)
if [ -n "$errors" ]; then echo "FAILED: QML errors during the tour"; echo "$errors"; exit 1; fi
echo "UI tour passed: no QML error"
