#!/usr/bin/env python3
"""Checks the scanner chain (scanner + VueScan settings + your ICC profile) on the physical
ColorChecker Classic: the scan, converted with the profile, is compared with the reference Lab
values of YOUR chart (D50), which you supply (datasheet / X-Rite software / BabelColor): they
differ between chart production years, so none are bundled here.

    python3 validation/check_scanner.py cc_scan.tif --corners "x,y x,y x,y x,y" \
        --reference my_reference.csv --out results [--scanner-icc scanner.icc]

--corners: pixel coordinates of the CENTRES of four patches, in this order: dark skin (top-left),
bluish green (top-right), white (bottom-left), black (bottom-right), with the chart in its normal
orientation (the row of greys at the bottom). Read them with any image viewer.
The result is an estimate of the measurement uncertainty on pigment patches, not on dye-sublimation
prints: it bounds what differences the print measurements can resolve.
"""
import argparse
import csv
import json
from pathlib import Path

import numpy as np

import analyze_scan
import selphy_core


def read_reference(path):
    rows = list(csv.DictReader(open(path, newline="")))
    if len(rows) != 24:
        raise analyze_scan.ScanError(f"The reference file must have 24 rows, found {len(rows)}.")
    values = []
    for row in rows:
        try:
            values.append([float(row["L"]), float(row["a"]), float(row["b"])])
        except (KeyError, ValueError):
            raise analyze_scan.ScanError(f"Patch {row.get('patch')}: L, a, b are missing in the reference file.")
    return np.array(values)


def parse_corners(text):
    pts = [tuple(float(v) for v in item.split(",")) for item in text.split()]
    if len(pts) != 4 or any(len(p) != 2 for p in pts):
        raise analyze_scan.ScanError("--corners needs four 'x,y' pairs separated by spaces.")
    return np.array(pts)


def patch_centres(corners):
    tl, tr, bl, br = corners
    centres = []
    for r in range(4):
        v = r / 3
        left, right = tl + (bl - tl) * v, tr + (br - tr) * v
        for c in range(6):
            centres.append(left + (right - left) * (c / 5))
    return np.array(centres)


def check(scan_path, corners, reference, scanner_icc=None, radius_fraction=0.22):
    rgb, embedded = analyze_scan.read_scan(scan_path)
    icc = scanner_icc or embedded
    if icc is None:
        raise analyze_scan.ScanError("No scanner profile: embed it in the TIFF or pass --scanner-icc.")
    centres = patch_centres(corners)
    pitch = np.linalg.norm(corners[1] - corners[0]) / 5
    radius = max(2, int(pitch * radius_fraction))
    samples = []
    for cx, cy in centres:
        x0, x1 = int(cx) - radius, int(cx) + radius + 1
        y0, y1 = int(cy) - radius, int(cy) + radius + 1
        if x0 < 0 or y0 < 0 or x1 > rgb.shape[1] or y1 > rgb.shape[0]:
            raise analyze_scan.ScanError("A patch lies outside the scan: check --corners.")
        samples.append(np.median(rgb[y0:y1, x0:x1].reshape(-1, 3), axis=0).astype(np.uint16))
    measured = selphy_core.source_to_lab(icc, np.array(samples))
    de = selphy_core.delta_e2000(measured, reference)
    return {"measured_lab": measured.round(3).tolist(), "reference_lab": reference.tolist(),
            "de00": de.round(3).tolist(), "summary": analyze_scan.stats(de),
            "note": "Scanner chain error on ColorChecker pigments (absolute Lab D50, no white normalisation)."}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("scan")
    parser.add_argument("--corners", required=True)
    parser.add_argument("--reference", required=True)
    parser.add_argument("--scanner-icc")
    parser.add_argument("--out", default="results")
    args = parser.parse_args()
    icc = Path(args.scanner_icc).read_bytes() if args.scanner_icc else None
    result = check(args.scan, parse_corners(args.corners), read_reference(args.reference), icc)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "scanner_check.json").write_text(json.dumps(result, indent=1) + "\n")
    s = result["summary"]
    print(f"Scanner chain on the ColorChecker: dE00 mean {s['mean']}  median {s['median']}  p95 {s['p95']}  max {s['max']}")
    worst = np.argsort(result["de00"])[::-1][:3]
    print("Worst patches:", ", ".join(f"{i + 1} ({result['de00'][i]})" for i in worst))


if __name__ == "__main__":
    try:
        main()
    except analyze_scan.ScanError as error:
        raise SystemExit(f"Error: {error}")
