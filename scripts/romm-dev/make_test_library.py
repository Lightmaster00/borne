"""RomM test library: dummy files (no real ROMs), distinct contents for unique hashes."""
import os, random, sys, zipfile
root = sys.argv[1]
rnd = random.Random(42)
def blob(n): return bytes(rnd.getrandbits(8) for _ in range(n)) if n < 2_000_000 else os.urandom(n)
def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f: f.write(data)
nes = ["Pixel Quest (Europe)", "Crystal Knights (USA)", "Neon Racer (Japan)", "Shadow Saga (Europe)", "Iron Odyssey (USA)",
       "Lunar Blaster (Europe)", "Wild Hunter (USA)", "Silent Kingdom (Japan)", "Star Runner (Europe)", "Rogue Tactics (USA)",
       "Golden Drift (Europe)", "Frozen Legends (USA)"]
for n in nes:
    write(f"{root}/library/roms/nes/{n}.nes", b"NES\x1a\x02\x01\x01\x00" + bytes(8) + blob(40_960))
md = ["Thunder Fighter (Europe)", "Solar Chronicles (USA)", "Hyper Rush (Japan)", "Ancient Heroes (Europe)", "Rogue Racer (USA)",
      "Iron Saga (Europe)", "Neon Odyssey (USA)", "Pixel Kingdom (Europe)"]
for n in md:
    write(f"{root}/library/roms/genesis/{n}.md", blob(524_288))
# Versions of the same game (regions, languages, revisions), grouped by Borne
variants = [("nes", "Crystal Knights (Europe) (En,Fr,De)", ".nes"), ("nes", "Crystal Knights (Japan) (Rev 1)", ".nes"),
            ("genesis", "Ancient Heroes (France)", ".md"), ("genesis", "Ancient Heroes (USA)", ".md")]
for system, n, ext in variants:
    data = b"NES\x1a\x02\x01\x01\x00" + bytes(8) + blob(40_960) if ext == ".nes" else blob(524_288)
    write(f"{root}/library/roms/{system}/{n}{ext}", data)
# Compressed games (extraction on the Borne side must be tested)
for n in ["Zip Adventure (Europe)", "Zip Arena (USA)"]:
    p = f"{root}/library/roms/genesis/{n}.zip"
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with zipfile.ZipFile(p, "w", zipfile.ZIP_DEFLATED) as z: z.writestr(f"{n}.md", blob(524_288))
# Large file to test download resume
write(f"{root}/library/roms/genesis/Big Download Test (World).md", os.urandom(96 * 1024 * 1024))
# Systems of later stages (catalog display only)
for n in ["Cube Racer (Europe)", "Cube Legends (USA)"]: write(f"{root}/library/roms/ngc/{n}.iso", blob(1_000_000))
for n in ["Two Heroes (Europe)", "Two Saga (USA)"]: write(f"{root}/library/roms/ps2/{n}.iso", blob(1_000_000))
for n in ["Switch Quest [0100000000010000]", "Switch Kart [0100000000020000]"]: write(f"{root}/library/roms/switch/{n}.nsp", blob(1_000_000))
for d in ["resources", "assets", "config"]: os.makedirs(f"{root}/{d}", exist_ok=True)
open(f"{root}/config/config.yml", "a").close()
print("ok")
