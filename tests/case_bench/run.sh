#!/usr/bin/env bash
# Renders every kind of game case with synthetic scans (a coloured band on each edge: left red,
# right green, top blue, bottom yellow; a circle and an arrow up), faced and turned both ways, to
# check by eye that no print is cut, stretched, smeared or bleeding, on the real 3D shelf.
#
#   tests/case_bench/run.sh <package dir> <output dir>     (package: out/Borne; needs Pillow, an X display)
#
# Writes <output dir>/NN_0.png (faced), NN_L.png and NN_R.png (turned) for each case.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
PKG="$(cd "$1" && pwd)"; OUT="$(mkdir -p "$2" && cd "$2" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
python3 "$HERE/make_scans.py" "$WORK"
mkdir -p "$WORK/pkg/ui"
cp -a "$PKG/bin" "$WORK/pkg/"   # copied: the UI finds its views next to its own binary
for d in lib plugins qml; do ln -s "$PKG/$d" "$WORK/pkg/$d"; done
cp -a "$ROOT/ui/components" "$ROOT/ui/imports" "$ROOT/ui/fonts" "$WORK/pkg/ui/"
sed -e "s|GAMES_B64|\"$(base64 -w0 "$WORK/games.json")\"|" -e "s|OUT_DIR|\"$OUT\"|" "$HERE/Bench.qml" > "$WORK/pkg/ui/Main.qml"
timeout 300 "$WORK/pkg/bin/borne-ui"
echo "$(ls "$OUT"/*.png | wc -l) views in $OUT"
