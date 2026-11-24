#!/usr/bin/env python3
"""Randomised print order with blind codes for the physical test.

    python3 validation/make_run_plan.py --out Documentation/validation/run-plan.csv [--seed 20261128]

Each sheet gets a code (P01, P02, ...) in random order: print in this order, write ONLY the code
on the back, and keep the key (variant per code) apart until the scans are done.
"""
import argparse
import csv
import random
from pathlib import Path

CHART_VARIANTS = [
    ("V0", "chart, original file", "OFF"),
    ("V1", "chart, corrected Perceptual (BPC off in the app; it is forced on for v4 profiles anyway)", "OFF"),
    ("V2", "chart, corrected Relative colorimetric, BPC off", "OFF"),
    ("V3", "chart, corrected Perceptual", "ON"),
    ("V4", "chart, original file", "ON"),
]
PHOTOS = ["portrait", "foliage-sky", "low-key", "black-and-white"]


def plan(seed):
    items = [(v, d, cm) for v, d, cm in CHART_VARIANTS]
    for photo in PHOTOS:
        items.append((f"{photo}/V0", f"photo {photo}, original file", "OFF"))
        items.append((f"{photo}/V1", f"photo {photo}, corrected Perceptual", "OFF"))
    random.Random(seed).shuffle(items)
    return [(f"P{i + 1:02d}", v, d, cm) for i, (v, d, cm) in enumerate(items)]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default="run-plan.csv")
    parser.add_argument("--seed", type=int, default=20261128)
    args = parser.parse_args()
    rows = plan(args.seed)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["print_order_code", "variant", "content", "printer_image_optimize"])
        writer.writerows(rows)
    for row in rows:
        print(" | ".join(row))
