# Borne: improvements backlog

Findings from a full pass over the application (core API, interface, packaging, updates) on
2026-11-11, and the work they call for. Each item says why it matters, what "done" means, and its
priority: **P0** blocks everyday use, **P1** next, **P2** later.

State of the checks at the time of writing:

- Core unit tests: 26 passed.
- Integration test against a real RomM server: 70 checks passed (pairing, sync, library, versions
  and languages, downloads with resume and integrity checks, network mount, game details, media,
  ScreenScraper refusal without developer access, diagnostics with no secret in the report or log).
- Startup test in English and French, in-app update test (download, verify, swap, keep the previous
  version): passed.
- ScreenScraper and the media pipeline: tested end to end against a local stand-in of the API
  (credentials refused, game found by name, images fetched, spine cut from the box texture,
  credentials absent from logs and stored URLs). Not yet against the real service: Borne's
  developer credentials are pending.

## 1. Game boxes

### 1.1 Real 3D boxes with textured faces (P0 — first pass done)

Done: the shelf and the game page render the cases with Qt Quick 3D (`Case3D` in `Shelf3D`): shell,
front scan under a clear sleeve, spine on the left, back, key light with soft shadows on a fading
floor, fill and rim lights; the 2D shelf stays as a fallback (automatic, or Settings → Interface →
Game cases). Qt Quick 3D is bundled on Linux (PySide6 wheels) and macOS (`qtquick3d` module).

Still to do:
- Rounded edges: the shell is a plain cube; a mesh per case type with bevels and the real details
  (keep case rim and sleeve seam, jewel case hinge and tray, clamshell lid).
- The unfolded box texture (back, spine and front in one image) mapped by UV regions when present.
- Image-based lighting from a small studio environment map; reflection on the glossy floor.
- Measure: a 1 800-game library scrolling at 60 frames per second on the target PC, at 4K.

### 1.2 Spine when no scan exists (P1)

Many games have no spine scan on ScreenScraper. Generate one: a band in the cover's dominant colours,
the game's logo (wheel) rotated, the title as text when there is no logo. No console trademarks.

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

### 2.2 Matching quality (P1)

- Report per console in Settings: found, not found, and the list of games not found.
- Let the user fix a match: search ScreenScraper by name (`jeuRecherche.php`) from the game page and
  pick the right game.
- Respect the account's `maxthreads` (several requests at once for members who have it) to shorten
  the first run.

### 2.3 Image choice (P2)

From the game page: choose another region's box (EU / US / JP) when several exist.

## 3. Playing games

### 3.1 Emulators managed by Borne (P0 — second pass done)

Done: one emulator per console chosen in Settings, downloaded, installed, configured and updated
by Borne (`emuinstall.rs`); RetroArch hidden behind Borne's own configuration; launch, game mode,
Select + Start to quit.

Next:
- Cheats: done for RetroArch consoles (libretro database, exact dump name) and the DS
  (DeadSkullzJr's cheats.xml, game ID from the header) through RetroArch cores. Still to do:
  Dolphin (Gecko/Action Replay codes in the per-game INI of Borne's Dolphin folder, e.g. from
  Dolphin's own GameSettings), PCSX2 (`.pnach` by serial and CRC), standalone melonDS (`.mch`),
  Switch emulators (`load/<title id>/<name>/cheats`). Check on the real RetroArch that the `.cht`
  written under `cheat_database_path/<core name>/` is loaded with the game.
- Display settings: done for all games, per console and per game (shape, resolution, pixels with
  a CRT look, integer scaling, frame rate) for RetroArch, Dolphin, PCSX2, DuckStation, Eden,
  Citron, Ryubing (once its Config.json exists), RPCS3, Xenia. shadPS4 renders at native size.
  Controllers: Dolphin, PCSX2, DuckStation mapped to the first gamepad on their first start;
  the Switch and PS3 emulators' own controller formats still to write. All of these formats must
  be checked on the real emulators.
- PCSX2, DuckStation and melonDS in portable mode inside Borne's folder; controller mappings
  written by Borne for every emulator.
- BIOS and firmware: taken from RomM's BIOS for the console and placed in Borne's `bios` folder;
  a clear message before launching when one is missing.
- System files: done (Settings → System files, from a file or a link; placed for RetroArch,
  PCSX2, Eden, Citron, Ryubing keys, RPCS3 firmware). Still to do: Ryubing firmware installation,
  shadPS4 system modules, and
  checking BIOS dumps against known checksums (region shown).
- Eden and Ryubing release file names are matched by words; check them against the real releases
  on the first real install (they could not be read from the build machine).
- Test on the real machines (ChimeraOS, macOS) with real downloads.

### 3.2 Saves (P1 — first pass done)

Done (`savesync.rs`, per profile, newest wins, replaced copies archived, pending sends retried):
RetroArch battery saves and save states; Dolphin, PCSX2 and DuckStation with a memory card per
game; Eden and Citron save folders per title (zip); RPCS3 save folders by serial. Still to do:
check that PCSX2 creates a missing card itself; Ryubing, shadPS4 and Xenia saves; RomM's Device Sync (device id, tracked saves) once Borne registers as
a device; a conflict screen when both sides changed close together.

## 4. Library and navigation

- (P1) Library request time with 1 800 games: the core now looks up each game's media and covers
  when listing; measure on the real library, cache the result per sync if it exceeds 150 ms.
- (P1) Sort and filters: by name, recently played, recently added, installed, genre.
- (P2) Favourites and "continue playing" row once launching exists.
- (P2) Search: also match alternate titles (Japanese names, subtitles).

## 5. Interface

- (P1) Game page without a trailer and without artwork looks empty: use the screenshots as a slow
  slideshow behind the hero.
- (P1) Onscreen keyboard: add a QWERTY / AZERTY switch independent of the system language.
- (P2) The arcade room home style shares little with the new boxes: either bring it to the same
  quality or remove it.
- (P2) Settings pages are long lists of buttons: group them in cards like the install choice.

## 6. Reliability and security

What was checked in this pass: the API listens on 127.0.0.1 only behind a random token in the path;
file serving is limited to Borne's folders; secrets (RomM tokens, ScreenScraper account) are 0600
files; the diagnostic report and the log hold no token; network errors from ScreenScraper never
carry a URL; downloaded images are decoded with size and memory limits; updates are checked by
SHA-256 and only fetched from this repository's releases.

To do:

- (P1) QML check in CI only verifies syntax: a duplicated property broke the game page and was only
  caught by the startup test. Add `qmllint` with warnings as errors on the components.
- (P1) The interface writes many short warnings for missing images (404 on `art/...` when a scan is
  absent). The library already lists the kinds available; remove the remaining blind requests.
- (P2) Rate-limit the local API's expensive endpoints (media refresh, sync) against repeated calls.
- (P2) Signed releases (macOS notarisation, Linux signature) so the update check does not rest on
  GitHub alone.

## 7. Tests to add

- Real ScreenScraper run in CI (secret-gated, a handful of known games).
- UI walk-through test driving the debug pad: library, search, letters, game page, language,
  settings sections, downloads panel, menu (today done by hand with screenshots).
- Performance test with a generated 2 000-game library.
