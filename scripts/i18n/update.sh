#!/usr/bin/env bash
# Refreshes the translation files from the QML sources, then fills them from ui/i18n/<lang>.json.
#
#   scripts/i18n/update.sh [lupdate]       (default: lupdate from PATH)
#
# Workflow for a new or changed string: wrap it in qsTr("English text") in the QML, run this
# script, add the translation to ui/i18n/fr.json, run it again. Fails if a string is untranslated.
set -euo pipefail
LUPDATE="${1:-lupdate}"
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
status=0
for json in "$HERE"/ui/i18n/*.json; do
  lang="$(basename "${json%.json}")"
  ts="$HERE/ui/i18n/borne_$lang.ts"
  LC_ALL=C.UTF-8 "$LUPDATE" -silent -extensions qml -recursive "$HERE/ui" -ts "$ts" \
    -source-language en -target-language "$lang" -no-obsolete -locations none
  python3 "$HERE/scripts/i18n/fill-ts.py" "$ts" "$json" || status=1
done
exit $status
