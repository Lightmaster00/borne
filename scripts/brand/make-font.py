#!/usr/bin/env python3
"""Builds "Borne Blocks", the typeface of Borne's lettering (ui/brand/wordmark.svg), for titles.

The logo's letters are drawn on a grid of 50-unit cells, 3 cells wide and 5 tall (250), 42 units
apart. Cells joined by a side form one shape; cells touching only by a corner stay separate (the
notches of B and R). Every corner is rounded: 10 units, 15 on the outer corners between two long
sides, 10 inside. This script draws the other letters, the digits and some punctuation the same
way and writes a WOFF2 (and a TTF) font. B, O, R, N and E come out exactly as in the logo.

    scripts/brand/make-font.py <output dir>
"""
import os
import sys

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

CELL, GAP, CAP = 50, 42, 250
SCALE = 2.8  # 250 logo units → 700 font units (cap height)

# 'X' a cell, '.' empty; 5 rows from the top. Lowercase letters use the capitals.
GLYPHS = {
    "A": ["XXX", "X.X", "XXX", "X.X", "X.X"],
    "B": ["XX.", "X.X", "XX.", "X.X", "XX."],
    "C": ["XXX", "X..", "X..", "X..", "XXX"],
    "D": ["XX.", "X.X", "X.X", "X.X", "XX."],
    "E": ["XXX", "X..", "XX.", "X..", "XXX"],
    "F": ["XXX", "X..", "XX.", "X..", "X.."],
    "G": ["XXX", "X..", "X.X", "X.X", "XXX"],
    "H": ["X.X", "X.X", "XXX", "X.X", "X.X"],
    "I": ["XXX", ".X.", ".X.", ".X.", "XXX"],
    "J": ["..X", "..X", "..X", "X.X", "XXX"],
    "K": ["X.X", "X.X", "XX.", "X.X", "X.X"],
    "L": ["X..", "X..", "X..", "X..", "XXX"],
    "M": ["XXXXX", "X.X.X", "X.X.X", "X.X.X", "X.X.X"],
    "N": ["XXX", "X.X", "X.X", "X.X", "X.X"],
    "O": ["XXX", "X.X", "X.X", "X.X", "XXX"],
    "P": ["XXX", "X.X", "XXX", "X..", "X.."],
    "Q": ["XXX", "X.X", "X.X", "XXX", "..X"],
    "R": ["XX.", "X.X", "XX.", "X.X", "X.X"],
    "S": ["XXX", "X..", "XXX", "..X", "XXX"],
    "T": ["XXX", ".X.", ".X.", ".X.", ".X."],
    "U": ["X.X", "X.X", "X.X", "X.X", "XXX"],
    "V": ["X.X", "X.X", "X.X", "X.X", ".X."],
    "W": ["X.X.X", "X.X.X", "X.X.X", "X.X.X", "XXXXX"],
    "X": ["X.X", "X.X", ".X.", "X.X", "X.X"],
    "Y": ["X.X", "X.X", "XXX", ".X.", ".X."],
    "Z": ["XXX", "..X", ".X.", "X..", "XXX"],
    "0": ["XXX", "X.X", "X.X", "X.X", "XXX"],
    "1": ["XX.", ".X.", ".X.", ".X.", "XXX"],
    "2": ["XXX", "..X", "XXX", "X..", "XXX"],
    "3": ["XXX", "..X", "XXX", "..X", "XXX"],
    "4": ["X.X", "X.X", "XXX", "..X", "..X"],
    "5": ["XXX", "X..", "XXX", "..X", "XXX"],
    "6": ["XXX", "X..", "XXX", "X.X", "XXX"],
    "7": ["XXX", "..X", "..X", "..X", "..X"],
    "8": ["XXX", "X.X", "XXX", "X.X", "XXX"],
    "9": ["XXX", "X.X", "XXX", "..X", "XXX"],
    ".": [".", ".", ".", ".", "X"],
    ",": [".", ".", ".", ".", "X", "X"],  # a sixth row goes under the baseline
    ":": [".", "X", ".", "X", "."],
    "!": ["X", "X", "X", ".", "X"],
    "'": ["X", ".", ".", ".", "."],
    "-": ["..", "..", "XX", "..", ".."],
    "+": ["...", ".X.", "XXX", ".X.", "..."],
    "?": ["XXX", "..X", ".X.", "...", ".X."],
    "/": ["..X", "..X", ".X.", "X..", "X.."],
    "(": [".X", "X.", "X.", "X.", ".X"],
    ")": ["X.", ".X", ".X", ".X", "X."],
}
ALIASES = {"’": "'", "‘": "'", "–": "-", "—": "-"}
SPACE = 2 * CELL


def components(rows):
    """Cells grouped by side contact (4-connected), as sets of (col, row) with row 0 at the top."""
    cells = {(c, r) for r, line in enumerate(rows) for c, ch in enumerate(line) if ch == "X"}
    groups, seen = [], set()
    for start in sorted(cells):
        if start in seen:
            continue
        stack, group = [start], set()
        while stack:
            c, r = stack.pop()
            if (c, r) in seen:
                continue
            seen.add((c, r)); group.add((c, r))
            for n in ((c + 1, r), (c - 1, r), (c, r + 1), (c, r - 1)):
                if n in cells and n not in seen:
                    stack.append(n)
        groups.append(group)
    return groups


def loops(group):
    """Outlines of a group of cells: lists of corner points (font orientation: y up), outer
    contours clockwise and holes counter-clockwise, as TrueType expects."""
    # Directed unit edges with the cells on the right (y up): clockwise around the solid.
    edges = {}
    for c, r in group:
        x0, x1 = c, c + 1
        y1, y0 = 5 - r, 4 - r  # y up
        if (c, r - 1) not in group:
            edges[(x0, y1)] = edges.get((x0, y1), []) + [(x1, y1)]   # top, to the right
        if (c + 1, r) not in group:
            edges[(x1, y1)] = edges.get((x1, y1), []) + [(x1, y0)]   # right side, down
        if (c, r + 1) not in group:
            edges[(x1, y0)] = edges.get((x1, y0), []) + [(x0, y0)]   # bottom, to the left
        if (c - 1, r) not in group:
            edges[(x0, y0)] = edges.get((x0, y0), []) + [(x0, y1)]   # left side, up
    out = []
    while edges:
        start = next(iter(edges))
        pts, cur = [start], start
        while True:
            nxt = edges[cur].pop()
            if not edges[cur]:
                del edges[cur]
            if nxt == start:
                break
            pts.append(nxt)
            cur = nxt
        # Keep the corners only.
        corners = []
        n = len(pts)
        for i in range(n):
            a, b, c = pts[i - 1], pts[i], pts[(i + 1) % n]
            if (b[0] - a[0], b[1] - a[1]) != (c[0] - b[0], c[1] - b[1]):
                corners.append(b)
        out.append(corners)
    return out


def draw(pen, corners, xoff):
    """One outline with rounded corners (quadratic curves), in font units."""
    n = len(corners)
    pts = [(x * CELL, y * CELL) for x, y in corners]

    def length(a, b):
        return abs(a[0] - b[0]) + abs(a[1] - b[1])

    def radius(i):
        a, b, c = pts[i - 1], pts[i], pts[(i + 1) % n]
        cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0])
        convex = cross < 0  # clockwise outline: a right turn is an outer corner
        if convex and length(a, b) >= 2 * CELL and length(b, c) >= 2 * CELL:
            return 15
        return 10

    def towards(p, q, d):
        dx = (q[0] > p[0]) - (q[0] < p[0])
        dy = (q[1] > p[1]) - (q[1] < p[1])
        return (p[0] + dx * d, p[1] + dy * d)

    def f(p):
        return (round((p[0] + xoff) * SCALE), round(p[1] * SCALE))

    for i in range(n):
        a, b, c = pts[i - 1], pts[i], pts[(i + 1) % n]
        r = radius(i)
        before, after = towards(b, a, r), towards(b, c, r)
        if i == 0:
            pen.moveTo(f(before))
        else:
            pen.lineTo(f(before))
        pen.qCurveTo(f(b), f(after))
    pen.closePath()


def main():
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    names = {ch: f"uni{ord(ch):04X}" for ch in GLYPHS}
    order = [".notdef", "space"] + [names[ch] for ch in GLYPHS]
    glyphs, metrics, cmap = {}, {}, {32: "space", 160: "space"}

    empty = TTGlyphPen(None)
    glyphs[".notdef"] = empty.glyph(); metrics[".notdef"] = (round(SPACE * SCALE), 0)
    glyphs["space"] = TTGlyphPen(None).glyph(); metrics["space"] = (round(SPACE * SCALE), 0)
    for ch, rows in GLYPHS.items():
        pen = TTGlyphPen(None)
        side = GAP / 2
        for group in components(rows):
            for corners in loops(group):
                draw(pen, corners, side)
        width = len(rows[0]) * CELL + GAP
        g = pen.glyph()
        glyphs[names[ch]] = g
        metrics[names[ch]] = (round(width * SCALE), round(side * SCALE))
        cmap[ord(ch)] = names[ch]
        if ch.isalpha():
            cmap[ord(ch.lower())] = names[ch]
    for alias, ch in ALIASES.items():
        cmap[ord(alias)] = names[ch]

    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap(cmap)
    fb.setupGlyf(glyphs)
    for name, g in glyphs.items():
        g.recalcBounds(fb.font["glyf"])
    fb.setupHorizontalMetrics({k: (w, glyphs[k].xMin if hasattr(glyphs[k], "xMin") else 0) for k, (w, _) in metrics.items()})
    fb.setupHorizontalHeader(ascent=850, descent=-150)
    fb.setupNameTable({"familyName": "Borne Blocks", "styleName": "Regular",
                       "copyright": "Borne's lettering, drawn after ui/brand/wordmark.svg"})
    fb.setupOS2(sTypoAscender=850, sTypoDescender=-150, sTypoLineGap=0, usWinAscent=850, usWinDescent=150,
                sCapHeight=round(CAP * SCALE), sxHeight=round(CAP * SCALE), achVendID="BRNE")
    fb.setupPost()
    fb.save(os.path.join(out_dir, "BorneBlocks.ttf"))
    fb.font.flavor = "woff2"
    fb.save(os.path.join(out_dir, "BorneBlocks.woff2"))


if __name__ == "__main__":
    main()
