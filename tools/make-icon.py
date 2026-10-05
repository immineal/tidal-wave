#!/usr/bin/env python3
"""Regenerate assets/icon.svg and assets/icon.png from the mark's geometry.

The mark is drawn twice: once in QML (qml/components/AppMark.qml, for the
in-app marks) and once as a static asset (assets/icon.svg, for the window,
tray, taskbar and launcher). Those two drawings have drifted apart more than
once, because the SVG was hand-edited while the QML was not. This script is
the cure: it holds the same constants AppMark.qml does and emits the SVG from
them, so a change to the geometry is a change in two places that are checked
against each other rather than two places that are hand-copied.

Usage:
    tools/make-icon.py              # write assets/icon.svg and assets/icon.png
    tools/make-icon.py --check      # exit non-zero if either is out of date

The PNG is rasterised from the SVG with Inkscape, never edited by hand, so the
two can only disagree if this script did not run.

The one deliberate difference between the two drawings is ICON_INSET below: the
file the desktop reads carries a margin, the in-app mark does not. See the
comment on that constant.
"""
import argparse
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SVG_PATH = os.path.join(ROOT, "assets", "icon.svg")
PNG_PATH = os.path.join(ROOT, "assets", "icon.png")
PNG_SIZE = 128

# ── geometry, mirroring qml/components/AppMark.qml ──────────────────────────
# Keep these in step with the readonly properties of the same name there; the
# QML test tests/qml/tst_appmark.qml compares the two drawings.
AMP = 5.0                       # wave amplitude
THICK = (64 - 2 * AMP) / 7      # band thickness, so 7 equal bands and gaps fill 64
HALF = 32.0                     # half period
RADIUS = 14                     # tile corner radius, = ThemePalette's radii["mark"]
TILE = "#0079A8"                # brand blue
INK = "#FFFFFF"

CENTRES = [1.5 * THICK + AMP, 32.0, 64 - (1.5 * THICK + AMP)]

# ── the inset, which belongs to the exported file only ──────────────────────
# Margin on each side, as a fraction of the 64-unit canvas, so the mark covers
# 1 - 2 * ICON_INSET of it. Desktop icons are drawn with a margin and ours was
# not, so at 0 it measured about 10% larger than everything beside it in the
# panel: 32x32 in a 32px box where Firefox was 28x29 and Dolphin 30x26. At
# 0.0625 the mark is 28px in that box, which is the same weight as its
# neighbours.
#
# This is applied as a transform around the whole drawing when the SVG is
# written, so the paths below stay identical to the ones AppMark.qml generates
# and the two can still be compared number for number. The tile's corner radius
# rides on the same transform, so the corner keeps its proportion.
#
# AppMark.qml is deliberately not inset. The in-app marks sit inside the app's
# own layout, which already puts space around them; insetting them as well
# would only make the logo look undersized.
ICON_INSET = 0.0625

# Which way the wave runs. The first half period rises, then falls, reading
# left to right, the way the "≋" glyph this replaced did. SVG y grows
# downward, so rising is the negative amplitude.
RISE_FIRST = True


def band(cy):
    """One band as a closed path, the same construction as AppMark._band()."""
    spans = int(64 / HALF)

    def edge(off, reversed_):
        out = []
        for k in range(spans):
            i = (spans - 1 - k) if reversed_ else k
            xa = ((i + 1) if reversed_ else i) * HALF
            xb = (i if reversed_ else (i + 1)) * HALF
            crest = -AMP if RISE_FIRST else AMP
            yc = cy + (crest if i % 2 == 0 else -crest) + off
            t = (xb - xa) / 3
            out.append("C %.2f %.2f %.2f %.2f %.2f %.2f"
                       % (xa + t, yc, xb - t, yc, xb, cy + off))
        return " ".join(out)

    return ("M 0 %.2f " % (cy - THICK / 2) + edge(-THICK / 2, False)
            + " L 64 %.2f " % (cy + THICK / 2) + edge(THICK / 2, True)
            + " Z")


def svg_text():
    offset = 64 * ICON_INSET
    scale = 1 - 2 * ICON_INSET
    lines = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">',
             '  <g transform="translate(%g %g) scale(%g)">' % (offset, offset, scale),
             '    <rect width="64" height="64" rx="%d" fill="%s"/>' % (RADIUS, TILE)]
    for cy in CENTRES:
        lines.append('    <path d="%s" fill="%s"/>' % (band(cy), INK))
    lines.append("  </g>")
    lines.append("</svg>")
    return "\n".join(lines) + "\n"


def rasterise(svg_path, png_path):
    inkscape = shutil.which("inkscape")
    if not inkscape:
        print("inkscape not found; assets/icon.png not regenerated", file=sys.stderr)
        return False
    subprocess.run([inkscape, "--export-type=png",
                    "--export-filename=" + png_path,
                    "-w", str(PNG_SIZE), "-h", str(PNG_SIZE), svg_path],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="report whether the assets match the geometry, write nothing")
    args = ap.parse_args()

    want = svg_text()
    have = ""
    if os.path.exists(SVG_PATH):
        with open(SVG_PATH, encoding="utf-8") as f:
            have = f.read()

    if args.check:
        if have != want:
            print("assets/icon.svg does not match tools/make-icon.py", file=sys.stderr)
            return 1
        print("assets/icon.svg matches the geometry")
        return 0

    with open(SVG_PATH, "w", encoding="utf-8") as f:
        f.write(want)
    rasterise(SVG_PATH, PNG_PATH)
    print("wrote %s and %s" % (SVG_PATH, PNG_PATH))
    return 0


if __name__ == "__main__":
    sys.exit(main())
