# Borne

A couch-friendly, controller-driven launcher for your [RomM](https://github.com/rommapp/romm) game
library, on Linux (ChimeraOS, SteamOS or any desktop) and macOS. Pick a game with the gamepad, and
Borne downloads it (or plays it straight from the network), installs and configures the right
emulator, keeps each player's saves on RomM, and gets out of the way.

[![CI](https://github.com/Lightmaster00/borne/actions/workflows/ci.yml/badge.svg)](https://github.com/Lightmaster00/borne/actions/workflows/ci.yml)
[![Release](https://github.com/Lightmaster00/borne/actions/workflows/release.yml/badge.svg)](https://github.com/Lightmaster00/borne/actions/workflows/release.yml)

## Install

Downloads are on the [releases page](https://github.com/Lightmaster00/borne/releases): the latest
stable release, or the `dev` pre-release rebuilt on every change.

**Linux** (x86_64)

```bash
tar xzf Borne-linux-x86_64.tar.gz
./Borne/install.sh            # installs to ~/.local/opt/Borne, adds a menu entry and ~/.local/bin/borne
```

On ChimeraOS or SteamOS, add Borne to Steam as a non-Steam game to start it from the gamepad
interface. `./install.sh --uninstall` removes the program; your games, saves and settings stay in
`~/.local/share/borne`. Playing from the network needs FUSE (`fusermount3`, present on ChimeraOS
and SteamOS).

**macOS** (Apple Silicon)

Unzip `Borne-macos-arm64.zip` and move `Borne.app` to Applications. The app is not notarized: the
first time, right-click it → **Open** (or run `xattr -dr com.apple.quarantine /Applications/Borne.app`).
Data lives in `~/Library/Application Support/borne`.

**First start**: type your RomM server's address (e.g. `http://192.168.1.20:8080`) with the
on-screen keyboard, create a profile, then approve the pairing from RomM (QR code or the code shown),
or sign in with the account's password.

## Updates

Borne updates itself: Settings → Updates checks GitHub at startup and every 6 hours, and installs
only when you confirm, never during a game. It downloads **only the parts that changed** — the
programs, the interface, or the Qt runtime — and checks each against its SHA-256: a usual update
weighs about 5 MB instead of the whole 70 MB package. The previous version is kept next to the new
one. Two channels: **Stable** (tagged releases) and **Development** (the `dev` pre-release).

## What it does

- **Profiles** ("Who's playing?"), each bound to a RomM account; pairing without a keyboard (code or
  QR code approved from the phone). Tokens are kept outside the database, readable only by you.
- **Your library, offline too**: consoles, favourites and recently played, sorted by name (the first four
  letters, then the exact release date, so a series stands in order) or by play time, filtered by genre, searched as you
  type, in titles from every region.
- **Games as real cases**: 3D boxes in the shape of each console's retail case, rebuilt from the
  front, spine and back scans of ScreenScraper, cel shaded under clear plastic that reflects like
  glass; turn them with the right stick (or W A S D) to read the spine. Behind them, a video of the
  selected game; left alone, the library fades out and leaves the video.
- **Game page**: the trailer, the game's logo, the languages it really exists in (choosing one
  chooses the version), Play, favourite, and the game's own settings.
- **Downloads** with resume after interruption, SHA-1 checks, pause, cancel and a tidy list; or
  **play from the network** (Linux): only the games you pick are mounted, read from RomM on demand.
- **Emulators managed for you**: one per console, chosen in Settings → Emulators — RetroArch cores
  (Mesen, Snes9x, Genesis Plus GX, melonDS DS, SwanStation…), Dolphin, PCSX2, DuckStation, melonDS,
  Eden, Citron Neo and Ryubing (Switch), RPCS3 (PS3), shadPS4 (PS4), Xenia Canary (Xbox 360, Linux).
  Borne downloads each from its official source, configures it and keeps it up to date; you never
  open it. Select then Start quits a game.
- **Per-game settings**: another emulator for one game, its options (rewind, run-ahead, widescreen
  hacks, CPU overclock, Switch docked or handheld…), picture (shape, resolution, sharp, smooth or CRT
  pixels), cheats, language, cover.
- **Saves on RomM**, per profile: fetched before a game when newer, sent after it, replaced copies
  archived — for RetroArch, memory cards per game (Dolphin, PCSX2, DuckStation), Switch, PS3, PS4,
  Xbox 360 save folders. Profiles never share saves.
- **Cheats** from public databases (libretro, DeadSkullzJr's DS codes, Dolphin's codes,
  switch-cheats-db), or a `.pnach` you give for a PS2 game.
- **System files** (BIOS, keys, firmware) taken from RomM or given by you, checked and placed for
  each emulator; Borne never downloads them by itself.
- **Settings in plain words**: installation and saves, the interface (videos, size, animations,
  clock, sounds, buttons shown), the picture in games, emulators, system files, game images, RomM,
  updates, help (diagnostics report without any password or token).
- **English and French**, following the system (`BORNE_LANG=fr|en` forces one).

Borne talks to nothing but your RomM server, ScreenScraper (game images) and GitHub (its own updates
and the emulators' releases).

## Controls

| Gamepad | Keyboard | Action |
|---|---|---|
| D-pad / left stick | Arrows | Move |
| A | Enter | Open / choose |
| B | Escape | Back |
| X | X | Play |
| Y | Y, T, Ctrl+F or / | Search (on the profile screen: profile options) |
| — | Any letter or digit | Start a search with it |
| LB / RB | Page Up / Page Down, Q / E | Previous / next tab |
| LT / RT | R / C, Home / End | Previous / next letter |
| Right stick | W A S D (held) | Turn the selected case to see its spine |
| R3 | Tab | Downloads |
| Start | M or F1 | Settings |
| Select | F2 | Sort and filter |
| Select then Start | the emulator's own key (usually Esc) | Quit the game |

The hints on screen show the buttons of the device in use (or the one chosen in Settings →
Interface). Borne is played with a gamepad or a keyboard only: the mouse is ignored.

## Documentation

- [`docs/SPEC.md`](docs/SPEC.md) — functional and technical specification.
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) — building, testing, translating, releasing.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — what is left to do and to check.

## License

GPL-3.0-or-later. Qt is used under the LGPL (dynamic linking, replaceable libraries). Fonts:
Fredoka and Manrope (SIL Open Font License, `ui/fonts/licenses`).
