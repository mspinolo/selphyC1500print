#!/usr/bin/env python3
"""Measures a scanned print of the validation chart against the intended values.

    python3 validation/analyze_scan.py scan.tif --manifest validation/charts/selphy_chart_v1.json \
        --label V1 --out results [--scanner-icc scanner.icc]

The scan must be a TIFF without automatic corrections. The scanner profile is read from the
TIFF if embedded, otherwise given with --scanner-icc. Orientation does not matter (the large
corner mark identifies the top-left); a rotation of a few degrees or 90 degree steps is fine.
"""
import argparse
import csv
import json
import math
from pathlib import Path

import numpy as np
import tifffile
from scipy import ndimage
from scipy.spatial import ConvexHull

import selphy_core

ICC_TAG = 34675
NEUTRAL_GROUPS = ("grey", "dark")


class ScanError(RuntimeError):
    pass


def read_scan(path):
    with tifffile.TiffFile(path) as tif:
        page = tif.pages[0]
        data = page.asarray()
        tag = page.tags.get(ICC_TAG)
        icc = bytes(tag.value) if tag is not None else None
    if data.ndim == 3 and data.shape[0] in (3, 4) and data.shape[0] < data.shape[-1]:
        data = np.moveaxis(data, 0, -1)
    if data.ndim != 3 or data.shape[2] < 3:
        raise ScanError("The scan must be an RGB TIFF.")
    data = data[..., :3]
    if data.dtype == np.uint8:
        data = data.astype(np.uint16) * 257
    elif data.dtype != np.uint16:
        raise ScanError(f"Unsupported TIFF sample type {data.dtype}; use 8 or 16 bit.")
    return data, icc


def _downsample(rgb, target=1400):
    factor = max(1, int(max(rgb.shape[:2]) // target))
    h, w = (rgb.shape[0] // factor) * factor, (rgb.shape[1] // factor) * factor
    small = rgb[:h, :w].reshape(h // factor, factor, w // factor, factor, 3).mean(axis=(1, 3))
    return small.astype(np.uint16), factor


def find_fiducials(rgb, icc, manifest):
    """Locates the 4 corner marks; returns centres in full-resolution pixels, in chart order
    (top-left, top-right, bottom-right, bottom-left)."""
    small, factor = _downsample(rgb)
    lab = selphy_core.source_to_lab(icc, small.reshape(-1, 3)).reshape(small.shape)
    dark = lab[..., 0] < 35
    labels, count = ndimage.label(dark)
    candidates = []
    centres = ndimage.center_of_mass(dark, labels, range(1, count + 1)) if count else []
    for index, sl in enumerate(ndimage.find_objects(labels), start=1):
        h, w = sl[0].stop - sl[0].start, sl[1].stop - sl[1].start
        area = int((labels[sl] == index).sum())
        if area < 12 or not 0.75 < w / h < 1.33 or area / (w * h) < 0.8:
            continue
        cy, cx = centres[index - 1]
        candidates.append((cx, cy, area, w, h))
    if len(candidates) < 4:
        raise ScanError("Fewer than 4 corner marks found: check that the whole print is in the scan.")
    pts = np.array([[c[0], c[1]] for c in candidates])
    hull = list(ConvexHull(pts).vertices) if len(pts) > 4 else list(range(len(pts)))
    best, best_area = None, -1.0
    from itertools import combinations
    for combo in combinations(hull, 4):
        quad = pts[list(combo)]
        centre = quad.mean(axis=0)
        order = np.argsort(np.arctan2(quad[:, 1] - centre[1], quad[:, 0] - centre[0]))
        q = quad[order]
        area = 0.5 * abs(sum(q[i, 0] * q[(i + 1) % 4, 1] - q[(i + 1) % 4, 0] * q[i, 1] for i in range(4)))
        if area > best_area:
            best, best_area = [combo[i] for i in order], area
    marks = [candidates[i] for i in best]            # clockwise on screen (y down)
    areas = [m[2] for m in marks]
    big = int(np.argmax(areas))
    others = sorted(a for i, a in enumerate(areas) if i != big)
    ratio = areas[big] / np.mean(others)
    if not 1.5 < ratio < 3.2:
        raise ScanError(f"The large corner mark is not clearly identified (area ratio {ratio:.2f}).")
    ordered = [marks[(big + k) % 4] for k in range(4)]
    centres = np.array([[m[0] * factor + factor / 2, m[1] * factor + factor / 2] for m in ordered])

    chart = np.array([f["centre"] for f in manifest["fiducials"]])
    scan_w = np.linalg.norm(centres[1] - centres[0]), np.linalg.norm(centres[2] - centres[3])
    chart_w = np.linalg.norm(chart[1] - chart[0])
    scan_h = np.linalg.norm(centres[3] - centres[0]), np.linalg.norm(centres[2] - centres[1])
    chart_h = np.linalg.norm(chart[3] - chart[0])
    ratio_scan = np.mean(scan_w) / np.mean(scan_h)
    if abs(ratio_scan / (chart_w / chart_h) - 1) > 0.04:
        raise ScanError("The corner marks do not form the expected rectangle: check the scan.")
    return centres, chart


def homography(src, dst):
    """3x3 matrix mapping src points to dst (DLT, 4 points)."""
    rows = []
    for (x, y), (u, v) in zip(src, dst):
        rows.append([x, y, 1, 0, 0, 0, -u * x, -u * y, -u])
        rows.append([0, 0, 0, x, y, 1, -v * x, -v * y, -v])
    _, _, vt = np.linalg.svd(np.array(rows, dtype=np.float64))
    return vt[-1].reshape(3, 3) / vt[-1, 8]


def map_points(h, pts):
    pts = np.asarray(pts, dtype=np.float64)
    ones = np.ones((len(pts), 1))
    mapped = np.hstack([pts, ones]) @ h.T
    return mapped[:, :2] / mapped[:, 2:3]


def sample_rect(rgb, h, rect, inner=0.6, n=14):
    x, y, w, hh = rect
    xs = x + w * (0.5 + (np.linspace(0, 1, n) - 0.5) * inner)
    ys = y + hh * (0.5 + (np.linspace(0, 1, n) - 0.5) * inner)
    grid = np.array([(a, b) for b in ys for a in xs])
    scan = np.rint(map_points(h, grid)).astype(int)
    scan[:, 0] = scan[:, 0].clip(0, rgb.shape[1] - 1)
    scan[:, 1] = scan[:, 1].clip(0, rgb.shape[0] - 1)
    values = rgb[scan[:, 1], scan[:, 0]]
    return np.median(values, axis=0).astype(np.uint16)


def analyse(scan_path, manifest, label, scanner_icc=None):
    rgb, embedded = read_scan(scan_path)
    icc = scanner_icc or embedded
    if icc is None:
        raise ScanError("No scanner profile: embed it in the TIFF or pass --scanner-icc.")
    scan_pts, chart_pts = find_fiducials(rgb, icc, manifest)
    h = homography(chart_pts, scan_pts)

    white_samples = [sample_rect(rgb, h, w["rect"]) for w in manifest["white_samples"]]
    white_lab = np.median(selphy_core.source_to_lab(icc, np.array(white_samples)), axis=0)

    patches = manifest["patches"]
    samples = np.array([sample_rect(rgb, h, p["rect"]) for p in patches])
    lab_abs = selphy_core.source_to_lab(icc, samples)
    lab = selphy_core.normalise_to_paper_white(lab_abs, white_lab)
    intended = np.array([p["lab_intended"] for p in patches])
    de = selphy_core.delta_e2000(lab, intended)

    result = {"label": label, "scan": str(scan_path), "paper_white_lab": [round(float(v), 3) for v in white_lab],
              "patches": []}
    for p, m, d in zip(patches, lab, de):
        result["patches"].append({"id": p["id"], "group": p["group"], "name": p["name"], "srgb": p["srgb"],
                                  "intended_lab": p["lab_intended"], "measured_lab": [round(float(v), 3) for v in m],
                                  "de00": round(float(d), 3)})
    result["summary"] = summarise(result["patches"])
    return result


def stats(values):
    v = np.asarray(values, dtype=np.float64)
    return {"mean": round(float(v.mean()), 3), "median": round(float(np.median(v)), 3),
            "p95": round(float(np.percentile(v, 95)), 3), "max": round(float(v.max()), 3), "n": int(len(v))}


def summarise(patches):
    scored = [p for p in patches if p["group"] != "uniformity"]
    summary = {"all": stats([p["de00"] for p in scored])}
    for group in sorted({p["group"] for p in scored}):
        summary[group] = stats([p["de00"] for p in scored if p["group"] == group])
    # Neutral axis: residual chroma of the grey/dark steps that are not near black.
    neutral = [math.hypot(p["measured_lab"][1], p["measured_lab"][2]) for p in scored
               if p["group"] in NEUTRAL_GROUPS and p["measured_lab"][0] >= 25]
    summary["neutral_chroma_p95"] = round(float(np.percentile(neutral, 95)), 3) if neutral else None
    # Shadow separation: adjacent dark steps that are still distinguishable (dE00 >= 1).
    dark = sorted((p for p in scored if p["group"] == "dark"), key=lambda p: p["srgb"][0])
    gaps = selphy_core.delta_e2000([p["measured_lab"] for p in dark[:-1]], [p["measured_lab"] for p in dark[1:]])
    summary["dark_steps_distinguishable"] = int((gaps >= 1.0).sum()) + 1
    summary["dark_steps_total"] = len(dark)
    grey = [p["measured_lab"] for p in patches if p["group"] == "uniformity"]
    if len(grey) > 1:
        pair = [selphy_core.delta_e2000(a, b)[0] for i, a in enumerate(grey) for b in grey[i + 1:]]
        summary["uniformity_de00_max"] = round(float(max(pair)), 3)
    return summary


def write_outputs(result, out_dir):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    stem = f"results_{result['label']}"
    (out / f"{stem}.json").write_text(json.dumps(result, indent=1) + "\n")
    with open(out / f"{stem}.csv", "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["id", "group", "name", "R", "G", "B", "L_intended", "a_intended", "b_intended",
                         "L_measured", "a_measured", "b_measured", "dE00"])
        for p in result["patches"]:
            writer.writerow([p["id"], p["group"], p["name"], *p["srgb"], *p["intended_lab"], *p["measured_lab"], p["de00"]])
    return out / f"{stem}.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("scan")
    parser.add_argument("--manifest", default="validation/charts/selphy_chart_v1.json")
    parser.add_argument("--label", required=True, help="variant label, e.g. V0")
    parser.add_argument("--scanner-icc")
    parser.add_argument("--out", default="results")
    args = parser.parse_args()
    manifest = json.loads(Path(args.manifest).read_text())
    icc = Path(args.scanner_icc).read_bytes() if args.scanner_icc else None
    result = analyse(args.scan, manifest, args.label, icc)
    path = write_outputs(result, args.out)
    s = result["summary"]
    print(f"{args.label}: dE00 mean {s['all']['mean']}  median {s['all']['median']}  p95 {s['all']['p95']}  "
          f"max {s['all']['max']}  (paper white Lab {result['paper_white_lab']})  -> {path}")


if __name__ == "__main__":
    try:
        main()
    except ScanError as error:
        raise SystemExit(f"Error: {error}")
