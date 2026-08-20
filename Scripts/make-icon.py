#!/usr/bin/env python3
"""Draws the app icon: `caret`.

Two bars of text in the camera-blue and recorder-amber of the waveform lanes,
with a red block cursor parked at the end of the second. It says the thing the
program claims — that a cut is a piece of text — in three rectangles, and three
rectangles are what survives being drawn sixteen pixels wide in a menu bar. The
icon it replaces was a faithful little picture of the app's own timeline, two
recorded waveforms and a playhead, and recorded noise is exactly what a
downsample destroys: at 32px it was grey soup.

Written in the standard library, like everything else here: an icon that needs a
`pip install` to regenerate is an icon nobody regenerates.

    python3 Scripts/make-icon.py
"""
import math
import os
import struct
import subprocess
import zlib

SIZE = 1024
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_DIR = os.path.join(ROOT, "Resources", "Icon")

# The geometry, in the 0–100 square the concept was drawn in, scaled up here.
# Kept in those numbers so it can be checked against the design page directly.
BACKGROUND = (0x19, 0x1B, 0x1F)
# Written as they were drawn, then centred: the three of them together span
# x 12–76 and y 30–76, which leaves twice as much room on the right as on the
# left and a little more above than below. Somebody noticed, and at the size an
# icon is actually seen — sixteen points in a menu bar, a thumbnail in a dock —
# six units of a hundred is the difference between "off" and "drawn".
SHAPES = [
    # x,  y,   w,   h,    r,    colour                  what
    (12, 30, 64, 15, 7.5, (0x6B, 0x9E, 0xD9)),  # the camera lane's blue
    (12, 56, 38, 15, 7.5, (0xF2, 0xB8, 0x52)),  # the recorder lane's amber
    (57, 51, 19, 25, 2.0, (0xF2, 0x4C, 0x59)),  # the playhead red, as a cursor
]

def centred(shapes):
    """The same shapes, with equal air on all four sides."""
    left = min(x for x, _, _, _, _, _ in shapes)
    right = max(x + w for x, _, w, _, _, _ in shapes)
    top = min(y for _, y, _, _, _, _ in shapes)
    bottom = max(y + h for _, y, _, h, _, _ in shapes)
    dx = (100 - (left + right)) / 2
    dy = (100 - (top + bottom)) / 2
    return [(x + dx, y + dy, w, h, r, colour) for x, y, w, h, r, colour in shapes]


SHAPES = centred(SHAPES)
CORNER = 22.5

# Four sub-rows a pixel, and exact horizontal extents within each. Enough
# anti-aliasing to look drawn rather than stepped, without the sixteen million
# point-in-shape tests a naive supersample would need — a rounded rectangle's
# extent at a given height is arithmetic, so each sub-row is one interval per
# shape rather than a thousand tests.
SUBSAMPLES = 4


def extent(y, x0, y0, w, h, r):
    """The [left, right] a rounded rectangle covers at height `y`, or None."""
    if y < y0 or y >= y0 + h:
        return None
    inset = 0.0
    if y < y0 + r:
        d = (y0 + r) - y
        inset = r - math.sqrt(max(r * r - d * d, 0.0))
    elif y > y0 + h - r:
        d = y - (y0 + h - r)
        inset = r - math.sqrt(max(r * r - d * d, 0.0))
    return (x0 + inset, x0 + w - inset)


def add_span(row, left, right, weight):
    """Accumulates coverage over a fractional interval."""
    if right <= left:
        return
    first, last = int(math.floor(left)), int(math.ceil(right))
    for x in range(max(first, 0), min(last, SIZE)):
        covered = min(right, x + 1) - max(left, x)
        if covered > 0:
            row[x] += covered * weight


def draw():
    scale = SIZE / 100.0
    rows = []
    for py in range(SIZE):
        # One coverage row per shape, plus the background, then composited in
        # order — so the cursor sits over the amber bar the way it does in the
        # drawing rather than being blended with it.
        coverage = [[0.0] * SIZE for _ in range(len(SHAPES) + 1)]
        for sub in range(SUBSAMPLES):
            y = (py + (sub + 0.5) / SUBSAMPLES) / scale
            span = extent(y, 0, 0, 100, 100, CORNER)
            if span:
                add_span(coverage[0], span[0] * scale, span[1] * scale, 1.0 / SUBSAMPLES)
            for index, (x0, y0, w, h, r, _) in enumerate(SHAPES):
                span = extent(y, x0, y0, w, h, r)
                if span:
                    add_span(coverage[index + 1], span[0] * scale, span[1] * scale, 1.0 / SUBSAMPLES)

        row = bytearray()
        for px in range(SIZE):
            alpha = min(coverage[0][px], 1.0)
            if alpha <= 0:
                row += bytes((0, 0, 0, 0))
                continue
            colour = list(BACKGROUND)
            for index, shape in enumerate(SHAPES):
                # Clipped to the rounded square, so nothing leans out of a
                # corner at any size.
                a = min(coverage[index + 1][px], 1.0) * alpha
                if a > 0:
                    colour = [c * (1 - a) + s * a for c, s in zip(colour, shape[5])]
            row += bytes(int(round(c)) for c in colour) + bytes((int(round(alpha * 255)),))
        rows.append(row)
    return rows


def write_png(path, rows):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)

    def chunk(tag, payload):
        data = tag + payload
        return struct.pack(">I", len(payload)) + data + struct.pack(">I", zlib.crc32(data))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


def main():
    os.makedirs(ICON_DIR, exist_ok=True)
    source = os.path.join(ICON_DIR, "icon-1024.png")
    write_png(source, draw())
    print("==> " + source)

    iconset = os.path.join(ICON_DIR, "cuttr.iconset")
    os.makedirs(iconset, exist_ok=True)
    for size in (16, 32, 64, 128, 256, 512, 1024):
        for scale, name in ((1, "%dx%d" % (size, size)), (2, "%dx%d@2x" % (size // 2, size // 2))):
            if scale == 2 and size == 16:
                continue
            target = os.path.join(iconset, "icon_%s.png" % name)
            subprocess.run(["sips", "-z", str(size), str(size), source, "--out", target],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    icns = os.path.join(ICON_DIR, "cuttr.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    print("==> " + icns)


if __name__ == "__main__":
    main()
