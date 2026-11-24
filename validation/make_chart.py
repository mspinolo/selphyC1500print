#!/usr/bin/env python3
"""Generates the validation chart (sRGB PNG) and its manifest.

    python3 validation/make_chart.py --out validation/charts [--width 1181]

The width is a parameter because the printer's native raster must be confirmed before the
physical test; the height follows the 100 x 148 mm format. The manifest records, for every
patch, the sRGB numbers, the rectangle in the raster and the intended Lab (D50, relative).
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageCms, ImageDraw

import chart_layout as layout
import selphy_core

CHART_VERSION = 1


def build(width=layout.DESIGN_W):
    scale = width / layout.DESIGN_W
    height = round(layout.DESIGN_H * scale)

    def s(v):
        return v * scale

    image = Image.new("RGB", (width, height), (255, 255, 255))
    draw = ImageDraw.Draw(image)
    patches = []
    for pid, group, name, rgb, (x, y, w, h) in layout.design_patches():
        rect = [round(s(x)), round(s(y)), round(s(w)), round(s(h))]
        draw.rectangle([rect[0], rect[1], rect[0] + rect[2] - 1, rect[1] + rect[3] - 1], fill=tuple(rgb))
        patches.append({"id": pid, "group": group, "name": name, "srgb": list(rgb), "rect": rect})
    fiducials = []
    for name, cx, cy, size in layout.design_fiducials():
        half = s(size) / 2
        box = [round(s(cx) - half), round(s(cy) - half), round(s(cx) + half) - 1, round(s(cy) + half) - 1]
        draw.rectangle(box, fill=(0, 0, 0))
        fiducials.append({"name": name, "centre": [s(cx), s(cy)], "size": s(size)})
    whites = [{"name": n, "rect": [round(s(v)) for v in r]} for n, r in layout.design_white_samples()]

    rgb16 = np.array([p["srgb"] for p in patches], dtype=np.uint16) * 257
    for patch, lab in zip(patches, selphy_core.source_to_lab(None, rgb16)):
        patch["lab_intended"] = [round(float(v), 4) for v in lab]
    manifest = {"chart_version": CHART_VERSION, "width": width, "height": height,
                "format_mm": [100, 148], "patches": patches, "fiducials": fiducials, "white_samples": whites,
                "note": "Intended Lab = sRGB numbers -> Lab D50, relative colorimetric, no BPC."}
    return image, manifest


def save(out_dir, width=layout.DESIGN_W):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    image, manifest = build(width)
    srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    dpi = width / (100 / 25.4)
    png = out / f"selphy_chart_v{CHART_VERSION}.png"
    image.save(png, icc_profile=srgb, dpi=(dpi, dpi), optimize=True)
    (out / f"selphy_chart_v{CHART_VERSION}.json").write_text(json.dumps(manifest, indent=1) + "\n")
    return png


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default="validation/charts")
    parser.add_argument("--width", type=int, default=layout.DESIGN_W)
    args = parser.parse_args()
    print(save(args.out, args.width))
