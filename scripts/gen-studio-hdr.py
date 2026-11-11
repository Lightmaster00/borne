#!/usr/bin/env python3
"""Writes ui/components/studio.hdr: the photo studio the 3D game cases are lit by (an
equirectangular Radiance HDR used as the scene's light probe). A dark room, a large softbox
above and in front on the left (the key), a tall strip on the right (the fill), a long overhead
panel and two narrow strips behind the cases (the rims). Their reflections are what make the
clear sleeves, the jewel cases and the plastic read as real.

Run it again after changing the layout:  python3 scripts/gen-studio-hdr.py
"""
import math
import os
import struct
import sys

W, H = 512, 256

# Directions are in the shelf's scene coordinates: x right, y up, z toward the camera (which
# looks toward -z). Mapping checked in Qt Quick 3D with a mirror case: the texel at (u, v) is seen
# toward longitude (u - 0.5) * 2π from +x round to +z, latitude (0.5 - v) * π.

def direction(u, v):
    lon = (u - 0.5) * 2 * math.pi
    lat = (0.5 - v) * math.pi
    return (math.cos(lat) * math.cos(lon), math.sin(lat), math.cos(lat) * math.sin(lon))


def norm(a):
    l = math.sqrt(sum(c * c for c in a))
    return tuple(c / l for c in a)


def smooth(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


class Panel:
    """A rectangular light facing the centre: centre direction, half sizes in degrees
    (horizontal, vertical), colour × intensity, edge softness in degrees."""

    def __init__(self, toward, half_w, half_h, rgb, power, soft=4.0):
        self.c = norm(toward)
        up = (0.0, 1.0, 0.0)
        if abs(self.c[1]) > 0.95:
            up = (0.0, 0.0, -1.0)
        # local axes on the panel
        r = norm((up[1] * self.c[2] - up[2] * self.c[1], up[2] * self.c[0] - up[0] * self.c[2],
                  up[0] * self.c[1] - up[1] * self.c[0]))
        u = (self.c[1] * r[2] - self.c[2] * r[1], self.c[2] * r[0] - self.c[0] * r[2],
             self.c[0] * r[1] - self.c[1] * r[0])
        self.r, self.u = r, u
        self.hw, self.hh = math.radians(half_w), math.radians(half_h)
        self.rgb = tuple(c * power for c in rgb)
        self.soft = math.radians(soft)

    def light(self, d):
        dc = sum(a * b for a, b in zip(d, self.c))
        if dc <= 0.05:
            return (0.0, 0.0, 0.0)
        x = math.atan2(sum(a * b for a, b in zip(d, self.r)), dc)
        y = math.atan2(sum(a * b for a, b in zip(d, self.u)), dc)
        k = (1 - smooth(self.hw - self.soft, self.hw + self.soft, abs(x))) * \
            (1 - smooth(self.hh - self.soft, self.hh + self.soft, abs(y)))
        if k <= 0:
            return (0.0, 0.0, 0.0)
        # a softbox is brighter in its middle
        k *= 0.82 + 0.18 * (1 - min(1.0, (x / self.hw) ** 2 + (y / self.hh) ** 2))
        return tuple(c * k for c in self.rgb)


PANELS = [
    # key: a large softbox above and left of the camera; its edge sweeps over the sleeves
    Panel((-0.38, 0.36, 0.85), 22, 14, (1.0, 0.96, 0.9), 6.0, soft=6),
    # a dim bounce card behind the camera: the faint gloss every clear face shows
    Panel((0.1, 0.0, 1.0), 38, 22, (1.0, 1.0, 1.0), 0.35, soft=14),
    # fill: a tall strip on the right
    Panel((0.88, 0.1, 0.45), 6, 30, (0.9, 0.95, 1.0), 3.0, soft=3),
    # overhead panel
    Panel((0.0, 1.0, 0.2), 24, 8, (1.0, 1.0, 1.0), 2.2, soft=6),
    # rims: two narrow strips behind the cases
    Panel((-0.75, 0.25, -0.62), 4, 32, (1.0, 0.97, 0.92), 4.0, soft=2),
    Panel((0.75, 0.25, -0.62), 4, 32, (0.92, 0.96, 1.0), 3.0, soft=2),
]


def background(d):
    y = d[1]
    # dark grey room: a little brighter above, near black floor, a faint warm bounce near it
    if y >= 0:
        g = 0.035 + 0.05 * y
        return (g, g, g * 1.05)
    g = 0.012 + 0.02 * (1 + y)
    return (g * 1.1, g, g * 0.9)


def rgbe(r, g, b):
    m = max(r, g, b)
    if m < 1e-32:
        return (0, 0, 0, 0)
    e = math.frexp(m)[1]
    f = 256.0 / (2.0 ** e)
    return (int(r * f), int(g * f), int(b * f), e + 128)


def rle_scanline(px):
    out = bytearray([2, 2, (W >> 8) & 0xFF, W & 0xFF])
    for ch in range(4):
        data = [p[ch] for p in px]
        i = 0
        while i < W:
            # a run of equal bytes?
            j = i
            while j < W and j - i < 127 and data[j] == data[i]:
                j += 1
            if j - i >= 3:
                out += bytes([128 + (j - i), data[i]])
                i = j
                continue
            # literal chunk up to the next run of 3
            j = i
            while j < W and j - i < 128:
                if j + 2 < W and data[j] == data[j + 1] == data[j + 2]:
                    break
                j += 1
            out += bytes([j - i]) + bytes(data[i:j])
            i = j
    return out


def main():
    dst = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(__file__), "..", "ui", "components", "studio.hdr")
    body = bytearray()
    for y in range(H):
        line = []
        for x in range(W):
            d = direction((x + 0.5) / W, (y + 0.5) / H)
            c = list(background(d))
            for p in PANELS:
                l = p.light(d)
                c = [a + b for a, b in zip(c, l)]
            line.append(rgbe(*c))
        body += rle_scanline(line)
    head = b"#?RADIANCE\n# Borne studio light probe, scripts/gen-studio-hdr.py\nFORMAT=32-bit_rle_rgbe\n\n"
    head += ("-Y %d +X %d\n" % (H, W)).encode()
    with open(dst, "wb") as f:
        f.write(head + body)
    print("wrote", dst, len(head) + len(body), "bytes")


if __name__ == "__main__":
    main()
