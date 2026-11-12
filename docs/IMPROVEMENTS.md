# Borne: improvements backlog

Findings from a full pass over the application (core API, interface, packaging, updates) on
2026-11-11, and the work they call for. Each item says why it matters, what "done" means, and its
priority: **P0** blocks everyday use, **P1** next, **P2** later.

State of the checks (2026-11-12):

- Core unit tests: 58 passed.
- Integration test against a real RomM server: 98 checks passed (pairing with a code or with the
  account's password, the server's accounts listed for an administrator, sync, library, versions
  and languages, downloads with resume and integrity checks, network mount, game details, media,
  diagnostics with no secret in the report or log).
- Startup test in English and French; UI walk-through with no QML error; QML check with no
  duplicated property or binding.
- ScreenScraper and the media pipeline: tested end to end against a local stand-in of the API
  (search, corrections, regions, console frames included). To check against the real service.

## 1. Game boxes

### 1.1 Real 3D boxes with textured faces (P0 — done)

Done: the shelf and the game page render the cases with Qt Quick 3D (`Case3D` in `Shelf3D`): a box to
the console's proportions with slightly rounded corners and edges (`CaseMesh.js`), cover in front, the
same spine on both sides, back scan behind, the console's plastic colour on top and bottom; varnish and
grain on the prints, satin grain on the plastic; a thin ink outline; studio light probe and soft
shadows. The detailed per-console models (sleeves, jewel hinges…) were tried and dropped for this
simpler box. The 2D shelf stays as a fallback.

Still to do:
- Measure: a 1 800-game library scrolling at 60 frames per second on the target PC, at 4K.

### 1.2 Spine when no scan exists (done)

The game's logo (ScreenScraper wheel) turned along a band in the console's colour, else the title.

### 1.3 Box turning (done in this pass)

The stick sets the angle (±38° turn, ±22° tilt) so the front always stays in view, and the box comes
back as soon as the stick is released. To check on real hardware: stick sensitivity and dead zone on
the Xbox, PlayStation and Switch Pro controllers.

## 2. Game images and ScreenScraper

### 2.1 Developer credentials (P0, waiting on ScreenScraper)

Request sent by the project owner. Once granted, add the repository secrets
`SCREENSCRAPER_DEV_ID` and `SCREENSCRAPER_DEV_PASSWORD`; the next build includes them (see
SPEC.md, "External services"). Then test against the real service: matching rate per console,
quota use for 1 800 games, error texts.

### 2.2 Matching quality (done)

Settings → Game images → "Games found, per console": found, not found, not looked up; the games
not found open from there. Game page → Images: "Not the right game?" searches ScreenScraper by name
(`jeuRecherche.php`) and keeps the chosen game; the box region can be chosen (EU / US / JP…).
`maxthreads` is respected.

## 3. Playing games

### 3.1 Emulators managed by Borne (P0 — second pass done)

Done: one emulator per console chosen in Settings, downloaded, installed, configured and updated
by Borne (`emuinstall.rs`); RetroArch hidden behind Borne's own configuration; launch, game mode,
Select + Start to quit.

Next:
- Cheats: done for RetroArch consoles (libretro database, exact dump name), the DS
  (DeadSkullzJr's cheats.xml, game ID from the header; through RetroArch, or standalone melonDS
  with a `.mch` next to the game), GameCube and Wii (the codes Dolphin ships, game ID read from
  ISO, RVZ, WIA, CISO, WBFS), Switch (HamletDuFromage's switch-cheats-db, by title id; every
  version's file written since the build id cannot be read: Eden / Citron `load/`, Ryujinx
  `mods/` with `enabled.txt`) and PS2 (no public database: the player gives a `.pnach` for the
  game; the chosen cheats are written under the CRC read from the ISO's boot program). To check on
  the real emulators: that each picks its file up, and Ryujinx's `enabled.txt` format.
- Display settings: done for all games, per console and per game for RetroArch, Dolphin, PCSX2,
  DuckStation, Eden, Citron, Ryubing (once its Config.json exists), RPCS3, Xenia. Controllers:
  Dolphin, PCSX2, DuckStation, Eden / Citron (Pro Controller on the SDL pad, by its GUID), Ryujinx
  (Pro Controller on the SDL pad in its Config.json) and RPCS3 (SDL handler) set on their first
  start; Xenia finds gamepads by itself. All of these formats must be checked on the real
  emulators.
- System files: done (from a file, a link or RomM; placed for RetroArch, PCSX2, Eden, Citron,
  Ryubing keys and firmware, RPCS3 firmware, shadPS4 system modules); BIOS dumps checked against
  known MD5s (model and region shown, "(?)" for an unknown dump).
- Eden and Ryubing release file names are matched by words; check them against the real releases
  on the first real install (they could not be read from the build machine).
- Test on the real machines (ChimeraOS, macOS) with real downloads.

### 3.2 Saves (P1 — second pass done)

Done (`savesync.rs`, per profile, newest wins, replaced copies archived, pending sends retried):
RetroArch battery saves and save states; Dolphin, PCSX2 and DuckStation with a memory card per
game; Eden and Citron save folders per title (zip); RPCS3 save folders by serial; shadPS4 save
folders by title id (from param.sfo); Ryujinx save folders found by the program id in their
extra data; Xenia save folders by the title id read from default.xex (game folder, .xex or
ISO). Saves never mix between profiles: where an emulator keeps one
save folder for the whole Mac (Eden, Citron, Ryujinx, RPCS3, PCSX2), the previous profile's are set
aside before a game. Ryujinx and Xenia saves exist once the game has saved on that computer. Still
to do: RomM's Device Sync; a conflict screen when both sides changed close together.

## 4. Library and navigation

- Done: Favourites and Recent tabs (recently played, per profile), sort (name, recently played,
  recently added, most played) and one genre in Select → Sort and filter, search on every title
  ScreenScraper knows (other regions, Japanese names).
- (P1) Library request time with 1 800 games: measure on the real library, cache the result per
  sync if it exceeds 150 ms.

## 5. Interface

- Done: the redesign (console frame, console colours, rounded cards with an ink shadow, Fredoka
  titles); the game page shows its screenshots one after the other when it has no other picture;
  Settings rows are cards; the on-screen keyboard switches between AZERTY and QWERTY.

## 6. Reliability and security

What was checked in this pass: the API listens on 127.0.0.1 only behind a random token in the path;
file serving is limited to Borne's folders; secrets (RomM tokens, ScreenScraper account) are 0600
files; the diagnostic report and the log hold no token; network errors from ScreenScraper never
carry a URL; downloaded images are decoded with size and memory limits; updates are checked by
SHA-256 and only fetched from this repository's releases.

Done: the QML check fails on a duplicated property or binding (second qmllint pass); the
interface asks only for the images that exist; sync, media refresh and ScreenScraper runs asked
again within seconds run once.

To do:

- (P2) Signed releases (macOS notarisation, Linux signature) so the update check does not rest on
  GitHub alone: needs an Apple developer account and a signing key.

## 7. Tests to add

- Real ScreenScraper run in CI (secret-gated, a handful of known games).
- Performance test with a generated 2 000-game library.
