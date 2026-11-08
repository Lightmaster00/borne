#!/usr/bin/env bash
# Builds the self-contained Borne package (Rust core + QML UI + bundled Qt 6.8).
#
#   scripts/package.sh <qt_dir> <output>
#
# <qt_dir>: a Qt 6.8 containing lib/, plugins/, qml/ (for instance the PySide6/Qt folders
# extracted from the pyside6-essentials and pyside6-addons wheels, merged).
# LRELEASE: path to Qt's lrelease (default: lrelease from PATH) to compile the translations.
set -euo pipefail
QT="$1"; OUT="$2"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

cargo build --release --manifest-path "$HERE/core/Cargo.toml"
cmake -S "$HERE/ui/launcher" -B "$HERE/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$HERE/build" -j

rm -rf "$OUT"; mkdir -p "$OUT"/{bin,lib,plugins,qml,resources}

# Qt libraries: everything except unused modules (WebEngine, 3D, charts…)
cp -a "$QT/lib/." "$OUT/lib/"
( cd "$OUT/lib" && rm -rf cmake pkgconfig metatypes ./*.prl \
  libQt6WebEngine* libQt63D* libQt6Quick3D* libQt6Charts* libQt6DataVisualization* libQt6Graphs* \
  libQt6Location* libQt6Pdf* libQt6Designer* libQt6Bluetooth* libQt6Nfc* libQt6Sensors* libQt6Serial* \
  libQt6Scxml* libQt6StateMachine* libQt6RemoteObjects* libQt6TextToSpeech* libQt6WebView* libQt6Positioning* \
  libQt6Help* libQt6UiTools* libQt6HttpServer* libQt6SpatialAudio* libQt6Sql* libQt6Test* libQt6PrintSupport* \
  libQt6Concurrent* libQt6Widgets* libQt6QuickControls2* libQt6QuickDialogs2* libQt6QuickTemplates2* libQt6Labs* \
  libQt6WebChannel* libQt6Xml* libQt6ShaderTools* libQt6QuickTest* libQt6VirtualKeyboard* libQt6MultimediaWidgets* \
  libQt6OpenGLWidgets* libQt6QuickWidgets* 2>/dev/null || true )

for p in platforms xcbglintegrations wayland-decoration-client wayland-graphics-integration-client \
         wayland-shell-integration multimedia imageformats tls networkinformation egldeviceintegrations; do
  [ -d "$QT/plugins/$p" ] && cp -a "$QT/plugins/$p" "$OUT/plugins/"
done
rm -f "$OUT/plugins/imageformats/libqpdf.so"

for m in QtQuick QtQml QtCore QtMultimedia QtWebSockets; do cp -a "$QT/qml/$m" "$OUT/qml/"; done
rm -rf "$OUT"/qml/QtQuick/{Controls,Dialogs,Templates,VirtualKeyboard,Scene2D,Scene3D,Pdf,NativeStyle} \
       "$OUT"/qml/QtQuick/Timeline* "$OUT/qml/QtQml/StateMachine"

# Qt ≥ 6.5 needs libxcb-cursor for X11, missing on some distributions
for f in /usr/lib/x86_64-linux-gnu/libxcb-cursor.so.0* /usr/lib/libxcb-cursor.so.0*; do [ -e "$f" ] && cp -a "$f" "$OUT/lib/"; done

cp "$HERE/core/target/release/borne" "$HERE/build/borne-ui" "$OUT/bin/"
printf '[Paths]\nPrefix=..\nLibraries=lib\nPlugins=plugins\nQmlImports=qml\n' > "$OUT/bin/qt.conf"
mkdir -p "$OUT/ui/i18n" && cp -a "$HERE/ui/Main.qml" "$HERE/ui/components" "$HERE/ui/imports" "$HERE/ui/themes" "$OUT/ui/"
for ts in "$HERE"/ui/i18n/*.ts; do "${LRELEASE:-lrelease}" -silent "$ts" -qm "$OUT/ui/i18n/$(basename "${ts%.ts}").qm"; done
cp -a "$HERE/resources/." "$OUT/resources/" 2>/dev/null || true
cp "$HERE/README.md" "$OUT/README.md" 2>/dev/null || true
cp -a "$HERE/examples" "$OUT/examples" 2>/dev/null || true

cat > "$OUT/borne" <<'SH'
#!/usr/bin/env bash
# Borne — entry point: the core starts its local API, then launches and supervises the QML UI.
here="$(dirname "$(readlink -f "$0")")"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland;xcb}"
exec "$here/bin/borne" "$@"
SH
chmod +x "$OUT/borne"

# Check: no missing dependency in the package.
# Libraries provided by any Linux graphical session (audio, GPU, X11/Wayland, fonts)
# are not bundled: they are only reported if missing on the build machine.
SYSTEM_LIBS='^(libpulse|libasound|libGL|libEGL|libGLX|libOpenGL|libvulkan|libva|libdrm|libgbm|libwayland|libxkbcommon|libX|libxcb|libfontconfig|libfreetype|libdbus-1|libglib-2|libgthread|libgobject|libgio)'
missing=$(find "$OUT/bin" "$OUT/lib" "$OUT/plugins" "$OUT/qml" -type f \( -name '*.so*' -o -name 'borne-*' -o -name 'borne' \) \
  -exec env LD_LIBRARY_PATH="$OUT/lib" ldd {} \; 2>/dev/null | grep 'not found' | awk '{print $1}' | sort -u || true)
system=$(echo "$missing" | grep -E "$SYSTEM_LIBS" || true)
real=$(echo "$missing" | grep -vE "$SYSTEM_LIBS" | grep . || true)
[ -n "$system" ] && echo "System libraries missing on the build machine (expected on the target): $(echo $system)"
if [ -n "$real" ]; then echo "Missing dependencies:"; echo "$real"; exit 1; fi
echo "Package ready: $OUT ($(du -sh "$OUT" | cut -f1))"
