#!/usr/bin/env python3
"""Compare two sets of store screenshots pixel by pixel.

    compare-store.py REF FRESH [--diffs DIR] [--label TEXT]

REF and FRESH are path patterns with {} where the scene name goes, e.g.
assets/screenshot_{}.png and tests/visual/out/store_{}_sea.png. A scene fails
when the sizes differ or when more than --max-pixels pixels differ by more
than --fuzz in any channel. For every scene that differs at all, DIR gets
diff_<scene>.png: FRESH greyed out, the pixels over --fuzz in red.

Prints one line per scene and a GitHub ::error:: naming each failing pair.
Exit 0 when all pass, 1 when any fails, 2 when a file is missing.
"""

import argparse
import os
import sys

from PIL import Image, ImageChops

SCENES = ("home", "collection", "album", "nowplaying", "search")

# Two draws in a row match pixel for pixel, and release.yml checks that. This
# leaves room for antialiasing drift and still fails on one changed glyph.
FUZZ = 24
MAX_PIXELS = 16


def compare(ref_path, fresh_path, fuzz, diff_path):
    ref = Image.open(ref_path).convert("RGB")
    fresh = Image.open(fresh_path).convert("RGB")
    if ref.size != fresh.size:
        return {"size": (ref.size, fresh.size)}

    delta = ImageChops.difference(ref, fresh)
    # Largest channel difference per pixel.
    r, g, b = delta.split()
    peak = ImageChops.lighter(ImageChops.lighter(r, g), b)
    hist = peak.histogram()
    changed = sum(hist[1:])
    over = sum(hist[fuzz + 1:])
    stats = {
        "changed": changed,
        "over": over,
        "max": max((i for i, n in enumerate(hist) if n), default=0),
        "box": peak.point(lambda v: 255 if v > fuzz else 0).getbbox(),
    }
    if changed and diff_path:
        mask = peak.point(lambda v: 255 if v > fuzz else 0)
        grey = fresh.convert("L").point(lambda v: 64 + v // 3).convert("RGB")
        grey.paste((230, 30, 40), mask=mask)
        grey.save(diff_path)
    return stats


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("ref")
    ap.add_argument("fresh")
    ap.add_argument("--diffs", help="directory for diff_<scene>.png")
    ap.add_argument("--fuzz", type=int, default=FUZZ,
                    help="channel difference (0-255) a pixel may have and still match")
    ap.add_argument("--max-pixels", type=int, default=MAX_PIXELS,
                    help="pixels over --fuzz a scene may have and still pass")
    ap.add_argument("--label", default="",
                    help="what the comparison is, for the error lines")
    args = ap.parse_args()

    if args.diffs:
        os.makedirs(args.diffs, exist_ok=True)

    failed, missing = [], []
    for scene in SCENES:
        ref_path = args.ref.replace("{}", scene)
        fresh_path = args.fresh.replace("{}", scene)
        absent = [p for p in (ref_path, fresh_path) if not os.path.isfile(p)]
        if absent:
            missing += absent
            continue
        diff_path = (os.path.join(args.diffs, "diff_%s.png" % scene)
                     if args.diffs else None)
        s = compare(ref_path, fresh_path, args.fuzz, diff_path)
        if "size" in s:
            (rw, rh), (fw, fh) = s["size"]
            print("%-10s size %dx%d against %dx%d" % (scene, rw, rh, fw, fh))
            failed.append((ref_path, fresh_path, "is %dx%d, the fresh one %dx%d"
                           % (rw, rh, fw, fh)))
            continue
        ok = s["over"] <= args.max_pixels
        print("%-10s %s  %7d pixels differ, %7d by more than %d, largest %3d, box %s"
              % (scene, "pass" if ok else "FAIL", s["changed"], s["over"],
                 args.fuzz, s["max"], s["box"]))
        if not ok:
            failed.append((ref_path, fresh_path, "%d pixels differ by more than %d"
                           % (s["over"], args.fuzz)))

    label = args.label + ": " if args.label else ""
    for path in missing:
        print("::error::%s%s is missing" % (label, path))
    for ref_path, fresh_path, why in failed:
        print("::error file=%s::%s%s does not match %s: %s"
              % (ref_path, label, ref_path, fresh_path, why))
    if missing:
        return 2
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
