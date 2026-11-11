#!/usr/bin/env bash
# Builds Borne.app for macOS (Apple Silicon or Intel), with Qt bundled.
#
#   scripts/package-macos.sh <output>
#
# Requirements: Rust, CMake, Qt ≥ 6.9 — official Qt (QT_PREFIX=<Qt dir>/6.9.3/macos) or Homebrew (`brew install qt`).
#
# Resulting layout:
#   Borne.app/Contents/MacOS/borne        core (main executable, launches and supervises the UI)
#   Borne.app/Contents/MacOS/borne-ui     QML UI
#   Borne.app/Contents/Resources/ui       views, Borne.Theme module, translations
#   Borne.app/Contents/Frameworks, PlugIns, Resources/qml   Qt (macdeployqt)
set -euo pipefail
OUT="$1"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
QT_PREFIX="${QT_PREFIX:-${QT_ROOT_DIR:-$(brew --prefix qt)}}"

cargo build --release --manifest-path "$HERE/core/Cargo.toml"
cmake -S "$HERE/ui/launcher" -B "$HERE/build-macos" -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$QT_PREFIX"
cmake --build "$HERE/build-macos" -j

APP="$OUT/Borne.app"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$HERE/build-macos/Borne.app" "$APP"

UI="$APP/Contents/Resources/ui"
mkdir -p "$UI/i18n" "$APP/Contents/Resources/resources"
cp -R "$HERE/ui/Main.qml" "$HERE/ui/components" "$HERE/ui/imports" "$HERE/ui/fonts" "$HERE/ui/sounds" "$UI/"
for ts in "$HERE"/ui/i18n/*.ts; do "$QT_PREFIX/bin/lrelease" -silent "$ts" -qm "$UI/i18n/$(basename "${ts%.ts}").qm"; done
cp -R "$HERE/resources/." "$APP/Contents/Resources/resources/" 2>/dev/null || true
cp -R "$HERE/examples" "$APP/Contents/Resources/examples" 2>/dev/null || true

# Qt: frameworks, plugins and QML modules used by the views (import scan).
# Homebrew splits Qt into several packages (qtbase, qtmultimedia…): all their folders are given
# to macdeployqt so it finds every framework. Not needed with the official Qt (single prefix).
LIBPATHS=()
for d in "$QT_PREFIX/lib" /opt/homebrew/opt/qt*/lib /usr/local/opt/qt*/lib; do
  [ -d "$d" ] && LIBPATHS+=("-libpath=$d")
done
"$QT_PREFIX/bin/macdeployqt" "$APP" -qmldir="$UI" -qmlimport="$UI/imports" -always-overwrite "${LIBPATHS[@]}"
# Check: the required frameworks are bundled.
for fw in QtCore QtGui QtQml QtQuick QtMultimedia QtWebSockets QtQuick3D; do
  [ -d "$APP/Contents/Frameworks/$fw.framework" ] || { echo "Framework missing from the app: $fw"; exit 1; }
done

# The core becomes the app's main executable; the UI keeps its own binary.
mv "$APP/Contents/MacOS/Borne" "$APP/Contents/MacOS/borne-ui"
cp "$HERE/core/target/release/borne" "$APP/Contents/MacOS/borne"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable borne" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSApplicationCategoryType string public.app-category.games" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$APP/Contents/Info.plist" 2>/dev/null || true

# Ad hoc signature (required on Apple Silicon after the binaries were modified).
codesign --force --deep --sign - "$APP"

ditto -c -k --keepParent "$APP" "$OUT/Borne-macos-$(uname -m).zip"
echo "App ready: $APP"
