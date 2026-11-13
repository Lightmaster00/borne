#!/usr/bin/env python3
# Synthetic case scans for the bench: each edge has its own coloured band (left red, right green,
# top blue, bottom yellow), an arrow points up, corners are labelled. A cut print loses a band, a
# smeared one spreads it, a stretched one turns the circle into an ellipse.
#
#   tests/case_bench/make_scans.py <work dir>     (needs Pillow)
from PIL import Image, ImageDraw, ImageFont
import json, os, sys
WORK = sys.argv[1]
ART = os.path.join(WORK, "art")
F = ImageFont.load_default(size=26)
def scan(w, h, label, bg):
    im = Image.new("RGB", (w, h), bg); d = ImageDraw.Draw(im)
    b = max(4, min(w, h) // 30)
    d.rectangle([0, 0, b, h], fill=(220, 30, 30)); d.rectangle([w - b - 1, 0, w, h], fill=(30, 200, 60))
    d.rectangle([0, 0, w, b], fill=(40, 80, 230)); d.rectangle([0, h - b - 1, w, h], fill=(240, 210, 30))
    r = min(w, h) // 4; cx, cy = w // 2, h // 2
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline="white", width=max(2, r // 10))
    d.polygon([(cx, cy - r + 6), (cx - r // 3, cy - r // 4), (cx + r // 3, cy - r // 4)], fill="white")
    if w > 80:
        d.text((b + 6, b + 4), "TL", fill="white", font=F); d.text((w - b - 40, h - b - 34), "BR", fill="white", font=F)
        d.text((b + 8, cy + r + 10), label, fill="white", font=F)
    return im
# id, console, front w/h, spine w/h (0: none), kinds
G = [(1, "nds", 0.912, 0.10), (2, "psx", 1.0, 0.075), (3, "ps2", 0.71, 0.07), (4, "switch", 0.62, 0.065),
     (5, "snes", 1.40, 0.29), (6, "snes", 0.73, 0.20), (7, "n64", 1.40, 0.24), (8, "gb", 0.90, 0.17),
     (9, "genesis", 0.71, 0.15), (10, "3ds", 0.91, 0.10), (11, "neogeoaes", 0.73, 0.25), (12, "ngc", 0.71, 0.10),
     (13, "wii", 0.71, 0.09), (14, "nes", 0.71, 0)]
out = []
for i, slug, far, sar in G:
    d = f"{ART}/{i}"; os.makedirs(d, exist_ok=True)
    scan(int(900 * far), 900, f"{slug} front", (60, 60, 110)).save(f"{d}/front", "PNG")
    scan(int(900 * far), 900, f"{slug} back", (90, 60, 60)).save(f"{d}/back", "PNG")
    kinds = ",front,back,"
    if sar:
        scan(max(24, int(900 * sar)), 900, "", (40, 40, 40)).save(f"{d}/side", "PNG"); kinds += "side,"
    out.append({"rom_id": i, "name": f"{slug} {far}", "platform_slug": slug, "art": f"file://{d}/", "art_kinds": kinds,
                "front_ar": far, "side_ar": sar, "cover_ar": 0, "cover": "", "hue": 200, "spine_color": "#d02030"})
# Risky cases: a RomM cover only (square on a PS2, a banner), a very thin Switch spine, a spine
# scanned lying down.
extra = []
d = f"{ART}/15"; os.makedirs(d, exist_ok=True); scan(900, 900, "cover 1.0", (70, 90, 60)).save(f"{d}/cover.png")
extra.append({"rom_id": 15, "name": "ps2 cover", "platform_slug": "ps2", "art": f"file://{d}/", "art_kinds": ",",
              "front_ar": 0, "side_ar": 0, "cover_ar": 1.0, "cover": f"file://{d}/cover.png", "hue": 120, "spine_color": ""})
d = f"{ART}/16"; os.makedirs(d, exist_ok=True); scan(1500, 500, "banner", (70, 90, 60)).save(f"{d}/cover.png")
extra.append({"rom_id": 16, "name": "banner cover", "platform_slug": "snes", "art": f"file://{d}/", "art_kinds": ",",
              "front_ar": 0, "side_ar": 0, "cover_ar": 3.0, "cover": f"file://{d}/cover.png", "hue": 30, "spine_color": ""})
d = f"{ART}/17"; os.makedirs(d, exist_ok=True)
scan(558, 900, "switch front", (60, 60, 110)).save(f"{d}/front", "PNG"); scan(58, 900, "", (40, 40, 40)).save(f"{d}/side", "PNG")
extra.append({"rom_id": 17, "name": "switch thin", "platform_slug": "switch", "art": f"file://{d}/", "art_kinds": ",front,side,",
              "front_ar": 0.62, "side_ar": 0.065, "cover_ar": 0, "cover": "", "hue": 0, "spine_color": "#e60012"})
d = f"{ART}/18"; os.makedirs(d, exist_ok=True)
scan(640, 900, "ps2 front", (60, 60, 110)).save(f"{d}/front", "PNG")
lying = scan(900, 90, "", (40, 40, 40)); ImageDraw.Draw(lying).text((120, 30), "LYING SPINE  START >>>", fill="white", font=F); lying.save(f"{d}/side", "PNG")
extra.append({"rom_id": 18, "name": "ps2 lying spine", "platform_slug": "ps2", "art": f"file://{d}/", "art_kinds": ",front,side,",
              "front_ar": 0.71, "side_ar": 10.0, "cover_ar": 0, "cover": "", "hue": 0, "spine_color": "#1f4bbf"})
json.dump(out + extra, open(os.path.join(WORK, "games.json"), "w"))
print(len(out + extra), "games")
