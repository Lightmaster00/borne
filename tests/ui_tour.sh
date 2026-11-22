#!/usr/bin/env bash
# Walks through every screen of a running Borne with the debug pad (BORNE_DEBUG_INPUT=1) and fails
# on any QML error in its log: the home (recent games, collections, the rail), a folder and its
# order, the Store's consoles and one console's games, game page (fact sheet, its case in 3D, gallery) and its
# settings, search, every Settings section row by row. Needs a paired profile (see integration_romm.py).
#
#   tests/ui_tour.sh <log of the running Borne>
set -uo pipefail
LOG="$1"
API=$(grep -ao 'API http://[^ ]*' "$LOG" | head -1 | cut -d' ' -f2)
[ -n "$API" ] || { echo "FAILED: no API in $LOG"; exit 1; }
pad() { for a in "$@"; do case $a in sleep:*) sleep "${a#sleep:}" ;; *) curl -sf -X POST "$API/api/v1/debug/pad?action=$a" >/dev/null || { echo "FAILED: debug pad closed"; exit 1; }; sleep 0.3 ;; esac; done; }
start=$(wc -l < "$LOG")
pad a sleep:4                                   # profile
pad right right left down right left up          # home: the recent games, the collections
pad left up up down down down down up up right   # the rail
pad down a sleep:1 right down left lt rt b sleep:1 up   # a collection's folder
for _ in $(seq 1 14); do pad right; done; pad a sleep:1 down y sleep:1 down a sleep:1 b sleep:1  # See all, its order
pad rb sleep:1 right left rt lt a sleep:1 right a sleep:2 b sleep:1 b sleep:1  # the Store: a console, a game
pad y sleep:1 up a sleep:1 lb sleep:1               # the consoles' order
pad a sleep:2 right right right a sleep:1 a left left left sleep:1  # game page, its fact sheet
pad up left right up down a down right left up      # its case in 3D, its gallery
pad y sleep:2 b sleep:1                            # Y: its settings, and back
pad right right a sleep:2                          # its settings, every section row by row
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
