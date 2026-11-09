# Borne

A couch-friendly, controller-driven launcher for retro and console games on Linux, connected to
[RomM](https://github.com/rommapp/romm). Borne brings together the library, downloads, emulators,
compatibility checks and multi-profile saves.

Specification: [`docs/SPEC.md`](docs/SPEC.md).

## Status

| Stage | Scope | Status |
|---|---|---|
| 0 | Prototypes and technical choices (Rust core + Qt/QML UI) | ✅ |
| **1** | **Foundation + RomM: pairing, catalog, covers, downloads** | ✅ |
| 2 | Profiles and saves: per-profile isolation, RomM sync, conflicts | planned |
| 3 | NES / Mega Drive emulators (isolated RetroArch): real launching | planned |
| 4 | GameCube / PS2 (Dolphin, PCSX2), then Switch (Eden) | planned |
| 5 | Compatibility, peripherals, polish, packaging | planned |

### What stage 1 does

- **First launch**: the RomM server address is typed with the gamepad on-screen keyboard and checked before it is saved.
- **Console-style profiles** ("Who's playing?"), each bound to a RomM account.
- **Keyboard-free pairing**: Borne shows a code and a QR code; you approve it from your phone in RomM,
  which creates a "Borne device". The token is stored outside the database (`secrets/`, 0600).
- **Catalog** synced (platforms, games, metadata, cached covers), browsable **offline**.
- **Downloads**: persistent queue, **resume after interruption** (Range requests), **SHA-1** verification
  (including archive contents), safe zip extraction, atomic install, live progress on the poster,
  cancellation, local deletion that never touches RomM.
- **UI**: grid and detailed view, systems bar, main menu, game menu, downloads panel, notifications,
  QML themes (Nocturne, Arcade, Cristal + user themes), English and French.

Since then:

- **Game page**: a game opens on its own page before anything is downloaded. Versions of the same game
  (regions, languages, revisions) are grouped into one entry; the page picks the version and the
  language the emulator starts in, both remembered per profile.
- **Play from the network** (Linux): instead of downloading, a game can be linked into the Borne
  virtual mount (`~/.local/share/borne/mount`). Only the games you pick appear there; their files
  are read from RomM on demand with the profile's token, through a bounded cache. No NFS export,
  no root. Settings → Games chooses what A does by default (download or network).
- **Mouse**: everything is clickable; the pointer appears when the mouse moves and hides when the
  gamepad is used. The wheel scrolls the library.
- **Console themes**: Horizon (cinematic home row), Mosaic (tile dashboard), Lumen (bright home with
  round shortcuts), Arcade (cabinet carousel), plus Nocturne and Cristal, each with its own UI sounds.

Launching games arrives with stage 3.

## Try it on a Mac (Apple Silicon)

1. On GitHub, open the [Actions](https://github.com/Lightmaster00/borne/actions) tab → latest successful
   build → *Artifacts* → `borne-macos-arm64`. Unzip until you get `Borne.app`.
2. The app is not signed with an Apple developer account: on first launch, right-click `Borne.app` →
   **Open**, or run `xattr -dr com.apple.quarantine Borne.app` in Terminal.
3. Enter the RomM server address (e.g. `http://192.168.1.20:8080`), create a profile, then approve
   the pairing from RomM (QR code or the code shown).

Data lives in `~/Library/Application Support/borne`.

## Architecture

```
borne (script)  →  bin/borne        Rust core: local HTTP + WebSocket API, RomM, SQLite database,
                                    downloads, gamepads; launches and supervises the UI
                   bin/borne-ui     minimal C++ launcher for the QML UI
                   ui/              QML UI (no business logic), translations in ui/i18n
                   lib/ plugins/ qml/   bundled Qt 6.8
```

The UI talks to the core only through the local API (`core/src/api.rs` documents every route):
a UI crash interrupts neither downloads nor sync, and the core restarts the UI.

Data: `~/.local/share/borne/` (`state.db`, `library/`, `media/covers/`, `secrets/`, `profiles/`, `themes/`,
`mount/` and `cache/stream/` for games played from the network). The virtual mount needs FUSE
(`fusermount3`, present on ChimeraOS and SteamOS).

## Controls

| Gamepad | Keyboard | Action |
|---|---|---|
| D-pad / stick | Arrows | Navigate |
| A | Enter | Open the game page / choose |
| B | Escape | Back |
| Y | Y or T | Game or profile options |
| X | X | Grid ↔ detailed view |
| LB / RB | Page Up / Page Down, Q / E | Previous / next system |
| Start | M or F1 | Menu (sync, downloads, theme, profile, server, diagnostics) |
| Select | F2 | Performance overlay |

In text fields, type directly on the keyboard; Enter confirms. With the mouse: click a game to open
it, click the hints at the bottom of the screen as buttons, right-click a profile for its options.

## Language

The UI follows the system language (English and French today). `BORNE_LANG=fr` or `BORNE_LANG=en`
forces one. English is the source language: wrap new strings in `qsTr("…")`, run
`scripts/i18n/update.sh`, add the translation to `ui/i18n/fr.json` (and plural forms to
`ui/i18n/en.json`), run the script again. CI fails if a translation is missing or `ui/i18n` is stale.

## Building

Requirements (Ubuntu 24.04): stable Rust, `cmake g++ qt6-base-dev qt6-declarative-dev qt6-l10n-tools libudev-dev libxcb-cursor0`.

```bash
# Qt 6.8 to bundle (extracted from the PySide6 wheels)
pip download --no-deps -d qt-wheels "pyside6-essentials==6.8.3" "pyside6-addons==6.8.3"
mkdir -p qt-ess qt-add qt
python3 -m zipfile -e qt-wheels/PySide6_Essentials-*.whl qt-ess
python3 -m zipfile -e qt-wheels/PySide6_Addons-*.whl qt-add
cp -a qt-ess/PySide6/Qt/. qt/ && cp -a qt-add/PySide6/Qt/. qt/

cargo test --release --manifest-path core/Cargo.toml                          # core unit tests
scripts/check-qml.sh qt-ess/PySide6                                            # syntax of every QML view
LRELEASE=/usr/lib/qt6/bin/lrelease scripts/package.sh "$PWD/qt" "$PWD/out/Borne"   # self-contained package
./out/Borne/borne
```

macOS: `scripts/package-macos.sh out-macos` (official Qt ≥ 6.9 via `QT_PREFIX`, or Homebrew Qt).

End-to-end tests against a real RomM: see [`scripts/romm-dev/`](scripts/romm-dev/README.md).

Useful variables: `BORNE_DATA_DIR` (data directory), `BORNE_LANG` (UI language), `BORNE_DEBUG_INPUT=1`
(gamepad action injection for automated tests), `BORNE_DEBUG_DL_KBPS` (download rate limit for tests).

## Themes

A theme is a folder in `~/.local/share/borne/themes/<id>/`: `theme.json` (with its `layout`: `grid`,
`list`, `shelf` or `carousel`), `Theme.qml` (inherits `ThemeBase` from the `Borne.Theme` module:
colors, fonts, tile sizes, home row, UI sounds…), and optionally `Card.qml` (custom poster or tile,
with the `CardStatus` state badge). Examples in [`examples/themes/`](examples/themes/) and the
built-in themes in [`ui/themes/`](ui/themes/). Bundled fonts: Inter, Poppins, Bebas Neue, Press Start 2P
(SIL Open Font License, see `ui/fonts/licenses`); UI sounds are synthesized by
`scripts/assets/make_sounds.py`.
An invalid theme is set aside with the reason shown; after two UI crashes, Borne restarts
in safe mode with the default theme.

## License

GPL-3.0-or-later. Qt is used under the LGPL (dynamic linking, replaceable libraries in `lib/`).
