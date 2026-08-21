#!/usr/bin/env python3
"""Draws a harmonograph, one frame at a time, into a folder cuttr can read.

A harmonograph is four decaying sines: two pendulums swinging across each other,
one moving the paper and one moving the pen. It is here because it is the
cheapest possible demonstration of the point a `frames:` overlay makes — a
picture arriving already drawn, from something that is not cuttr and is not a
browser either. This is a hundred lines of Python with nothing but the standard
library, and cuttr cannot tell the difference between its output and Remotion's.

    tools/frames/harmonograph.py examples/frames/harmonograph

Nothing runs this automatically. The frames are committed, because they are a
few kilobytes each; this is here so that they are reproducible rather than
merely present.
"""

import math
import os
import struct
import sys
import zlib

SIZE = 480
FRAMES = 36
# Two seconds' worth of pendulum per frame of the sequence, so the whole curve
# is drawn by the last frame and each frame adds a visible arc.
SPAN = 58.0
# Enough samples that the curve is a line rather than a dotted one. Cheap: the
# whole sequence is under a second of arithmetic.
SAMPLES_PER_UNIT = 900

# The pendulums: amplitude, frequency, phase, decay. Frequencies close to whole
# ratios are what makes the figure nearly close on itself and then drift, which
# is the whole charm of the thing. The amplitudes add up to less than a half,
# because a half is the edge of the paper and a pendulum that swings off it
# draws nothing.
PENS = (
    (0.26, 2.001, 0.00, 0.0042),
    (0.20, 3.003, 1.57, 0.0035),
)
PAPER = (
    (0.25, 2.997, 0.00, 0.0039),
    (0.20, 1.999, 1.05, 0.0031),
)

# Warm at the start of the curve, cool at the end, so the order it was drawn in
# is legible in a still frame.
FROM = (0.98, 0.71, 0.37)
TO = (0.44, 0.80, 0.94)


def point(t):
    x = sum(a * math.sin(f * t + p) * math.exp(-d * t) for a, f, p, d in PENS)
    y = sum(a * math.sin(f * t + p) * math.exp(-d * t) for a, f, p, d in PAPER)
    return (0.5 + x) * (SIZE - 1), (0.5 + y) * (SIZE - 1)


def splat(coverage, tint, x, y, shade):
    """One sample, spread over the four pixels it falls between."""
    # Floor rather than truncate: `int(-0.4)` is nought, which would give the
    # neighbouring pixel a negative share of the sample.
    left, bottom = math.floor(x), math.floor(y)
    fx, fy = x - left, y - bottom
    for dx, dy, weight in (
        (0, 0, (1 - fx) * (1 - fy)),
        (1, 0, fx * (1 - fy)),
        (0, 1, (1 - fx) * fy),
        (1, 1, fx * fy),
    ):
        px, py = left + dx, bottom + dy
        if 0 <= px < SIZE and 0 <= py < SIZE:
            index = py * SIZE + px
            coverage[index] = min(1.0, coverage[index] + weight * 0.5)
            # The colour of the newest sample wins, which is what a pen does.
            tint[index] = shade


def png(path, coverage, tint):
    rows = bytearray()
    for y in range(SIZE - 1, -1, -1):
        rows.append(0)   # no filter on this scanline
        for x in range(SIZE):
            index = y * SIZE + x
            alpha = coverage[index]
            shade = tint[index]
            red = FROM[0] + (TO[0] - FROM[0]) * shade
            green = FROM[1] + (TO[1] - FROM[1]) * shade
            blue = FROM[2] + (TO[2] - FROM[2]) * shade
            # Straight alpha, which is what PNG carries and what cuttr reads.
            rows += bytes((int(red * 255), int(green * 255), int(blue * 255),
                           int(alpha * 255)))

    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff))

    with open(path, "wb") as out:
        out.write(b"\x89PNG\r\n\x1a\n")
        out.write(chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)))
        out.write(chunk(b"IDAT", zlib.compress(bytes(rows), 9)))
        out.write(chunk(b"IEND", b""))


def main():
    folder = sys.argv[1] if len(sys.argv) > 1 else "examples/frames/harmonograph"
    os.makedirs(folder, exist_ok=True)
    coverage = [0.0] * (SIZE * SIZE)
    tint = [0.0] * (SIZE * SIZE)
    step = SPAN / FRAMES
    samples = int(step * SAMPLES_PER_UNIT)
    for frame in range(FRAMES):
        for sample in range(samples):
            t = frame * step + step * sample / samples
            x, y = point(t)
            splat(coverage, tint, x, y, t / SPAN)
        path = os.path.join(folder, "%04d.png" % frame)
        png(path, coverage, tint)
        print(path)


if __name__ == "__main__":
    main()
