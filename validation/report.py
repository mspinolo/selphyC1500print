#!/usr/bin/env python3
"""Merges the per-variant results into one report and checks the pre-declared gates.

    python3 validation/report.py --results results --printer-icc ICC-Profile165-CP1500.icc \
        --manifest validation/charts/selphy_chart_v1.json --out results/REPORT.md

Variants: V0 original/CM off, V1 corrected perceptual/CM off, V2 corrected relative colorimetric/
CM off, V3 corrected perceptual/CM ON, V4 original/CM ON. Any subset can be reported.
"""
import argparse
import json
from pathlib import Path

import numpy as np

import analyze_scan
import selphy_core
import simulate_scan

DESCRIPTIONS = {
    "V0": "original, printer colour management OFF (baseline)",
    "V1": "corrected, Perceptual, colour management OFF (main result)",
    "V2": "corrected, Relative colorimetric, colour management OFF (intent choice)",
    "V3": "corrected, Perceptual, colour management ON (double-conversion check)",
    "V4": "original, colour management ON (control for V3)",
}
INDISTINGUISHABLE = 1.0          # dE00 differences below this are not interpreted as real


def model_summary(manifest, printer_icc, variant):
    """What the profile's model predicts for this variant on the chart (A2B, paper-relative)."""
    model_variant = {"V3": "V1", "V4": "V0"}.get(variant, variant)
    srgb = [p["srgb"] for p in manifest["patches"]]
    labs = simulate_scan.predicted_lab(printer_icc, model_variant, np.vstack([srgb, [[255, 255, 255]]]))
    pred = selphy_core.normalise_to_paper_white(labs[:-1], labs[-1])
    de = selphy_core.delta_e2000(pred, [p["lab_intended"] for p in manifest["patches"]])
    patches = [{"group": p["group"], "de00": float(d), "srgb": p["srgb"], "measured_lab": list(map(float, lab))}
               for p, d, lab in zip(manifest["patches"], de, pred)]
    return analyze_scan.summarise(patches)


def load_results(folder):
    results = {}
    for path in sorted(Path(folder).glob("results_V*.json")):
        data = json.loads(path.read_text())
        results[data["label"]] = data
    return results


def _fmt(value):
    return "–" if value is None else f"{value:.2f}"


def build_report(results, manifest=None, printer_icc=None, scanner_check=None):
    lines = ["# Physical validation report", "",
             "Evidence level: scanner-estimated colorimetry (flatbed scanner + ICC profile), not a spectrophotometer. "
             "dE00 against the intended appearance of the sRGB source, paper-relative.", ""]
    if scanner_check:
        s = scanner_check["summary"]
        lines += [f"Scanner chain on the ColorChecker: dE00 mean {s['mean']:.2f}, p95 {s['p95']:.2f}, max {s['max']:.2f}. "
                  f"Differences between variants smaller than about {max(INDISTINGUISHABLE, s['mean']):.1f} dE00 "
                  "are not interpreted.", ""]
    else:
        lines += ["Scanner chain not checked on the ColorChecker: absolute values carry an unknown measurement error.", ""]

    lines += ["## Summary (dE00 on all patches)", "",
              "| Variant | Description | Mean | Median | P95 | Max | Neutral C* p95 | Dark steps seen | Model mean |",
              "|---|---|---|---|---|---|---|---|---|"]
    for label in sorted(results):
        s = results[label]["summary"]
        model = None
        if manifest is not None and printer_icc is not None and label in DESCRIPTIONS:
            model = model_summary(manifest, printer_icc, label)["all"]["mean"]
        lines.append(f"| {label} | {DESCRIPTIONS.get(label, '')} | {_fmt(s['all']['mean'])} | {_fmt(s['all']['median'])} | "
                     f"{_fmt(s['all']['p95'])} | {_fmt(s['all']['max'])} | {_fmt(s['neutral_chroma_p95'])} | "
                     f"{s['dark_steps_distinguishable']}/{s['dark_steps_total']} | {_fmt(model)} |")
    lines += ["", "(Model mean = what the profile's own model predicts for the same chart; V3/V4 reuse V1/V0.)", ""]

    groups = sorted({g for r in results.values() for g in r["summary"] if isinstance(r["summary"][g], dict) and g != "all"})
    lines += ["## Mean dE00 by patch group", "", "| Group | " + " | ".join(sorted(results)) + " |",
              "|---|" + "---|" * len(results)]
    for g in groups:
        row = [_fmt(results[l]["summary"].get(g, {}).get("mean")) for l in sorted(results)]
        lines.append(f"| {g} | " + " | ".join(row) + " |")
    lines.append("")

    gates = []
    v0, v1, v2, v3 = (results.get(k) for k in ("V0", "V1", "V2", "V3"))
    if v0 and v1:
        a, b = v0["summary"]["all"], v1["summary"]["all"]
        ok = b["mean"] < a["mean"] and b["p95"] <= a["p95"]
        note = "improvement" if a["mean"] - b["mean"] >= INDISTINGUISHABLE else "difference too small to interpret"
        gates.append(("G1 correction helps (V1 mean < V0 mean and V1 p95 <= V0 p95)", ok,
                      f"mean {a['mean']:.2f} -> {b['mean']:.2f}, p95 {a['p95']:.2f} -> {b['p95']:.2f} ({note})"))
        paired = [(p0["de00"], p1["de00"], p0["group"]) for p0, p1 in zip(v0["patches"], v1["patches"]) if p0["group"] != "uniformity"]
        better = sum(1 for x, y, _ in paired if y < x - 0.5)
        worse = sum(1 for x, y, _ in paired if y > x + 0.5)
        gates.append(("G1b patches improved / worsened by more than 0.5 dE00", worse <= better // 4 + 1,
                      f"{better} improved, {worse} worsened of {len(paired)}"))
    if v1:
        c = v1["summary"]["neutral_chroma_p95"]
        gates.append(("G2 neutral axis (C* p95 <= 3 from L* 25 up) in V1", c is not None and c <= 3.0, f"C* p95 = {_fmt(c)}"))
    if v1 and v3:
        gates.append(("G3 colour management ON is worse than OFF (double conversion exists)",
                      v3["summary"]["all"]["mean"] > v1["summary"]["all"]["mean"] + INDISTINGUISHABLE,
                      f"V3 mean {v3['summary']['all']['mean']:.2f} vs V1 {v1['summary']['all']['mean']:.2f}; "
                      "if equal, the printer ignores the setting for this route"))
    for label in sorted(results):
        u = results[label]["summary"].get("uniformity_de00_max")
        if u is not None:
            gates.append((f"G4 sheet uniformity {label} (4 mid-greys, max pairwise dE00 < 1)", u < 1.0, f"{u:.2f}"))
    lines += ["## Gates", "", "| Gate | Result | Detail |", "|---|---|---|"]
    for name, ok, detail in gates:
        lines.append(f"| {name} | {'PASS' if ok else 'FAIL'} | {detail} |")
    if v1 and v2:
        a, b = v1["summary"], v2["summary"]
        better = "V2 (Relative colorimetric)" if b["all"]["mean"] < a["all"]["mean"] else "V1 (Perceptual)"
        lines += ["", "## Intent choice", "",
                  f"Lower mean dE00: **{better}** (V1 {a['all']['mean']:.2f}, V2 {b['all']['mean']:.2f}; median "
                  f"{a['all']['median']:.2f} vs {b['all']['median']:.2f}; neutral C* p95 {_fmt(a['neutral_chroma_p95'])} vs "
                  f"{_fmt(b['neutral_chroma_p95'])}; dark steps seen {a['dark_steps_distinguishable']} vs "
                  f"{b['dark_steps_distinguishable']}). Confirm with the photographs before changing the default."]
    lines += ["", "The photographs are judged visually side by side under neutral light (V0 against V1); "
              "record the verdict in the run notes."]
    return "\n".join(lines) + "\n", gates


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--results", default="results")
    parser.add_argument("--manifest", default="validation/charts/selphy_chart_v1.json")
    parser.add_argument("--printer-icc", default="ICC-Profile165-CP1500.icc")
    parser.add_argument("--out", default="results/REPORT.md")
    args = parser.parse_args()
    results = load_results(args.results)
    if not results:
        raise SystemExit("No results_V*.json found: run analyze_scan.py first.")
    manifest = json.loads(Path(args.manifest).read_text())
    icc = Path(args.printer_icc).read_bytes()
    check_path = Path(args.results) / "scanner_check.json"
    scanner = json.loads(check_path.read_text()) if check_path.exists() else None
    text, gates = build_report(results, manifest, icc, scanner)
    Path(args.out).write_text(text)
    print(text)


if __name__ == "__main__":
    main()
