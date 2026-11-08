#!/usr/bin/env bash
# Checks the syntax and blocking errors of every QML file in the UI.
#   scripts/check-qml.sh <qt_dir>     (the Qt 6.8 folder containing qmllint or bin/qmllint)
set -uo pipefail
QT="$1"; HERE="$(cd "$(dirname "$0")/.." && pwd)"
LINT=""
for c in "$QT/qmllint" "$QT/bin/qmllint" "$QT/../qmllint"; do [ -f "$c" ] && chmod +x "$c" 2>/dev/null; [ -x "$c" ] && LINT="$c" && break; done
[ -z "$LINT" ] && { echo "qmllint not found in $QT"; exit 2; }
export LD_LIBRARY_PATH="$QT/lib:${LD_LIBRARY_PATH:-}"
status=0
while IFS= read -r f; do
  # Style warnings disabled: only syntax errors fail (non-zero exit code).
  if ! out=$(LC_ALL=C.UTF-8 "$LINT" -I "$HERE/ui/imports" -I "$QT/qml" --unqualified disable --missing-property disable \
        --unresolved-type disable --import disable --compiler disable "$f" 2>&1); then
    echo "✗ ${f#$HERE/}"; echo "$out" | grep -v "locale" | head -5; status=1
  fi
done < <(find "$HERE/ui" -name '*.qml' -not -path '*/launcher/*')
[ $status -eq 0 ] && echo "QML: no syntax errors"
exit $status
