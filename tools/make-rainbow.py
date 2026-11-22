#!/usr/bin/env python3
"""Regenerate the glass rainbow behind the colour switch (qml/components/Toggle.qml).

The checked track of "Let the colour in" is this picture. Where Qt draws
shaders, assets/toggle-rainbow.frag bends it while the switch flips and
drifts; at rest it draws it unchanged, and the software renderer shows it as
it is. The picture is computed here in floating point and dithered once, so
its gradients carry no 8-bit bands.

Usage:
    tools/make-rainbow.py            # write assets/toggle-rainbow{,@2x,@3x}.png
    tools/make-rainbow.py --check    # exit non-zero if a committed file is stale

Only the Python standard library is used, so the check runs wherever CMake
finds a Python 3.

The look, outside in: a faint glow past the track, a rim where the colour
thins into the ground, and a body whose hues crowd towards the rim, as a
thick glass rod bends what lies behind it. A soft sheen follows the upper
rim. The knob is drawn by QML on top.
"""
import argparse
import math
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets")

# ── geometry, in logical pixels ──────────────────────────────────────────
# Toggle.qml's implicit size; the track is a full pill.
TRACK_W = 38.0
TRACK_H = 22.0
RADIUS = TRACK_H / 2
# How far the glow reaches past the track on every side. Toggle.qml places
# the image this far out, so the two numbers must change together.
PAD = 4
SCALES = (1, 2, 3)

# ── look ─────────────────────────────────────────────────────────────────
# Where the hues start and end along the track. Past these the strip holds
# its end colour, so the crowding at the rim stops on red at both ends.
HUE_X0 = 1.5
HUE_X1 = TRACK_W - 1.5
# How far the glass shifts what is behind it at the rim, in pixels: outward
# along the rim's normal, and along the track away from its middle.
LENS = 8.0
SWEEP = 5.0
# The opacity, against the distance past FADE_START: a stretched exponential,
# half at the rim and a tenth 2px out, then a soft cut at the end of PAD.
# One smooth curve, so no knee shows as a ring where the body meets the glow.
FADE_START = RADIUS - 2.0
FADE_WIDTH = 2.47
FADE_POWER = 1.73
# The sheen along the upper rim and a fainter caustic along the lower one.
SHEEN = 0.38
SHEEN_DEPTH = 3.0
SHEEN_WIDTH = 1.7
CAUSTIC = 0.14
CAUSTIC_DEPTH = 2.3
CAUSTIC_WIDTH = 1.3

# The hues along the strip as (t, L, C, h) in OKLCH, red to red by way
# of yellow, green, blue and magenta. Yellow is kept light, lemon rather than
# amber; blue is kept deep so the white knob stands out on it.
STOPS = [
    (0.000, 0.640, 0.230, 27.0),
    (0.100, 0.740, 0.195, 52.0),
    (0.150, 0.810, 0.180, 74.0),
    (0.225, 0.930, 0.200, 108.0),
    (0.360, 0.850, 0.235, 145.0),
    (0.520, 0.780, 0.150, 210.0),
    (0.660, 0.580, 0.220, 262.0),
    (0.800, 0.650, 0.290, 325.0),
    (0.910, 0.660, 0.260, 355.0),
    (1.000, 0.640, 0.240, 375.0),
]


# ── colour ───────────────────────────────────────────────────────────────
def oklab_to_linear(L, a, b):
    """Ottosson's OKLab to linear sRGB."""
    l_ = L + 0.3963377774 * a + 0.2158037573 * b
    m_ = L - 0.1055613458 * a - 0.0638541728 * b
    s_ = L - 0.0894841775 * a - 1.2914855480 * b
    l, m, s = l_ ** 3, m_ ** 3, s_ ** 3
    return (
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    )


def encode(c):
    c = min(max(c, 0.0), 1.0)
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def fits(rgb):
    return all(-1e-6 <= v <= 1 + 1e-6 for v in rgb)


def clip_chroma(L, a, b):
    """The colour of lightness L and hue atan2(b, a) with the most chroma, up
    to that of (a, b), that sRGB can show; as linear sRGB."""
    rgb = oklab_to_linear(L, a, b)
    if fits(rgb):
        return rgb
    lo, hi = 0.0, 1.0
    for _ in range(30):
        mid = (lo + hi) / 2
        if fits(oklab_to_linear(L, a * mid, b * mid)):
            lo = mid
        else:
            hi = mid
    return oklab_to_linear(L, a * lo, b * lo)


def linear_to_oklab(r, g, b):
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


def catmull(p0, p1, p2, p3, u):
    return 0.5 * (2 * p1 + (p2 - p0) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u * u
                  + (3 * p1 - p0 - 3 * p2 + p3) * u * u * u)


def raw_colour(t):
    """OKLab at t along the stops, clipped into sRGB."""
    k = 0
    while k < len(STOPS) - 2 and t > STOPS[k + 1][0]:
        k += 1
    t0, t1 = STOPS[k][0], STOPS[k + 1][0]
    u = (t - t0) / (t1 - t0)
    pts = [STOPS[max(k - 1, 0)], STOPS[k], STOPS[k + 1], STOPS[min(k + 2, len(STOPS) - 1)]]
    L = catmull(*(p[1] for p in pts), u)
    C = max(catmull(*(p[2] for p in pts), u), 0.0)
    h = math.radians(catmull(*(p[3] for p in pts), u))
    rgb = clip_chroma(L, C * math.cos(h), C * math.sin(h))
    return linear_to_oklab(*(max(v, 0.0) for v in rgb))


def build_strip():
    """The strip as a table of encoded sRGB. Clipping to the gamut leaves a
    corner at each primary, which the eye sees as a line; a blur in OKLab
    along the strip rounds them off."""
    raw = [raw_colour(i / (STRIP_N - 1)) for i in range(STRIP_N)]
    sigma = STRIP_BLUR * (STRIP_N - 1)
    reach = int(3 * sigma)
    weights = [math.exp(-0.5 * (k / sigma) ** 2) for k in range(-reach, reach + 1)]
    table = []
    for i in range(STRIP_N):
        acc, wsum = [0.0, 0.0, 0.0], 0.0
        for k, w in zip(range(-reach, reach + 1), weights):
            c = raw[min(max(i + k, 0), STRIP_N - 1)]
            for j in range(3):
                acc[j] += w * c[j]
            wsum += w
        L, a, b = (v / wsum for v in acc)
        table.append(tuple(encode(v) for v in clip_chroma(L, a, b)))
    return table


STRIP_N = 512
STRIP_BLUR = 0.02
STRIP = build_strip()


def strip_colour(t):
    """Encoded sRGB at t in 0..1 along the strip; the ends hold."""
    f = min(max(t, 0.0), 1.0) * (STRIP_N - 1)
    i = min(int(f), STRIP_N - 2)
    u = f - i
    return tuple(p + (q - p) * u for p, q in zip(STRIP[i], STRIP[i + 1]))


def smoothstep(e0, e1, x):
    x = min(max((x - e0) / (e1 - e0), 0.0), 1.0)
    return x * x * (3 - 2 * x)


# ── the picture ──────────────────────────────────────────────────────────
def shade(x, y):
    """Straight-alpha RGBA in 0..1 at track point (x, y)."""
    # Nearest point on the pill's spine, and the way out from it.
    qx = min(max(x, RADIUS), TRACK_W - RADIUS)
    vx, vy = x - qx, y - RADIUS
    s = math.hypot(vx, vy)
    nx, ny = (vx / s, vy / s) if s > 1e-9 else (0.0, 0.0)

    # Through a rod of round section the shift grows with the slope of the
    # glass, so the hues crowd into the rim. Past the rim it holds.
    rho = min(s / RADIUS, 1.0)
    bend = 1.0 - math.sqrt(1.0 - rho * rho)
    sweep = (x - TRACK_W / 2) / (TRACK_W / 2 - RADIUS)
    t = (x + bend * (LENS * nx + SWEEP * sweep) - HUE_X0) / (HUE_X1 - HUE_X0)
    r, g, b = strip_colour(t)

    inside = RADIUS - s
    sheen = SHEEN * math.exp(-((inside - SHEEN_DEPTH) / SHEEN_WIDTH) ** 2) * max(-ny, 0.0) ** 3
    caustic = CAUSTIC * math.exp(-((inside - CAUSTIC_DEPTH) / CAUSTIC_WIDTH) ** 2) * max(ny, 0.0) ** 2
    lift = min(sheen + caustic, 1.0)
    r, g, b = (c + (1.0 - c) * lift for c in (r, g, b))

    past = max(s - FADE_START, 0.0)
    alpha = math.exp(-(past / FADE_WIDTH) ** FADE_POWER)
    alpha *= 1.0 - smoothstep(RADIUS + PAD - 1.5, RADIUS + PAD, s)
    return r, g, b, alpha


def noise(ix, iy, ch, salt):
    """A fixed hash in [0, 1), the same on every machine."""
    h = (ix * 73856093) ^ (iy * 19349663) ^ (ch * 83492791) ^ (salt * 2654435761)
    h &= 0xFFFFFFFF
    h ^= h >> 16
    h = (h * 0x7FEB352D) & 0xFFFFFFFF
    h ^= h >> 15
    h = (h * 0x846CA68B) & 0xFFFFFFFF
    h ^= h >> 16
    return h / 4294967296.0


def render(scale):
    """Rows of 8-bit RGBA bytes at `scale` pixels per logical pixel."""
    w = int(round((TRACK_W + 2 * PAD) * scale))
    h = int(round((TRACK_H + 2 * PAD) * scale))
    rows = []
    for iy in range(h):
        row = bytearray()
        for ix in range(w):
            # 3x3 supersampling, so each pixel is an area average.
            acc = [0.0, 0.0, 0.0, 0.0]
            for sy in range(3):
                for sx in range(3):
                    x = (ix + (sx + 0.5) / 3) / scale - PAD
                    y = (iy + (sy + 0.5) / 3) / scale - PAD
                    r, g, b, a = shade(x, y)
                    acc[0] += r * a
                    acc[1] += g * a
                    acc[2] += b * a
                    acc[3] += a
            a = acc[3] / 9
            rgb = [c / acc[3] if acc[3] > 0 else 0.0 for c in acc[:3]]
            # Triangular dither of one step, so no gradient shows 8-bit bands.
            for ch, v in enumerate(rgb + [a]):
                if a <= 0.0:
                    row.append(0)
                    continue
                d = noise(ix, iy, ch, scale) + noise(ix, iy, ch, scale + 17) - 1.0
                row.append(min(max(int(math.floor(v * 255 + 0.5 + d)), 0), 255))
        rows.append(bytes(row))
    return w, h, rows


# ── PNG ──────────────────────────────────────────────────────────────────
def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def write_png(path, w, h, rows):
    raw = b"".join(b"\x00" + r for r in rows)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def read_png(path):
    """8-bit RGBA PNG to (w, h, rows); any filter type, as an optimiser may
    have rewritten them."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        n, = struct.unpack(">I", data[pos:pos + 4])
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + n]
        if tag == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
            if depth != 8 or ctype != 6 or body[12] != 0:
                raise ValueError("not 8-bit RGBA, non-interlaced")
        elif tag == b"IDAT":
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride, bpp, rows, prev = w * 4, 4, [], bytearray(w * 4)
    for y in range(h):
        ftype = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if ftype == 1:
                line[i] = (line[i] + a) & 0xFF
            elif ftype == 2:
                line[i] = (line[i] + b) & 0xFF
            elif ftype == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif ftype == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        rows.append(bytes(line))
        prev = line
    return w, h, rows


def path_for(scale):
    suffix = "" if scale == 1 else "@%dx" % scale
    return os.path.join(ASSETS, "toggle-rainbow%s.png" % suffix)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--check", action="store_true",
                    help="compare with the committed files instead of writing them")
    args = ap.parse_args()

    stale = []
    for scale in SCALES:
        w, h, rows = render(scale)
        path = path_for(scale)
        if not args.check:
            write_png(path, w, h, rows)
            print("wrote", os.path.relpath(path, ROOT))
            continue
        try:
            cw, ch, crows = read_png(path)
        except (OSError, ValueError) as e:
            stale.append("%s: %s" % (os.path.relpath(path, ROOT), e))
            continue
        if (cw, ch) != (w, h):
            stale.append("%s: %dx%d, expected %dx%d" % (os.path.relpath(path, ROOT), cw, ch, w, h))
            continue
        # One step of slack: another libm may round a value the other way.
        worst = max(abs(p - q) for r1, r2 in zip(rows, crows) for p, q in zip(r1, r2))
        if worst > 1:
            stale.append("%s: off by up to %d" % (os.path.relpath(path, ROOT), worst))
    if stale:
        print("stale, run tools/make-rainbow.py:\n  " + "\n  ".join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
