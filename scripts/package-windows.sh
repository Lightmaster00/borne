#!/usr/bin/env bash
# Builds the self-contained Borne Windows package (Rust core + QML UI + bundled Qt 6).
#
#   scripts/package-windows.sh <qt_prefix> <output>
#
# <qt_prefix>: a Qt 6 installation (bin/ with windeployqt and lrelease, lib/ with the
# dlls) — the jurplel/install-qt-action folder in CI, or the official/Kitware Qt in a
# local build. QT_PREFIX or QTDIR are used when the argument is left empty.
#
# Resulting layout (the Qt libraries stay next to the executables, where Windows finds them;
# plugins and QML modules are redirected to the package root by bin/qt.conf):
#   Borne/bin/{borne.exe, borne-ui.exe, qt.conf, <Qt dlls>}
#   Borne/{plugins, qml, ui, resources}, borne.bat, README.md, LICENSE
# The package is zipped as Borne-windows-x86_64.zip in <output>.
set -euo pipefail
QT="${1:-${QT_PREFIX:-${QTDIR:-}}}"
OUT="${2:-$PWD/out-windows}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "$QT" ] || { echo "No Qt prefix: pass one as the first argument, or set QT_PREFIX/QTDIR"; exit 1; }
[ -x "$QT/bin/windeployqt" ] || [ -x "$QT/bin/windeployqt.exe" ] || { echo "windeployqt not found in $QT/bin"; exit 1; }
WINDEPLOYQT="$QT/bin/windeployqt"
[ -x "$WINDEPLOYQT" ] || WINDEPLOYQT="$QT/bin/windeployqt.exe"
LRELEASE="$QT/bin/lrelease"
[ -x "$LRELEASE" ] || LRELEASE="$QT/bin/lrelease.exe"

cargo build --release --manifest-path "$HERE/core/Cargo.toml"
cmake -S "$HERE/ui/launcher" -B "$HERE/build-windows" -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$QT"
cmake --build "$HERE/build-windows" -j

PKG="$OUT/Borne"
rm -rf "$PKG"
mkdir -p "$PKG/bin" "$PKG/qml" "$PKG/ui/i18n" "$PKG/resources"

cp "$HERE/core/target/release/borne.exe" "$PKG/bin/"
cp "$HERE/build-windows/borne-ui.exe" "$PKG/bin/"
# Qt resolves plugins and QML modules from the package root; the dlls must stay next to the
# executables (Windows searches there first).
cat > "$PKG/bin/qt.conf" <<'CONF'
[Paths]
Prefix=..
Libraries=.
Plugins=plugins
QmlImports=qml
CONF

# Qt runtime: the dlls (next to the executables), the plugins and the QML modules the views
# import. windeployqt places plugins and QML modules next to the executable (older Qt) or under
# the qt.conf prefix (Qt ≥ 6.3): whatever it put in bin/ besides the executables, the qt.conf
# and the dlls is moved where Qt will find it at runtime.
"$WINDEPLOYQT" --release --qmldir "$HERE/ui" --qmlimport "$HERE/ui/imports" "$PKG/bin/borne-ui.exe" >/dev/null
mkdir -p "$PKG/plugins"
for d in "$PKG"/bin/*/; do
  [ -d "$d" ] || continue
  base="$(basename "$d")"
  if [ "$base" = "plugins" ]; then
    rm -rf "$PKG/plugins"
    mv "$d" "$PKG/plugins"
  elif [ "$base" = "qml" ]; then
    # A container holding the modules.
    (cd "$d" && mv -f */ "$PKG/qml/" 2>/dev/null) || true
    rm -rf "$d"
  else
    mv "$d" "$PKG/qml/"
  fi
done
for n in QtCore QtGui QtQml QtQuick QtMultimedia QtWebSockets; do
  [ -f "$PKG/bin/$n.dll" ] || { echo "Missing from the package: bin/$n.dll"; exit 1; }
done
[ -d "$PKG/qml/QtQuick" ] || [ -d "$PKG/qml/QtQml" ] || { echo "No QML module in the package"; exit 1; }
# The offscreen platform plugin: displays on machines without a usable GPU (and the CI tests).
if [ -f "$QT/plugins/platforms/qoffscreen.dll" ]; then
  mkdir -p "$PKG/plugins/platforms"
  cp -a "$QT/plugins/platforms/qoffscreen.dll" "$PKG/plugins/platforms/"
fi

mkdir -p "$PKG/ui/i18n"
cp -R "$HERE/ui/Main.qml" "$HERE/ui/components" "$HERE/ui/imports" "$HERE/ui/fonts" "$HERE/ui/sounds" "$HERE/ui/brand" "$PKG/ui/"
for ts in "$HERE"/ui/i18n/*.ts; do "$LRELEASE" -silent "$ts" -qm "$PKG/ui/i18n/$(basename "${ts%.ts}").qm"; done
cp -R "$HERE/resources/." "$PKG/resources/"
cp "$HERE/README.md" "$HERE/LICENSE" "$PKG/"

cat > "$PKG/borne.bat" <<'BAT'
@echo off
rem Borne - entry point: the core starts its local API, then launches and supervises the QML UI.
"%~dp0bin\borne.exe" %*
BAT

# The archive (the release publishes this one; python3 or PowerShell, whichever is around).
cd "$OUT"
rm -f Borne-windows-x86_64.zip
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import shutil; shutil.make_archive('Borne-windows-x86_64', 'zip', root_dir='$OUT', base_dir='Borne')"
else
  powershell -NoProfile -Command "Compress-Archive -Path '$PKG' -DestinationPath 'Borne-windows-x86_64.zip' -Force"
fi
echo "Package ready: $PKG"
