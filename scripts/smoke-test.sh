#!/usr/bin/env bash
# Startup test of a Borne package:
# the core starts, answers on its API and launches the UI, which loads all its QML views without errors.
#
#   scripts/smoke-test.sh <core executable>     (out/Borne/bin/borne or Borne.app/Contents/MacOS/borne)
#
# BORNE_LANG (e.g. fr) runs the UI in another language, to check the translations load.
set -uo pipefail
CORE="$1"
DATA="$(mktemp -d)"
LOG="$DATA/borne.log"
export BORNE_DATA_DIR="$DATA/data"
# Headless Linux: offscreen rendering. macOS: native display (CI machines have a graphical session).
[ "$(uname)" = "Linux" ] && export QT_QPA_PLATFORM=offscreen

"$CORE" > "$LOG" 2>&1 &
PID=$!
API=""
for _ in $(seq 1 40); do
  API=$(grep -ao 'API http://[^ ]*' "$LOG" | head -1 | cut -d' ' -f2)
  [ -n "$API" ] && break
  sleep 0.25
done
fail() { echo "FAILED: $1"; echo "--- log ---"; cat "$LOG"; kill "$PID" 2>/dev/null; exit 1; }
[ -n "$API" ] || fail "the core did not start"
curl -sf "$API/api/v1/hello" | grep -q '"api":1' || fail "the API does not answer"
curl -sf "$API/api/v1/themes" | grep -q nocturne || fail "built-in themes not found"

sleep 6   # let the UI start and load its views
kill -0 "$PID" 2>/dev/null || fail "the core stopped"
if grep -aE "qml: |\.qml:[0-9]+|module .* is not installed|TypeError|ReferenceError|cannot launch the UI|the UI stopped" "$LOG"; then
  fail "errors in the UI"
fi
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
echo "Startup test passed: core, API and QML UI${BORNE_LANG:+ (language: $BORNE_LANG)}"
