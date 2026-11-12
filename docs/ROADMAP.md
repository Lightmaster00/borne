# Roadmap

What is left to build or to check. Done work is described in [`SPEC.md`](SPEC.md).

## To check on the real machines (ChimeraOS PC, Mac)

- Emulators: that each one picks up the configuration Borne writes (display settings, per-game
  options, controllers, cheats; Ryujinx's `enabled.txt`), and the Eden and Ryubing release file
  names on a first real install.
- Saves: a round trip per emulator against RomM.
- 3D cases on real covers: the PlayStation hinge cut, regional N64 / Super Nintendo boxes, spine
  thickness, the glass reflections; stick sensitivity on Xbox, PlayStation and Switch Pro pads.
- A 1 800-game library: 60 frames per second at 4K, library requests under 150 ms.
- Updates by parts between two published builds, on Linux and macOS.

## To build

- RomM Device Sync for saves, and a conflict screen when both sides changed close together.
- Compatibility rules engine (warned launch, launch anyway) and per-game reports.
- Flatpak packaging.
- Signed releases (macOS notarization, Linux signature): needs an Apple developer account and a
  signing key.

## Tests to add

- A real ScreenScraper run in CI (secret-gated, a handful of known games), once the developer
  credentials are granted.
- A performance test with a generated 2 000-game library.
