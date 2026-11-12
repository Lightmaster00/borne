# Developing Borne

Everything in the repository (code, comments, documentation, commit messages) is written in
English. The interface's source language is English too; French comes from `ui/i18n`.

## Layout

```
core/                 Rust core: local HTTP + WebSocket API (api.rs documents every route), RomM,
                      SQLite, downloads, sync, emulators, saves, cheats, media, updates
  src/emulators.json  emulators and RetroArch cores: sources, arguments, consoles
  src/systemfiles.json  BIOS, keys and firmware Borne recognizes
ui/
  Main.qml            the application: screens, input, calls to the core
  components/         views and pieces (library, game page, settings, 3D cases, shaders…)
  imports/Borne/Theme the look: colours, type, sizes, motion
  launcher/           minimal C++ launcher of the QML UI (borne-ui)
  i18n/               translations (.ts generated; edit en.json / fr.json)
  fonts/ sounds/      bundled assets
resources/            bundled with the package (app icon)
scripts/
  package.sh          self-contained Linux package (core + UI + Qt)
  package-macos.sh    Borne.app
  install-linux.sh    shipped as Borne/install.sh in the Linux archive
  release/            parts.py (package split for updates), manifest.py (latest.json, notes)
  check-qml.sh        qmllint on every view
  smoke-test.sh       a package starts and loads every view
  i18n/               translation refresh and fill
  ci/                 CI helpers
  romm-dev/           a development RomM with a generated test library
  gen-case-assets.py  grain.png and studio.hdr of the 3D cases
  assets/             UI sounds generator
tests/
  integration_romm.py end-to-end against a real RomM (pairing, sync, downloads, mount, settings…)
  ui_tour.sh          walks every screen of a running Borne, fails on any QML error
  update_test.sh      in-app updates: full archive, then by parts
docs/                 specification, this guide, roadmap
```

The UI never holds business logic: it talks to the core only through the local API, so a UI crash
interrupts neither downloads nor sync, and the core restarts the UI.

## Building

Linux (Ubuntu 24.04): stable Rust and
`cmake g++ qt6-base-dev qt6-declarative-dev qt6-l10n-tools libudev-dev libxcb-cursor0`.

```bash
# Qt 6.8 to bundle, from the PySide6 wheels
pip download --no-deps -d qt-wheels "pyside6-essentials==6.8.3" "pyside6-addons==6.8.3"
mkdir -p qt-ess qt-add qt
python3 -m zipfile -e qt-wheels/PySide6_Essentials-*.whl qt-ess
python3 -m zipfile -e qt-wheels/PySide6_Addons-*.whl qt-add
cp -a qt-ess/PySide6/Qt/. qt/ && cp -a qt-add/PySide6/Qt/. qt/

LRELEASE=/usr/lib/qt6/bin/lrelease scripts/package.sh "$PWD/qt" "$PWD/out/Borne"
./out/Borne/borne
```

macOS: `scripts/package-macos.sh out-macos`, with the official Qt ≥ 6.9 (`QT_PREFIX=<Qt>/6.9.3/macos`)
or Homebrew's.

A local build reports itself as build 0 and never updates itself.

## Checks and tests

```bash
cargo fmt --manifest-path core/Cargo.toml --check
cargo clippy --release --manifest-path core/Cargo.toml -- -D warnings
cargo test --release --manifest-path core/Cargo.toml
scripts/check-qml.sh qt-ess/PySide6
scripts/i18n/update.sh qt-ess/PySide6/lupdate        # fails if a string is untranslated
scripts/smoke-test.sh out/Borne/bin/borne            # BORNE_LANG=fr for French
tests/update_test.sh out/Borne
```

End to end, against the development RomM ([`scripts/romm-dev/`](../scripts/romm-dev/README.md)):

```bash
python3 tests/integration_romm.py core/target/release/borne http://127.0.0.1:8080 <admin> <password> <user> <password>
tests/ui_tour.sh <log of a running Borne started with BORNE_DEBUG_INPUT=1>
```

Useful variables: `BORNE_DATA_DIR` (data folder), `BORNE_LANG` (UI language),
`BORNE_DEBUG_INPUT=1` (`POST /api/v1/debug/pad?action=` and `/debug/stick?x=&y=` drive the UI),
`BORNE_DEBUG_DL_KBPS` (download rate limit), `BORNE_UPDATE_URL` (another release server).

## Translations

Wrap every visible string in `qsTr("…")`, run `scripts/i18n/update.sh`, add the French text to
`ui/i18n/fr.json` (plural forms in `en.json` and `fr.json` as `[singular, plural]`), run it again.
CI fails when a translation is missing or `ui/i18n` is stale. Core messages shown to the user are
translated by `ui/components/CoreText.js`.

## Continuous integration and releases

- **CI** (`.github/workflows/ci.yml`), on every pull request and branch: formatting, clippy, unit
  tests, QML syntax, translations, script syntax.
- **Release** (`.github/workflows/release.yml`): on every push to `main`, after the same checks,
  builds the Linux package and Borne.app, runs the startup tests (English, French) and the update
  test, splits each package into parts, and replaces the **`dev`** pre-release. A tag `vX.Y.Z`
  publishes a **stable** release instead.

To publish a stable version: set `version` in `core/Cargo.toml` (the tag must match), commit, then

```bash
git tag v0.2.0 && git push origin v0.2.0
```

Each release holds:

| File | Use |
|---|---|
| `Borne-linux-x86_64.tar.gz`, `Borne-macos-arm64.zip` | first install (`./Borne/install.sh` on Linux) |
| `Borne-<platform>-core.tar.gz` | the programs and the package's root files |
| `Borne-<platform>-ui.tar.gz` | views, fonts, sounds, translations, icon |
| `Borne-<platform>-runtime.tar.gz` | Qt libraries, plugins and QML modules |
| `latest.json` | read by the updater: version, build, notes, and per platform the full archive and each part (URL, size, SHA-256, `tree`) |
| `SHA256SUMS` | every file |

The updater (`core/src/update.rs`) hashes the installed package part by part (`tree`: SHA-256 over
the part's files sorted by path, with each file's SHA-256 and executable bit, or a link's target),
downloads only the parts whose hash differs, lays them over a copy of the installed package and
requires every part to match before swapping; anything unexpected falls back to the full archive.
`scripts/release/parts.py` computes the same hashes (CI checks both agree; `borne --part-hashes
<package>` prints the core's). Change the part rules in both places together.

ScreenScraper developer credentials come from the repository secrets `SCREENSCRAPER_DEV_ID` and
`SCREENSCRAPER_DEV_PASSWORD`, compiled masked into official builds (`core/build.rs`); they never
appear in the code or the logs.

## Conventions

- Rust: `cargo fmt` (`core/rustfmt.toml`) and clippy without warnings.
- QML: one component per file, no business logic, every string through `qsTr`, sizes and colours
  from `Borne.Theme`.
- Commits: an imperative summary line, then what changed and why.
