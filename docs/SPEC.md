# Borne — Functional and technical specification

Version 1.7 — November 2026

> This document describes the intended product. It is not proof of emulator compatibility, a legal
> review of licenses, or a promise that Borne works on every Linux machine.

## Scope at a glance

| Item | Decision |
|---|---|
| Platforms | Linux — any distribution meeting the documented dependencies; ChimeraOS is the reference platform. macOS builds exist for development and testing. |
| Local core | Rust |
| UI | Dedicated Qt 6 / QML application, separate process, client of the core's local API; one built-in look with a living background and trailers |
| Library backend | RomM, latest stable release — accounts, games, metadata, Device Sync |
| Profiles | Several people, several devices: RomM accounts bound to local profiles usable offline |
| V1 scope | NES, Mega Drive, GameCube, PS2 and Nintendo Switch (reference game: Zelda Tears of the Kingdom) |
| Next | Game Boy, GBA, Dreamcast, Wii (V1.x); PS3 experimental |
| Use | Personal use first; living-room Linux PC, gamepad-first navigation |
| UI languages | English (source), French |

## 0. Version history

| Version | Changes |
|---|---|
| 1.0 | Initial scoping (working name "GameHub"). |
| 1.1 | Rust core, RomM latest + Device Sync, hybrid emulator strategy (isolated RetroArch + standalone emulators), Flatpak first, ChimeraOS integration as a non-Steam game, "newest wins + archive" conflict policy, multi-person and multi-device profiles. V1 narrowed to NES/MD and GC/PS2, Nintendo Switch added with Zelda TotK as reference. Reference hardware. |
| 1.2 | Theme system and media handling (posters, ES-DE-style background trailers). |
| 1.3 | Dedicated Qt 6 / QML UI, separate from the Rust core (two processes linked by a local HTTP + WebSocket API). ES-DE dropped. Tauri + Nuxt, Electron and a custom native engine rejected (see 5.2). QML themes with guardrails; plugin section. |
| 1.4 | Project renamed **Borne**. Specification moved to English. Stage plan aligned with the repository. UI translated (English source, French). |
| 1.6 | Settings screen (install method with its trade-offs, network cache, updates, interface); in-app updates from GitHub releases with stable and development channels. |
| 1.7 | One built-in look, "Halo" (living background from the selected game's art, game boxes in space, glass panels, accent taken from the cover); user QML themes removed. Persistent log and shareable diagnostic report. Sturdier sync and downloads against slow or older RomM servers. |
| 1.5 | Game page before any download; versions of a game grouped, with per-profile version and emulator language; "play from the network" through the Borne virtual mount (FUSE, only chosen games, read from RomM); mouse control; console-inspired themes (home row, tile dashboard, bright home, cabinet carousel) with UI sounds. |

## 1. Executive summary

Borne is a Linux application that radically simplifies playing a game library managed by RomM. Turn on
the PC, browse the collection from the couch, download a game, launch it with the best available
emulator, and find the saves on another device after sync.

It replaces today's experience of several independent tools to configure. Borne orchestrates them and
presents one coherent flow, without trying to replace the emulators themselves.

Guiding principle: Borne automates as much as possible, explains the limits clearly, and always leaves
the final decision to the user. Compatibility checks inform and recommend; they are never an arbitrary lock.

### 1.1 Expected results

- A coherent, gamepad-driven library UI, usable from the ChimeraOS Steam session.
- A RomM connection to retrieve games, metadata, users and saves.
- On-demand downloads with local storage, resume after interruption and controlled deletion.
- Centralized emulator management: detection, guided or automated installation, configuration, proposed updates.
- A pre-launch check of requirements, with explicit warnings and the permanent option to launch anyway.
- Individual profiles for several people; only saves and session data are separated, everything else is shared.
- Save sync across devices (another Borne PC, Steam Deck, Android, browser) through RomM.
- Offline use for games already downloaded and profiles/saves already present locally.
- Zelda Tears of the Kingdom playable in good conditions on the reference hardware in V1.

### 1.2 Explicit non-goals

- Developing new emulators or guaranteeing that every game works perfectly.
- Providing ROMs, BIOS, keys, firmware or protected content (Switch emulators are downloaded from their projects' own release pages, as the user decided in Nov 2026).
- Replacing RomM as the source of truth for the library and user accounts.
- Building a proprietary cloud service or requiring Syncthing.
- Imposing a single hardware platform or Linux distribution.
- Adding unvalidated extras such as parental controls, social statistics or a store.

## 2. Product vision and user journey

### 2.1 Nominal journey

1. **Start**: on ChimeraOS, the user starts Borne from Steam (non-Steam game); elsewhere, from the desktop session or autostart.
2. **Profile**: the user picks their local profile, bound to a RomM account. Online, the profile is authenticated or re-paired; offline, the last authorized local profile stays usable.
3. **Library**: games, covers, systems and metadata come from the local cache and/or RomM.
4. **Local install**: if the game is not present, the user starts its download; the UI shows progress and allows resuming.
5. **Preparation**: Borne identifies the system, required files, available emulators, controllers and configuration profiles.
6. **Check**: a readable report lists satisfied, missing or unknown requirements and known issues. The user can continue despite warnings.
7. **Incoming sync**: if a newer save exists on RomM, it is fetched before launch; the replaced local version is archived.
8. **Launch**: Borne starts the chosen emulator with profile-specific configuration and paths, then follows the session.
9. **Exit**: Borne detects the end of the game, finalizes local operations and syncs with RomM when the network is available.

### 2.2 Experience principles

- The gamepad is the primary input; keyboard and mouse remain available for administration and troubleshooting.
- Long operations never block: download, extraction, verification, shader compilation and sync show their state and can be resumed.
- Messages explain the cause and propose a concrete action, not just an error code.
- Advanced settings stay reachable without cluttering the main flow.
- Launching anyway is always possible after a warning, unless technically impossible (missing file, non-executable binary, etc.).

## 3. Functional scope

### 3.1 Target systems

| System | Priority | Planned emulator | Design notes |
|---|---|---|---|
| NES | V1 — stage 3 | RetroArch (pinned core) | First complete end-to-end flow; .srm saves compatible with EmulatorJS and RetroArch Android. |
| Mega Drive / Genesis | V1 — stage 3 | RetroArch (pinned core) | ROM variants and common formats. |
| GameCube | V1 — stage 4 | Dolphin (standalone) | First 3D system; per-game and per-controller profiles; per-profile memory cards. |
| PlayStation 2 | V1 — stage 4 | PCSX2 (standalone) | User-provided BIOS; per-profile memory cards. |
| Nintendo Switch | V1 — stage 4 | Eden ("Yuzu family" adapter, Citron-compatible) | Reference game: Zelda TotK. Keys and firmware from the user's console; emulator binary provided by the user. See section 9. |
| Game Boy | V1.x | RetroArch | Battery saves and states depending on the emulator. |
| Game Boy Advance | V1.x | RetroArch | Standard controls; per-game profiles if needed. |
| Dreamcast | V1.x | Flycast | Graphics dependencies and BIOS to check. |
| Wii | V1.x | Dolphin | Wiimote / pointer controls handled as specific capabilities. |
| PlayStation 3 | Experimental | RPCS3 | CPU/GPU requirements, firmware and per-game compatibility vary widely. |

This list is the requested functional scope, not a promise that every system works on every machine.
The most demanding systems (Switch, PS3) have clearly separate support levels and requirements.

### 3.2 Reference hardware

| Component | Value |
|---|---|
| CPU | AMD Ryzen 9 3900X (12 cores / 24 threads, Zen 2) |
| GPU | AMD Radeon RX 6650 XT, 8 GB VRAM (RDNA 2) |
| Graphics driver | Mesa RADV (Vulkan), as shipped by ChimeraOS |
| OS | ChimeraOS (immutable, Steam / gamescope session) |
| Server | Self-hosted RomM on the homelab, latest stable release |

Performance acceptance criteria (TotK in particular) are evaluated on this hardware. Other configurations
are qualified through the matrix in section 13.

### 3.3 Peripherals

- Nintendo Switch Pro, Xbox and PlayStation controllers.
- Joy-Con (pair and separate controllers, if drivers and the input layer allow it).
- Wiimote and accessories as games require and adapters allow (from V1.x).

The input system detects devices, identifies their type where possible, checks their availability before
launch and applies a per-system or per-game mapping. Advanced features (gyro, pointer, motion controls,
USB/Bluetooth accessories) are never assumed: they are detected or reported as unverified.

### 3.4 Synced devices

| Device | Client | Expected save compatibility |
|---|---|---|
| Living-room PC (reference) | Borne | Reference. |
| Another Linux PC | Borne | Full, with identical emulator versions. |
| Steam Deck | Borne (game mode) or Ludo | Full with the same emulators. |
| Android / handheld | RomM client + RetroArch, Dolphin, Eden/Citron Android | Battery saves: yes with the same emulator. Save states: not guaranteed. |
| Browser | EmulatorJS built into RomM | NES/MD only (libretro .srm saves). No GC, PS2 or Switch. |

Rule: only battery / memory saves are considered portable between devices. Save states are synced but
flagged as tied to a specific emulator version.

## 4. Target architecture

### 4.1 Logical view

| Layer | Responsibility | Technical approach |
|---|---|---|
| UI | Library, game details, profile, states, warnings, settings. | Dedicated Qt 6 / QML application, separate process, client of the local API. |
| Borne core | Orchestration, rules, local library state, events. | Local Rust service independent of the UI. |
| RomM connector | Authentication, catalog, metadata, downloads, device sync. | RomM REST API and official Device Sync protocol. |
| Library & cache | Local ROM files, extraction, hashes, download state, shader cache. | Filesystem + SQLite for the local index. |
| Emulator manager | Detection, installation, versions, configuration, launch. | Adapters per emulator (RetroArch, Dolphin, PCSX2, Yuzu family) and per installation method. |
| Compatibility engine | Requirements, peripherals, profiles, warnings and reports. | Versioned declarative rules + test base. |
| Profile & save manager | Save separation and per-account sync. | Local profile + RomM account + isolated save directories. |
| Session integration | Steam / gamescope session, autostart, return to the UI. | Non-Steam entry, dedicated Steam Input layout. |

### 4.2 Process architecture

A local core independent of the UI exposes a documented local API (HTTP on loopback with a random
token), runs background tasks and drives the emulators. The UI holds no critical business logic, so it
can evolve or be replaced without rewriting the orchestration. Core and UI are two processes: a UI crash
interrupts neither the running game, downloads nor sync, and the core restarts the UI (safe mode after
repeated crashes); a core outage shows a "reconnecting" state in the UI. A `borne` CLI (launch, status,
sync) is planned for third-party frontends and troubleshooting.

### 4.3 Technologies

| Component | Choice | Rationale |
|---|---|---|
| Local core | Rust (tiny_http, tungstenite, rusqlite, ureq, gilrs) | Robust process management, single binary, good Linux support. |
| UI | Qt 6.8 LTS (pinned), Qt Quick / QML, Qt Multimedia (FFmpeg), QtWebSockets; small C++ launcher | Native GPU rendering, identical on every distribution (bundled Qt), light on memory, FFmpeg video with VA-API. Validated by the stage 0 prototype. |
| Core ↔ UI link | Local HTTP + WebSocket API (127.0.0.1, token) | No Rust ↔ Qt code binding (cxx-qt rejected): versioned contract, isolated crashes, independent builds. |
| Gamepads | Read by the core (gilrs) and relayed to the UI over WebSocket | Qt 6 no longer has a gamepad module; the core is the single source. |
| Local database | SQLite | State, local profiles, tasks, index and operation log. |
| Emulator installation | Flatpak first; user-provided binary for Switch | Works on an immutable system. |
| Borne packaging | Self-contained bundle with Qt today; Flatpak (KDE runtime) and AppImage to validate | Do not assume a single format covers everything. |
| Translations | Qt Linguist (`qsTr`, `.ts` → `.qm`), English source | The UI follows the system language; `BORNE_LANG` overrides it. |

### 4.4 Flow

| Actor | Main flow |
|---|---|
| UI | Asks the core for catalog state, the active profile and user actions. |
| Borne core | Coordinates RomM, local cache, compatibility, emulators and saves. |
| RomM | Remote source of users, ROMs, metadata and saves. |
| Local storage | Downloaded ROMs, shared configuration, shader caches and per-profile saves. |
| Emulators | Started as external processes with prepared arguments, variables and paths. |

## 5. Dedicated UI and extensibility

### 5.1 Decision

Borne has its own UI, designed for this specification: remote RomM catalog, games available but not
downloaded, downloads, profiles, save conflicts, compatibility reports. It is a native Qt 6 / QML
application, client of the Rust core's local API. ES-DE is not used, neither as a base nor as an alternative frontend.

### 5.2 Rejected alternatives

| Option | Reason |
|---|---|
| ES-DE (as is, as a companion, or forked) | Built around local files (folders, gamelist.xml): a remote catalog, profiles and downloads would require changing its C++ data model and merging every upstream release. |
| Tauri + Nuxt | Working prototype, but rendering depends on WebKitGTK (varies across distributions, fragile under gamescope); video and user stylesheets impossible through asset://. |
| Electron + Nuxt | Reliable rendering (Chromium) but heavy on memory, Chromium to keep updated in every release, VA-API off by default. |
| Custom native engine (Rust + wgpu/OpenGL, ES-DE style) | Months of engine work (text, layout, video, input, on-screen keyboard) before any Borne feature. Still possible later thanks to the local API. |
| Godot, Flutter, Slint | Limited video (Godot), weak gamepad support on Linux (Flutter), young ecosystem without a video player (Slint). |

### 5.3 UI architecture

- Small C++ launcher (QQmlApplicationEngine); everything else in QML. No business logic in the UI.
- Communication: HTTP requests to the local API, events pushed over WebSocket (progress, gamepads, sync, catalog changes).
- API version negotiation at startup; UI and core cleanly refuse an incompatible version.
- Virtualized native views (GridView, ListView): only visible items are instantiated.
- Game mode: during a session the UI hides its window, releases video and textures and stops rendering, leaving VRAM to the emulator (critical for the Switch with 8 GB).
- Automatic UI restart by the core or by Steam after a crash.

### 5.4 Look

Since v1.7 Borne has one look, "Halo", instead of interchangeable themes: several themes spread the
effort thin, and a user QML theme is code that runs with the UI's rights.

- Background by default: a video of the selected game being played. When the selection rests
  (0.9 s), `POST /api/v1/games/{id}/gameplay` returns a local file: ScreenScraper's gameplay capture
  (`video-normalized`, else `video`; its address is noted without credentials during the media fetch
  and downloaded on first use, credentials added only for that request, ScreenScraper hosts only),
  else RomM's trailer. Stored in `media/videos` with the trailers (pruned beyond 2 GB). Played muted,
  looping, cropped to fill, darkened by half with a deeper bottom for the text; it fades in on its
  first frames and stays off with trailers off (and in safe mode), on the game page and in menus.
  Until it plays, or when the game has no video, the pixel mosaic below shows.
- Pixel mosaic, Borne's identity: the selected game's cover decoded at one pixel per 56-unit
  tile and drawn unsmoothed as a wall of large dark pixels, re-colouring tile by tile (each tile flashes
  at its own moment) when the selection settles, a slow diagonal light wave across it, a dark glossy
  floor under the cases. Other styles (Settings: the game's art — RomM fanart, else a screenshot, else the
  cover — drifting and cross-fading; a game room — wall, neon tinted by the game, wooden shelf, dust;
  moving light — beams, veils, particles). Former default: a sober dark stage (vertical graphite gradient, a soft light tinted by the selected game's
  accent behind the shelf, breathing slowly, and a vignette). No art or video behind the library: the
  cases carry the color.
- Library: the selected game's platform, title and states, and the games as physical cases standing on
  the stage below (cover inset under a plastic rim with gloss, spines with the system's color band and the
  title, a contact shadow, a faint floor reflection; the case follows the cover's aspect ratio). The
  selected box faces the camera, a little forward, swaying gently; the others turn toward it and recede.
  Rendered in real 3D with Qt Quick 3D (`Shelf3D`, `Case3D`): each case is a lit solid (shell,
  printed front under a clear sleeve, spine on the left, plain opening edge on the right, back) with a
  key light casting soft shadows on a glossy floor that fades out, a fill and a rim light. Only the 13
  cases around the selection exist. Fallback: the earlier 2D drawing (`BoxShelf`, six flat faces
  through one perspective matrix), used when Qt Quick 3D cannot load or when chosen in Settings →
  Interface → Game cases (3D / Flat); `ShelfView` picks one and forwards the same properties. A letter index; LT / RT jump between letters and show the letter
  large for a moment. Y opens the search: on-screen keyboard (or the physical keyboard, where typing any
  letter starts a search), up to six results ranked by title prefix, word prefix then substring, and the
  shelf follows the highlighted result. The catalog rarely changes, so there is no "featured" slot.
  Alternative home: an arcade room of cabinets (Settings → Interface → Home).
- Game page: the trailer across the top (muted, sound on request; RomM's `path_video`, a path under
  `/assets/romm/resources/`, downloaded by the core with the profile's token through
  `POST /api/v1/games/{id}/trailer`, cached in `media/videos` and pruned beyond 2 GB; when the shown
  version has none, another version of the same game is used; without a trailer the case stands on the
  right), then the choices and an introduction,
  the studios and series (RomM only), and the screenshots from RomM (fetched through the core with the profile's token).
- Accent: the cover's dominant hue, lifted to a light tone, colors the eyebrow text, the systems underline,
  halos and the language marks. Panels are glass (translucent white, fine edge).
- Type: Manrope (static Regular to ExtraBold instances). The scene keeps a 1080-unit height (or 1600
  units of width on narrow screens) and widens with the window, so 16:10, 21:9, 4:3 and 4K fill the screen.
- Safe mode: repeated UI crashes restart Borne with trailers and sounds off.

### 5.4.1 Game page and input

- A game opens on its own page before anything is downloaded: details, state, actions (download, play from
  the network, play, delete…), version chips (region, languages, revision), emulator language chips
  (Automatic follows the UI language), summary. Choices are stored per profile.
- Everything works with the gamepad (focus rings, row/column navigation) and with the mouse (hover and press
  states, clickable hints, back button, wheel scrolling). The pointer shows when the mouse moves and hides
  after a few seconds or as soon as a gamepad or the keyboard is used.
- Original synthesized UI sounds; bundled OFL font.

### 5.5 Media and trailers

- Managed media: poster/cover, background (fanart), game logo, screenshots, video trailer.
- Source: RomM metadata first; otherwise ScreenScraper with the user's account.
- Local cache shared between profiles, served to the UI through the local API.
- Trailer: starts muted about 1.5 s after stopping on a game, fades in, loops, stops immediately on movement, pauses and releases when a game launches. Volume configurable per theme and per profile.
- A single video decoded at a time; no preloading while scrolling; "disable trailers" option.
- Playback through Qt Multimedia (FFmpeg backend) with VA-API hardware decoding; target cache format H.264 or VP9, 720p maximum.

### 5.6 Extensions (plugins)

| Type | Form | Rules |
|---|---|---|
| UI extensions | QML modules (screen, widget, layout) | Same versioned API and isolation as themes; never a native module compiled against Qt (breaks with each release). |
| Emulators and systems | Declarative manifests read by the core (detection, installation, arguments, paths, per-game profiles) | Versioned and validated format; adding an emulator without recompiling Borne. |
| Metadata sources, compatibility rules | Manifests or external programs talking to the local API | Run outside the core, with consent; no extension ever receives RomM tokens. |

### 5.7 Ludo

Ludo (RomM client in Python + Electron, GPL-3.0) is a reference for the RomM and Eden integration; no code
reuse is planned. Any reuse would require a GPL-3.0-compatible license (Borne is GPL-3.0-or-later).

## 6. RomM integration

### 6.1 Role of RomM

RomM remains the remote source of truth for accounts, permissions, library, metadata and synced saves.
The target is the latest stable release; Borne declares a minimum supported version and cleanly refuses
an older one. Development and tests run against RomM 5.4.1.

### 6.2 Authentication and profile pairing

- The user binds a local profile to a RomM account through RomM's device pairing flow: Borne shows a code and a QR code, the user approves it from a phone in RomM.
- Tokens are stored outside the database (`secrets/`, files 0600 in a 0700 directory); the system secret store will be used when available.
- Borne never asks for the RomM password and never stores a secret in plain text in SQLite.
- A local profile stays usable offline after a first successful pairing.
- Each Borne profile on each machine is registered as a distinct RomM device.

### 6.3 Save sync

Use RomM's official Device Sync protocol rather than a custom sync.

- Sync before launch (fetch a newer remote version) and when the game exits.
- Never sync a file still open or being written by an emulator.
- Compute hashes and keep a sync state per profile, device, game and slot.
- Automatically retry idempotent operations after a network outage.
- Show clear states: up to date, pending, offline, conflict resolved, failed, authentication expired.

### 6.4 Conflict policy

By default the newest version wins; the other version is always archived and can be restored from the UI.

- "Newest" is determined by the RomM server timestamp and hash history, never by the local clock alone (clocks drift between devices).
- If the order cannot be established reliably, Borne keeps both versions and asks the user.
- Archives are kept per profile, game and slot, with origin device and date; configurable retention (default: 10 versions).
- A non-blocking notification reports every automatically resolved conflict.

### 6.5 Offline limits

Offline, Borne cannot guarantee that the remote account was not disabled, that permissions did not change,
or that a newer save does not exist on the server. It allows local access based on the last valid pairing,
reports the offline state and syncs on reconnection according to section 6.4.

### 6.6 Library and downloads

- Local cached catalog with stable RomM identifiers, systems, names, covers and local presence state.
- On-demand downloads with resume, size/hash verification and error handling.
- Archives and safe extraction: paths validated against path traversal.
- Locally installed game: no needless re-download; detection of missing or modified files.
- Switch updates and DLC handled as content attached to the base game.
- Local deletion is separate from remote deletion in RomM; clear confirmation, never any confusion between the two.
- Versions of the same game (regions, languages, revisions) are grouped into one library entry, keyed by the
  metadata id RomM matched (RomM's own "sibling" identity) or by the file name without tags. The version shown
  is the profile's choice, then an installed one, then the best match for the UI language.

### 6.7 Playing from the network (Borne virtual mount)

Instead of downloading, a game can be *linked*: it appears, alone, in `<data>/mount/<platform>/<rom_id>/`, a
read-only FUSE filesystem owned by the user (no root, no NFS export). Only linked games are exposed; the rest
of the catalog never is. Files are read from RomM on demand with Range requests and the active profile's
token, so RomM's per-account permissions apply, through a bounded cache of 4 MiB blocks (default 20 GB,
least recently read evicted first). Unlinking removes the game and its cached blocks. A setting chooses the
default action of a game page (download or network). Linux only (FUSE); macOS builds report it unavailable.
Offline, linked games are unavailable unless their blocks are cached.

## 7. Profiles and data separation

### 7.1 Model

Hybrid model for several people and devices: each Borne profile is a local profile bound to a RomM account.
The RomM account provides identity and remote scope; the local profile provides offline continuity.

| Data | Sharing | Rule |
|---|---|---|
| Library / metadata | Shared | Common catalog, RomM permissions respected. |
| Downloaded ROMs | Shared | A single local game cache. |
| Emulators and BIOS | Shared | Common installs; BIOS/firmware/keys provided by the user. |
| System configuration | Shared | Common defaults, documented per-game overrides. |
| Media (posters, trailers) | Shared | Common cache, manual purge. |
| Themes and extensions | Shared | Installed once; theme chosen per profile. |
| Shader caches | Shared | Non-personal technical data; kept across sessions and updates. |
| Battery saves / memory cards / Switch saves | Per profile | Separate paths; no leak between profiles. |
| Save states | Per profile | Strict separation; warn about portability across emulator versions. |
| Local history / conflict archives | Per profile | Minimal necessary data. |
| RomM tokens | Per profile | Isolated secrets; independent revocation and re-pairing. |

### 7.2 Switching profiles

- Profiles are switched from the home screen, never while a game is running.
- If a game is running, Borne asks for a clean exit or cancels the switch.
- Before switching, finish writing saves, then sync if the network is available.
- Activate the next profile and mount its isolated save paths; an emulator must never write into the previous profile's directory.

### 7.3 Local layout

`~/.local/share/borne/` with `state.db`, `library/` (shared ROMs), `media/` (shared covers and trailers),
`secrets/`, `themes/`, `shaders/` (shared caches), `profiles/<id>/saves/`, `profiles/<id>/states/`,
`profiles/<id>/archive/` and `config/`. Paths follow XDG and are exposed to Flatpak emulators through
`flatpak override --filesystem`, limited to these folders.

## 8. Centralized emulator management

> Implemented: `core/src/emulators.json` lists the programs (official source per system, command
> line) and, per console, the emulators offered (RetroArch cores or standalone programs; the first
> is the default). The user picks one per console (`POST /api/v1/consoles/<slug>/emulator`);
> `core/src/emuinstall.rs` downloads it into `emulators/<id>/<version>/` (GitHub release assets
> checked against their published SHA-256, RetroArch from the libretro buildbot with cores one by
> one, Dolphin's macOS image from its download page, Flathub on Linux where that is the only
> source), unpacks .zip/.7z/.tar.xz/.dmg, extracts AppImages once (no FUSE), replaces the old
> version only when the new one is complete, and checks for updates every 6 hours (installed when
> no game runs; Settings → Emulators → Emulator updates). *Play* installs what is missing then
> starts the game. RetroArch runs with Borne's own `--config` (fullscreen, no menu, no on-screen
> messages, no hotkeys, profile saves and states, Borne's cores and BIOS folders); Dolphin with
> its own user folder per profile (`-u`). Sessions: one at a time, own process group, output in
> `reports/emulator.log`, `session` events. Sources also include Forgejo (Eden) and GitLab
> (Ryubing) releases. Switch: Eden, Citron Neo, Ryubing; PS3: RPCS3; PS4: shadPS4; Xbox 360: Xenia
> Canary (Linux only); Xbox One: no usable emulator exists, the console is listed as unsupported.

### 8.1 Hybrid strategy

| Emulator | Systems | Integration rules |
|---|---|---|
| RetroArch | NES, MD (V1); GB, GBA (V1.x) | Started with an isolated configuration (Borne's own `--config` + per-profile `--appendconfig` forcing the saves/states folders). Pinned core versions; a core update is an explicit action with a warning about save states. Menu and hotkeys aligned with Borne's mapping. Changes made in the RetroArch menu must not overwrite Borne's configuration. |
| Dolphin | GameCube (V1); Wii (V1.x) | Per-profile user directory (`-u`) or redirected memory cards / GCI; shared configuration read-only. |
| PCSX2 | PS2 (V1) | Per-profile memory cards; shared user-provided BIOS. |
| Eden (Yuzu family) | Switch (V1) | See section 9. Common Eden/Citron adapter. |
| Flycast, RPCS3 | Dreamcast, PS3 | Outside V1. |

### 8.2 Required functions

- Detect installed emulators, their versions, paths, installation methods and capabilities.
- Install, or offer to install, a missing component with the supported method (Flatpak first).
- Configure ROM, BIOS, firmware, key, controller and save paths.
- Manage per-system profiles and per-game overrides without overwriting the user's settings.
- Check for updates, show the changes and allow postponing or refusing an update.
- Keep the previous version or a rollback procedure when the installation method allows it.
- Start emulators as separate processes, collect their exit code and detect abnormal exits.

### 8.3 Semi-automatic maintenance

| Action | Expected behavior |
|---|---|
| Detection | Automatic at startup and on demand. |
| Missing install | Automatic through Flatpak when available; otherwise a wizard with precise instructions. Switch: user-provided binary. |
| Standard configuration | Automatic and reversible. |
| Update | Automatic detection, installation after approval. |
| Specific version | Ability to pin a version (`flatpak update --commit`, AppImage kept). |
| Failure | Never overwrite the existing configuration; provide logs and rollback. |

### 8.4 Multi-distribution

Do not assume Flatpak, AppImage or a package manager is present everywhere. Adapter system: Flatpak
(preferred), AppImage, native packages, manual installation. Borne detects the real capabilities and
explains the limits. It never runs privileged commands silently.

### 8.5 ChimeraOS and Steam integration

- Borne is added to Steam as a non-Steam game (guided or automatic, with consent) and runs under gamescope.
- Emulators are started as child processes of Borne and inherit Borne's Steam Input layout.
- A "raw gamepad" Steam Input layout is provided and recommended, so Borne and the emulators handle mapping.
- Gyro, separate Joy-Con and Wiimote are tested specifically under Steam Input.
- Returning to the UI is guaranteed when the emulator exits, including after a crash.

## 9. Nintendo Switch

### 9.1 Context

Switch emulation is unstable legally and project-wise: several emulators were discontinued or targeted by
takedown requests. Only a few forks of the Yuzu line (Eden, Citron) are actively developed at the time of
writing. Borne must therefore stay independent of any specific project or distribution source.

### 9.2 Rules

- No hard-coded Switch emulator download source; the user provides the binary (AppImage or local Flatpak), Borne detects its version and capabilities.
- A "Yuzu family" adapter shared by Eden and Citron (`keys/`, `nand/`, `load/`, `sdmc/`, `shader/` tree).
- Keys (`prod.keys`, `title.keys`) and firmware come from the user's console; Borne checks their presence and consistency, never provides or syncs them.
- Per-profile saves: a separate `nand/user/save` folder per Borne profile, mounted at launch.
- Shader caches shared between profiles, kept across emulator updates.
- Mods (`load/<titleid>/`) managed per game, toggleable, without touching global settings.

### 9.3 Reference profile: Zelda Tears of the Kingdom

| Setting | Proposed default |
|---|---|
| Graphics API | Vulkan (RADV) |
| Resolution | 1x (native) by default; 2x offered when performance allows |
| ASTC textures | GPU decoding + recompression enabled (limits use of the 8 GB of VRAM) |
| GPU accuracy | Normal |
| Shader cache | Persistent, shared |
| Mods (60 fps, dynamic resolution) | Off by default, opt-in per game profile |

Acceptance criterion: the game starts from Borne with a gamepad and plays at a stable 30 fps during regular
exploration on the reference hardware once the shader cache is built, with per-profile saves synced
through RomM. These values are starting points to validate in stage 4.

### 9.4 Specific pre-launch checks

- Keys present and readable; installed firmware version compatible with the emulator version.
- Game version and installed updates.
- Available VRAM versus the chosen profile (warning, not a block).
- Compatible gamepad and Pro Controller mapping applied.

## 10. Compatibility engine and launch policy

### 10.1 Goal

The compatibility engine helps the user understand whether the technical requirements seem met. It never
blocks a launch just because a game was not tested or a community database rates it as uncertain.

### 10.2 Status levels

| Status | Meaning | UI action |
|---|---|---|
| Requirements met | Known, verifiable items are present. | Normal launch; remind that this does not guarantee the result. |
| Documented compatibility | A profile or known report exists for this game / emulator. | Show the profile's source, version and date. |
| Unverified | Not enough evidence; no automatic block. | Neutral warning, launch button available. |
| Known issue | A limitation or required peripheral is identified. | Detailed warning + ways to fix + launch anyway. |
| Missing requirement | Required BIOS, firmware, keys, file, peripheral or version is missing. | Explain what is missing; allow launching anyway if technically possible. |
| Technically impossible | Missing binary, unreadable file, incompatible architecture. | Explain why; offer a fix. |

### 10.3 Pre-launch checks

- Emulator present, executable, known version and compatible architecture.
- Game files present, readable, extraction finished.
- Required BIOS/firmware/keys: presence and, when possible, expected hash, without distributing the content.
- Expected peripherals and consistent mapping.
- Per-game configuration valid and compatible with the emulator version.
- Known minimum resources: CPU, GPU, VRAM, RAM, graphics API, drivers.
- Newer remote save fetched or conflict handled (section 6.4).

### 10.4 Special cases

| Case | Expected checks |
|---|---|
| Zelda TotK | Keys, firmware, game version, ASTC profile, VRAM, shader cache. |
| Pokémon Let's Go | Specific controls (motion); report if unconfirmed. |
| Guitar Hero | Detect guitar/adapter; warn if hardware is missing. |
| Wii | Detect a Wiimote or emulated configuration; check pointer/motion. |
| PS3 | Warn about high requirements, firmware and the title's compatibility status. |

Mandatory rule: every warning offers "Launch anyway" when execution is still technically possible. This is
available to every profile; the user then accepts the risk of malfunction.

### 10.5 Transparent results

Each report states what was actually checked, what is inferred, what is unknown, the emulator version, and
the date and source of a compatibility profile. Never show "100% compatible" based only on met requirements.

## 11. Offline mode and cache

### 11.1 Full offline mode for local content

- Games already downloaded stay visible and launchable.
- Cached metadata and covers stay browsable.
- Already-paired local profiles stay selectable; local saves stay accessible.
- Sync operations are queued and resume on reconnection.
- A new RomM account cannot be validated without access to the server.

### 11.2 Cache management

On-demand downloads, local storage and manual deletion by default. Minimum states: "available on RomM",
"downloading", "available locally", "verification required", "file missing/corrupted". Local deletion
never deletes the game on the server.

### 11.3 Download robustness

- Interrupted downloads resume; temporary file, then atomic rename after validation.
- Safe extraction and estimated disk space (Switch games often exceed 15 GB).
- Duplicate prevention and detection of orphaned local files.
- Explicit manual cleanup; any future automatic deletion will be opt-in.

### 11.4 Updating Borne

- Settings → Updates shows the installed version and build, the channel (Stable: releases tagged `vX.Y.Z`;
  Development: the `dev` pre-release rebuilt on every change of `main`) and automatic checks (startup, then
  every 6 hours; never an automatic install).
- CI publishes, per release, the Linux and macOS archives, `SHA256SUMS` and `latest.json` (version, build
  number, notes, URL / size / SHA-256 per platform). Builds are ordered by their CI build number.
- Installing: download, SHA-256 check, extraction next to the installed package, then on confirmation an
  atomic swap of the package folder (the previous one kept as `.borne-previous`, restored if the swap fails)
  and a restart on the new core. Locally built, Flatpak and read-only installs report why they cannot update.

## 12. Security, integrity and data protection

- RomM tokens protected, never in logs, URLs or plain-text configuration files.
- Minimal permissions on profile files and saves; strict separation between profiles.
- Archive paths and file names validated.
- Emulator Flatpak permissions limited to the Borne folders they need.
- No untrusted script run without consent; no silent root command.
- Sensitive operations logged without exposing secrets.
- Saves preserved on conflict, sync error or abrupt exit.
- Export of the local configuration, excluding protected content.

### 12.1 Rights and content

Borne manages and launches content provided by the user. It does not distribute games, BIOS, firmware,
keys or Switch emulators. Users remain responsible for their content and applicable law. The licenses of
emulators and any reused code (Qt, Ludo) are reviewed individually.

## 13. Linux compatibility and distribution

### 13.1 Portability goal

Borne targets every Linux distribution able to meet the documented dependencies, without claiming untested
universal compatibility. ChimeraOS on the reference hardware is the first validated target.

### 13.2 Minimum validation matrix

| Axis | Cases to test |
|---|---|
| Distributions | ChimeraOS (reference), SteamOS (Steam Deck), a Debian/Ubuntu base, Fedora, Arch. |
| Session | Steam / gamescope session, Wayland and X11; full screen and return to the UI. |
| GPU | AMD (reference: RX 6650 XT), Intel and NVIDIA, with detected drivers. |
| Installation | Flatpak, AppImage, native packages depending on the distribution. |
| Gamepads | Bluetooth and USB: Switch Pro, Xbox, PlayStation; Joy-Con; through Steam Input and outside Steam. |
| Storage | Local SSD, secondary volumes, paths with spaces. |
| Network | RomM connection, network loss during download, resume and offline mode. |

### 13.3 Immutable gaming distributions

ChimeraOS and SteamOS have a read-only system and atomic updates: no classic package manager. Flatpak and
AppImage are the only installation methods to assume; every dependency must be bundled.

## 14. Local data model and interfaces

### 14.1 Minimum local entities

| Entity | Indicative fields / role |
|---|---|
| Profile | Local id, name, RomM user, pairing state, last access, offline settings. |
| Device | RomM device id, name, registration date. |
| SecretRef | Reference to the stored secret; never a plain-text token value in the database. |
| Game | RomM ROM id, system, name, metadata, local path, hash, state, attached content (updates/DLC). |
| DownloadTask | Game, source, progress, temporary file, status, error. |
| Emulator | Identifier, family, path, version, installation source, pinned version, capabilities. |
| EmulatorProfile | System/game, emulator, core, settings, active mods, schema version. |
| CompatibilityReport | Game, emulator, machine, requirements, status, source, date, version. |
| SaveSyncState | Profile, game, slot, local/remote hash, server timestamp, origin device. |
| SaveArchive | Profile, game, slot, archived version, device, date, reason (conflict, replacement). |
| OperationLog | Type, date, result, technical message with secrets removed. |

### 14.2 Local API

The local contract exposes at least: system state, profiles, catalog, downloads, progress, local presence,
requirement report, emulator choice, launch/stop, sync, save archives, logs and settings. Long actions
return a task identifier and publish progress events. The same API is used by the UI and the CLI.
`core/src/api.rs` documents the current routes.

### 14.3 Observability

- Structured logs with debug/info/warning/error levels.
- Export of a diagnostics report with secrets removed.
- Correlation identifier from the UI to the service and the emulator.
- History of versions and configuration changes.

## 15. Non-functional requirements and acceptance criteria

| ID | Requirement / acceptance criterion |
|---|---|
| NFR-01 | No keyboard needed for everyday operations: choose a profile, browse, download, launch, go back. |
| NFR-02 | A network loss does not make games already present and known local profiles unusable. |
| NFR-03 | An interruption during a download never leaves a partially valid final file. |
| NFR-04 | No save of one profile is visible to or used by another profile, for every emulator. |
| NFR-05 | No save conflict overwrites a version without archiving it. |
| NFR-06 | Launching anyway is always possible if the executable and the game can technically run. |
| NFR-07 | Compatibility messages distinguish verified, unknown, warning and technical block. |
| NFR-08 | Emulator updates never overwrite user overrides without a backup. |
| NFR-09 | The UI stays usable at a common TV resolution, from a couch. |
| NFR-10 | RomM secrets appear neither in plain text in SQLite nor in logs. |
| NFR-11 | Uninstalling Borne never deletes ROMs/saves without explicit consent. |
| NFR-12 | Every distribution / version declared supported has a reproducible test result. |
| NFR-13 | Automatic conflict resolution relies on the server timestamp and hashes, never on the local clock alone. |
| NFR-14 | Shader caches survive emulator and Borne updates. |
| NFR-15 | RetroArch never writes a save outside the active profile's folders, even after its configuration is changed from its menu. |
| NFR-16 | The UI holds 60 fps while browsing a 2,000-game library on the reference hardware, under gamescope. |
| NFR-17 | An emulator exit or crash always returns to the Borne UI, without keyboard intervention. |
| NFR-18 | A 720p H.264 trailer is decoded by the GPU on the reference hardware without dropping navigation below 60 fps. |
| NFR-19 | The background and accent follow the focus within 600 ms without dropping frames. |

### 15.1 Acceptance test scenarios

- Pair two RomM accounts and create two local profiles.
- Download a game from each profile and confirm the ROM is physically shared.
- Create a save with profile A; check profile B does not use it.
- Launch the game offline with profile A; create a save; reconnect RomM and check the sync.
- Change the same save on two devices; check the newest wins and the other is archived and restorable.
- Deliberately shift one device's clock; check conflict resolution stays correct.
- Disconnect the network during a download; check it resumes without corruption.
- Launch a game without a compatibility profile; check the warning and the option to launch anyway.
- Simulate a missing BIOS or Switch keys; check the diagnosis and the absence of a false "compatible" status.
- Connect Switch Pro, Xbox and PlayStation controllers over USB then Bluetooth, in the Steam session; check detection and mapping.
- Update an emulator; check configurations and shader cache are kept, and rollback works.
- Kill the emulator; check the return to the UI and save consistency.
- Zelda TotK: launch with two profiles, play, quit; check separate saves, RomM sync, shader cache reuse and the performance criterion (section 9.3).
- Themes and trailers: browse 2,000 games with trailers on, switch theme with the gamepad; check smoothness, GPU decoding and fallback to the default theme with a broken theme.
- Cross-device: NES save created in Borne, continued in EmulatorJS (RomM), changed, then fetched back in Borne.

## 16. Delivery plan

| Stage | Deliverables | Exit criterion | Status |
|---|---|---|---|
| 0 — Audit & prototypes | Rust core + QML UI prototype (grid, trailer, themes, game mode); RomM API audit; licenses. | Prototype validated; RomM version, local API format and theme API v1 decided. | Done |
| 1 — Foundation + RomM | Rust service, SQLite, XDG paths, local API, pairing, accounts, devices, catalog, covers, downloads with resume and verification, UI (grid, detailed view, menus, themes), English/French UI, Linux and macOS builds. | A RomM game can be downloaded, verified and seen locally; end-to-end tests against a real RomM. | Done |
| 2 — Profiles & saves | Multi-person profiles, save isolation, Device Sync, conflict policy and archives. | Offline, shifted-clock and conflict tests pass without loss. | Next |
| 3 — RetroArch | Isolated config, pinned cores, NES/MD launch, Steam non-Steam integration. | Complete NES/MD flow, including an EmulatorJS round trip. | Planned |
| 4 — Dolphin, PCSX2, Switch | Adapters, per-profile memory cards, Flatpak installation; Yuzu-family adapter, keys/firmware, per-profile saves, shaders, mods, TotK profile. | Complete GC/PS2 flow; TotK scenario validated on the reference hardware. | Planned |
| 5 — Compatibility, peripherals, distribution | Rules engine, reports, per-game profiles, gamepads; Flatpak/AppImage packaging, autostart, CLI, documentation. | Warned launch, launch anyway and diagnostics verified; couch/gamepad acceptance and Linux matrix published. | Planned |

### 16.1 Main risks

| Risk | Impact | Mitigation |
|---|---|---|
| A Switch emulator is discontinued or taken down | Critical | Yuzu-family adapter (Eden/Citron), user-provided binary, no hard-coded source. |
| Multi-device save conflicts | Critical | Official Device Sync, server timestamps, systematic archives, failure tests. |
| Steam Input interferes with mapping | High | "Raw gamepad" layout, dedicated tests. |
| Qt Multimedia VA-API video decoding | High | Pinned and tested Qt version, dedicated test, option to disable trailers. |
| Unstable or malicious QML themes / extensions | High | Versioned API, isolated loading, safe mode, warning at install. |
| VRAM used by the UI during a game | High | Game mode (hidden window, released resources), measured in the diagnostics. |
| RetroArch writes outside the profile folders | High | Isolated config, per-profile appendconfig, NFR-15. |
| RomM protocol changes | High | Versioned adapter, declared minimum version. |
| Linux heterogeneity | High | Packaging adapters and a real compatibility matrix. |
| Not enough VRAM for TotK at high resolution | Medium | ASTC recompression, 1x resolution by default, VRAM check. |
| Special peripherals | Medium | Input profiles and documented hardware tests. |

## 17. Decision log

| Topic | Decision | Status |
|---|---|---|
| Name | Borne (working name "GameHub" until v1.3) | Decided |
| Platform | Multi-distribution Linux; ChimeraOS as reference; macOS builds for testing | Decided |
| Purpose | Personal use first | Decided |
| Local core | Rust | Decided |
| UI | Dedicated Qt 6 / QML application, separate process; ES-DE dropped | Decided |
| Core ↔ UI link | Versioned local HTTP + WebSocket API | Decided |
| Extensions | UI in QML; emulators and sources on the core side (manifests) | Decided |
| Themes | theme.json + Theme.qml (+ optional components), versioned API, isolation, safe mode | Decided |
| Trailers | Muted background video, local cache, GPU decoding | Decided |
| UI languages | English source, French translation; follows the system language | Decided |
| Ludo | Reference only, no code reuse planned | Decided |
| V1 systems | NES, MD, GameCube, PS2, Switch (TotK) | Decided |
| Emulators | Isolated RetroArch (8/16-bit) + Dolphin, PCSX2, Eden | Decided |
| Installation | Flatpak first; user binary for Switch | Decided |
| Session | Non-Steam game in the ChimeraOS Steam session | Decided |
| RomM | Latest stable release + Device Sync; developed against 5.4.1 | Decided |
| Profiles | Several people, several devices | Decided |
| Conflicts | Newest wins (server timestamp) + archive | Decided |
| Devices | Another PC, Steam Deck, Android, EmulatorJS | Decided |
| Separated data | Per-profile saves/states; shared library, emulators, shaders | Decided |
| Launch anyway | Available to everyone if technically possible | Decided |
| License | GPL-3.0-or-later | Decided |

## 18. Sources and technical references

Versions change: revalidate at the start of each stage and pin the versions actually tested.

- [S1] Qt 6 — doc.qt.io. Qt Quick / QML, Qt Multimedia (FFmpeg backend), Qt Linguist, LGPL licensing.
- [S2] RomM — docs.romm.app. API, users, saves, Device Sync protocol.
- [S3] Ludo — github.com/rommapp/ludo. RomM client (Python + Electron, GPL-3.0): library, downloads, save/state sync, RetroArch and Eden launching.
- [S4] RetroDECK — github.com/RetroDECK/RetroDECK. Reference for Flatpak emulator integration (GPL-3.0).
- [S5] ChimeraOS — chimeraos.org. Immutable gaming distribution, Steam session.
- [S6] State of Switch emulation (specialized press, 2026): discontinuations and takedown requests, Eden and Citron active. Secondary sources to revalidate.
- [S7] Pegasus Frontend — pegasus-frontend.org. Qt/QML launcher with QML themes, reference for theme architecture.

## Cases, art and languages

- Each console's games have a case profile (ui/components/Cases.js): material (cardboard, keep case,
  jewel case, clamshell), plastic color and real outer size in millimetres; cases are drawn to scale
  against each other (PlayStation jewel case small and nearly square, GameCube case tall, Super
  Nintendo box wide, or upright when its cover is). Logos and printed art
  come only from the user's RomM scans.
- Game media (core/src/media.rs): after each sync the core fetches, for every game, the case scans
  (front `box2d`, spine `box2d_side`, back `box2d_back`), the cartridge or disc (`physical`) and the
  logo, 4 at a time, into `media/art/sets`. One coherent set per game: the case faces come from the
  version with the most of them. Each image is cleaned once (white or transparent scan margins
  trimmed, at most 6% per side; a spine stored lying down stood up; size capped) and its pixel size
  is stored, so boxes are shaped before images load. A changed source in RomM is fetched again.
  Settings → Server → Game media shows, per console, what is on disk and what RomM lacks;
  *Fetch again* forgets the files and fetches them anew (`POST /api/v1/media/refresh`;
  `GET /api/v1/media/report`).
- Cases are rebuilt from ScreenScraper's case elements (through RomM or Borne's own access): the front scan (`box2d`) is the
  front and sets the width, the spine scan (`box2d_side`) is printed on the spine and sets the
  thickness (stood up if stored lying down), the back scan (`box2d_back`) is the back. The console's
  real case size fills in what is missing.
- `GET /api/v1/games/{id}/art/{front|side|back|fanart|logo|physical|title|backdrop}`: ScreenScraper media
  stored by RomM (`ss_metadata.*_path`), from any version of the game, fetched once with the profile's
  token and cached in `media/art`. Library entries and the game page list the kinds available
  (`art_kinds`) so the UI asks only for those.
- Game page `languages`: the languages found across the game's versions, each with the version
  launched for it (the region that natively speaks it first, then installed, then the usual score).
  Choosing one stores both the version and the language.

## ScreenScraper (Borne's own access)

- Settings → Game images: the user's ScreenScraper account (user name and password, checked with
  `ssuserInfos.php`, kept in a 0600 file, never logged). Borne's developer credentials are compiled
  in (see "External services").
- After each sync, and on demand, the core asks `jeuInfos.php` for each game not asked yet: by
  ScreenScraper's game id when RomM has it, else by console, file name, size and hashes. One request
  at a time; quota and refusals (403 credentials, 429/430 quota, 401/423 closed) stop the run with a
  clear message.
- Kept: `box-2D` (front), `box-2D-side` (spine), `box-2D-back` (back), `support-2D` (cartridge or
  disc), `wheel-hd` / `wheel` (logo), `fanart`, in the version's region first (Europe → eu, France →
  fr then eu, then wor, us, ss, jp). No spine scan: the spine is cut from `box-texture` (back | spine |
  front) using the front's proportions. ScreenScraper's images take precedence over RomM's copies.
- Boxes are real boxes: the spine on the left side only, the opening edge on the right; the front
  takes the exact proportions of its image (scan, else cover), so nothing is cropped.

## External services

Borne talks to RomM, to ScreenScraper (Borne's own access, optional) and to GitHub (its own
updates), and to nothing else. Earlier sources (LaunchBox Games Database, Wikidata / Wikipedia) were
removed; their caches are dropped when the database is opened.

### ScreenScraper developer credentials

ScreenScraper requires the software's developer credentials with every request. They are repository
secrets (`SCREENSCRAPER_DEV_ID`, `SCREENSCRAPER_DEV_PASSWORD`), passed to the build as
`BORNE_SS_DEV_ID` / `BORNE_SS_DEV_PASSWORD` and compiled in by `core/build.rs` masked with a key drawn
for each build: never in the repository, not readable as strings in the binary, masked in CI logs,
never logged by Borne, never returned by the API (only `developer_access: true/false`), and stripped
from stored media URLs. Errors from the network never carry the request URL. A build without them
says so in Settings; development builds can set the same variables in the environment.

## Game boxes as solids

- Six faces (front, back, spine on the left, opening edge on the right, top, bottom), each drawn
  through one perspective matrix; the box turns about its vertical axis (yaw) and its horizontal
  axis (pitch). Faces facing away are culled (a box is convex, so no depth sorting is needed).
- One key light (above, left, in front): each face is shaded by how it faces the light, scaled so a
  box facing the viewer at rest is fully lit, and catches a specular highlight (Blinn) that slides
  across it as it turns; the clear sleeve of plastic cases adds a sheen band that follows the turn.
  Materials: keep case (rim, rounded edges, moulded ridges on bare edges), jewel case (hinge, black
  tray under a clear lid), clamshell, cardboard (matte, crisp folds).
- The selected box (library and game page) leans with the right stick (core event `stick`, dead
  zone 0.18, steps of 0.05) or Z Q S D held: the stick sets the angle, within ±38° of turn and ±22°
  of tilt, so the front always stays in view (never the back); released, the box comes straight
  back. `POST /api/v1/debug/stick?x=&y=` drives it in tests.
