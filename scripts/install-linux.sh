#!/usr/bin/env bash
# Installs Borne for the current user, from the folder this script is in (the extracted
# release archive). Nothing needs root.
#
#   ./install.sh             install or move Borne to ~/.local/opt/Borne, add it to the
#                            applications menu and to ~/.local/bin
#   ./install.sh --uninstall remove the program, its menu entry and command (your games, saves
#                            and settings in ~/.local/share/borne stay)
#
# Borne updates itself from there (Settings → Updates): only the parts that changed are
# downloaded.
set -euo pipefail
SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DEST="${BORNE_INSTALL_DIR:-$HOME/.local/opt/Borne}"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
BIN="$HOME/.local/bin"

if [ "${1:-}" = "--uninstall" ]; then
  rm -rf "$DEST" "$(dirname "$DEST")/.borne-previous" "$APPS/borne.desktop" "$BIN/borne"
  echo "Borne removed. Your data stays in ${XDG_DATA_HOME:-$HOME/.local/share}/borne."
  exit 0
fi

[ -x "$SRC/bin/borne" ] || { echo "Run this script from the extracted Borne folder."; exit 1; }
if [ "$SRC" != "$DEST" ]; then
  mkdir -p "$(dirname "$DEST")"
  rm -rf "$DEST.new"
  cp -a "$SRC" "$DEST.new"
  rm -rf "$DEST"
  mv "$DEST.new" "$DEST"
fi

mkdir -p "$APPS" "$BIN"
ln -sf "$DEST/borne" "$BIN/borne"
cat > "$APPS/borne.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Borne
Comment=Your RomM game library, played from the couch
Exec=$DEST/borne
Icon=$DEST/resources/borne.png
Terminal=false
Categories=Game;Emulator;
DESKTOP
command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" >/dev/null 2>&1 || true

echo "Borne is installed in $DEST."
echo "Start it from your applications menu, or with: $BIN/borne"
echo "On ChimeraOS / SteamOS: in Steam, Add a Non-Steam Game → Borne, to start it from the gamepad interface."
