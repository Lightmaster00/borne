<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo-dark.svg">
    <img src="docs/assets/logo-light.svg" alt="Borne" height="56">
  </picture>
</h1>

A couch-friendly, controller-driven launcher for your [RomM](https://github.com/rommapp/romm) game
library, on Linux (ChimeraOS, SteamOS or any desktop), macOS and Windows. Pick a game with the gamepad, and
Borne downloads it (or plays it straight from the network), installs and configures the right
emulator, keeps each player's saves on RomM, and gets out of the way.

[![CI](https://github.com/Lightmaster00/borne/actions/workflows/ci.yml/badge.svg)](https://github.com/Lightmaster00/borne/actions/workflows/ci.yml)
[![Website](https://img.shields.io/badge/website-lightmaster00.github.io%2Fborne-E60012)](https://lightmaster00.github.io/borne/)
[![Release](https://github.com/Lightmaster00/borne/actions/workflows/release.yml/badge.svg)](https://github.com/Lightmaster00/borne/actions/workflows/release.yml)

## Install

Downloads are on the [releases page](https://github.com/Lightmaster00/borne/releases): the latest
stable release, or the `dev` pre-release rebuilt on every change.

**Linux** (x86_64)

```bash
tar xzf Borne-linux-x86_64.tar.gz
./Borne/install.sh            # installs to ~/.local/opt/Borne, adds a menu entry and ~/.local/bin/borne
```

`install.sh` also adds Borne to Steam as a non-Steam game, with its artwork: on ChimeraOS through
Chimera (it shows after the next Steam session start), elsewhere when Steam is closed (or later
from Settings → Help → Add to Steam). Emulators you already have are used — on the PATH, or
AppImages in `~/Applications` (EmuDeck's folder) — otherwise Borne installs its own in
`~/.local/share/borne/emulators`. `./install.sh --uninstall` removes the program; your games, saves and settings stay in
`~/.local/share/borne`. Playing from the network needs FUSE (`fusermount3`, present on ChimeraOS
and SteamOS).

**macOS** (Apple Silicon)

Unzip `Borne-macos-arm64.zip` and move `Borne.app` to Applications. The app is not notarized: the
first time, right-click it → **Open** (or run `xattr -dr com.apple.quarantine /Applications/Borne.app`).
Data lives in `~/Library/Application Support/borne`.

**Windows** (x86_64)

Unzip `Borne-windows-x86_64.zip` somewhere of your choice (it runs from its folder, there is no
installation) and start `Borne\borne.bat` — or make a shortcut to `Borne\bin\borne.exe` on the
desktop or in the Start menu. Borne is not signed: the first time, SmartScreen asks, then
**More info** → **Run anyway**. Emulators you already have are used if they are on the PATH,
otherwise Borne installs its own. Your games, saves and settings live in `%LOCALAPPDATA%\borne`.

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
- **A console's home, offline too**: over the selected game's art, the games you played lately
  in a row (the one selected large, its name under it), then your collections as folders:
  Favourites, Two players, one per console. A rail on the left for your profile, the Store,
  downloads and settings. "See all", a collection or a console opens a glass folder with its games,
  sorted by last played, newest, name, play time or release date; search (from the rail or Select)
  in titles from every region. B on the home goes back to the rail.
- **The Store**: your server's consoles as slanted cards in their colours, the one selected opening
  wide on a picture of the console; ordered by play time, number of games, release date, name, maker (then
  release or name) or your own order (LT / RT move a console).
- **A border in your console's colours**: the screen is framed in the colour of the console of the
  game you are on, Borne's lettering discreet in the top-left corner; a video of the selected game can play behind (off by
  default).
- **Game page**: its video playing behind (X, or a few seconds without a press, for full screen
  with its sound; X again to mute it); its case in 3D, turned with the right stick or W A S D; Play
  (or Install), the heart for your favourites, the game's own settings (Y) and its fact sheet
  (players' rating, your play time, studios, series, release, modes, age rating, languages, file,
  emulator, controller); its screenshots from RomM and ScreenScraper.
- **Each game its controller**: the version and the language, and the controller the console sees,
  per console or per game: a Switch Pro Controller, a pair of Joy-Con or the console in hand (the
  Pokémon Let's Go games get the console in hand, undocked, by themselves); a Wii Remote with its Nunchuk, alone, held
  sideways or a Classic Controller; a Wii U GamePad or Pro Controller. A map shows what each of your
  buttons (Xbox, PlayStation or Nintendo) does in the game, and every button can be changed.
- **Games made for an accessory** (a guitar, a Balance Board, PlayStation VR, Kinect, Joy-Con
  shaken…) are recognised by name and checked against what is plugged in: when it is missing, the
  game's page says so and Borne asks once before playing. Never a lock: Play anyway is remembered.
- **Developer mode** (Settings → Help): shows the technical settings (every emulator option, a
  console's own picture and controls, each controller button, the update channel, measurements),
  opens any emulator on its own interface with Borne's setup,
  gives it extra arguments, adds emulators of your own for any console. Borne copies an emulator's
  settings before opening it (Undo my changes), and turned off it plays as before.
- **Downloads** with resume after interruption, SHA-1 checks, pause, cancel and a tidy list; or
  **play from the network**: on Linux only the games you pick are mounted, read from RomM on demand;
  on macOS and Windows they are downloaded as temporary copies, the least recently played removed
  first past the cache size.
  Games stored as zip or 7z on RomM are extracted (arcade sets stay zipped), and downloaded rather
  than played from the network.
- **Your consoles, your choice**: after the first sync Borne asks which consoles of the RomM library it
  shows (Settings → Consoles → Choose to change it later); the others stay on RomM, and Borne installs
  no emulator for them. Borne looks at the machine it runs on (touch screen, mouse, motion-sensor pad,
  Wii Remote, Bluetooth, threads and memory, Steam Deck) and says beside each console, on its settings
  page and on each game's page what its games need that this machine lacks: the 3DS and DS touch
  screen, the Wii Remote and its sensor bar, Joy-Con-only Switch games, the Wii U GamePad's screen,
  or a computer too weak for the heaviest consoles.
- **Emulators managed for you**: one per console, chosen on each console's page (Settings → Consoles), kept up to date from Settings → Updates — RetroArch cores
  (Mesen, Snes9x, Genesis Plus GX, melonDS DS, SwanStation, Flycast, PPSSPP…), Dolphin, PCSX2, DuckStation,
  Azahar (3DS), Cemu (Wii U), Eden, Citron Neo and Ryubing (Switch), RPCS3 (PS3), shadPS4 (PS4), Xenia Canary
  (Xbox 360, Linux), Vita3K (PS Vita).
  Borne downloads each from its official source as soon as a console appears in your library,
  configures it (no first-run wizard, BIOS and keys put in place, fullscreen, the controller set for
  GameCube, Wii Remote and Nunchuk, PlayStation, Switch, 3DS…) and keeps it up to date; you never
  open it, and Borne sets each one's controller. A launch screen covers the passage to the
  emulator and back; Select + Start together pauses the game and asks whether to quit, and an
  emulator that cannot start the game is closed within a second, with the reason (read from its
  output and its own log).
- **Per-game settings**: another emulator for one game, its options (rewind, run-ahead, widescreen
  hacks, CPU overclock, Switch docked or handheld…), picture (shape, resolution, sharp, smooth or CRT
  pixels), controls for every emulator (which controller plays, A/B and X/Y swapped, what each
  button does), cheats, language, cover.
- **Saves on RomM**, per profile: fetched before a game when newer, sent after it, replaced copies
  archived — for RetroArch, memory cards per game (Dolphin, PCSX2, DuckStation), Switch, PS3, PS4,
  Xbox 360 save folders. Profiles never share saves.
- **Cheats** from public databases (libretro, matched by the game's title and region;
  DeadSkullzJr's DS codes, else libretro's; Dolphin's codes; switch-cheats-db), or a `.pnach` you
  give for a PS2 game.
- **System files** (BIOS, keys, firmware) taken from RomM or given by you, checked and placed for
  each emulator; Borne never downloads them by itself.
- **Two languages**: the interface in one (English, French, Spanish, Italian, German, Portuguese,
  Japanese, Chinese), the games in another if you like; any game can be set to its own.
- **Settings in plain words, only the useful ones**: installation and saves, the interface (videos,
  size, animations, clock, sounds), the picture in games, each console's emulator and system files,
  game images, RomM, updates of Borne and its emulators, help (diagnostics report without any
  password or token). The technical ones wait in developer mode.
- **English, French, Spanish, Italian, German, Portuguese, Japanese and Simplified Chinese**, following
  the system or chosen in Settings → Language (`BORNE_LANG=es` and so on forces one). Japanese and Chinese
  use the system's CJK fonts (on Linux, `noto-fonts-cjk`).

Borne talks to nothing but your RomM server, ScreenScraper (game images) and GitHub (its own updates
and the emulators' releases).

## Controls

| Gamepad | Keyboard | Action |
|---|---|---|
| D-pad / left stick | Arrows | Move |
| A | Enter | Open / choose |
| B | Escape | Back (from a folder or a game's page; on the home, to the rail) |
| X | X | In the Store, the console's next picture; on a game's page, its video |
| Y | T or Y | In a folder its order; on the home and the Store, the consoles' order; on a game's page, its settings |
| Select | F2, Ctrl+F or / | Search (on the profile screen, Y: profile options) |
| LB / RB | Page Up / Page Down, Q / E | Home / Store |
| LT / RT | R / C, Home / End | In a folder, previous / next group; in the Store, move the console selected |
| R3 | Tab | Downloads |
| Start | M or F1 | Settings |
| Select + Start, together | Escape | Pause and ask whether to quit (any emulator) |

The hints on screen show the buttons of the device in use (or the one chosen in Settings →
Screen and sound). Borne is played with a gamepad or a keyboard only: the mouse is ignored.

## Documentation

- [`docs/SPEC.md`](docs/SPEC.md) — functional and technical specification.
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) — building, testing, translating, releasing.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — what is left to do and to check.

## License

GPL-3.0-or-later. The Borne name, logo and pictogram (`ui/brand`) identify this project. Qt is used under the LGPL (dynamic linking, replaceable libraries). Fonts:
Bricolage Grotesque and Manrope (SIL Open Font License, `ui/fonts/licenses`).
