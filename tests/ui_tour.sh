#!/usr/bin/env bash
# Walks through every screen of a running Borne with the debug pad (BORNE_DEBUG_INPUT=1) and fails
# on any QML error in its log: library, its tabs, the Store's consoles, the Consoles menu and its
# order, the three layouts, game page and its settings, search, quick menu, downloads,
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
pad rb lb rb lb lt rt rt lt                      # My library / Store, groups
pad rb sleep:1 right down left a sleep:1 down right b sleep:1 b lb  # the Store's consoles, one console's games, back
pad x sleep:1 right right down right a up a sleep:1  # consoles: one console, a quick filter
pad x sleep:1 up right right left down rb lb a sleep:1  # consoles' order, your own order
pad x sleep:1 down right a up left left left left a sleep:1  # every console again, the filter off
for n in 6 7 8 5; do                                # each layout of the covers, moving in it
  pad y sleep:1; for _ in $(seq 1 $n); do pad down; done; pad a sleep:1 right down right up left
done
pad right right left a sleep:2 down down up up        # game page
pad y sleep:2 b sleep:1                            # Y: its settings, and back
pad up up up down down a sleep:2                   # its settings, every section row by row
for section in 1 2 3 4 5 6 7; do
  pad right; for _ in $(seq 1 10); do pad down; done; pad b down sleep:0.5
done
pad b sleep:0.5 b sleep:1
pad y sleep:1 down a sleep:1 y sleep:1 up a sleep:1  # sort: by name, then back
pad select sleep:1 b                             # search
pad start sleep:2                                # settings
for section in 1 2 3 4 5 6 7 8 9 10 11; do
  pad right; for _ in $(seq 1 14); do pad down; done; pad b down sleep:0.5
done
pad b sleep:1
pad start sleep:2 down right a sleep:1              # a console's own page, then back to its list
for _ in $(seq 1 20); do pad down; done
pad b down a sleep:1 b b b sleep:1
pad start sleep:2 right a sleep:1 b b b sleep:1     # the overview's first line opens its section
errors=$(tail -n +"$start" "$LOG" | grep -aE "TypeError|ReferenceError|\.qml:[0-9]+: |Unable to assign" | sort | uniq -c)
if [ -n "$errors" ]; then echo "FAILED: QML errors during the tour"; echo "$errors"; exit 1; fi
echo "UI tour passed: no QML error"
