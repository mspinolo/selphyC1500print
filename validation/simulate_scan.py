"""Synthetic scans of the chart, from the printer profile's model (used by the self-test).

The physical chain is replaced by: variant -> device RGB -> A2B (predicted Lab, relative) ->
paper white (not D50) -> a sRGB-like scanner -> rotated/scaled 16-bit TIFF with noise. The
analysis must recover the predicted values; it is a check of the tools, not of the printer.
"""
import json
from pathlib import Path

import numpy as np
import tifffile
from PIL import Image

import selphy_core

# Wide-gamut scanner stand-in (ROMM primaries, D50, gamma 1.8) so that the printer's saturated
# colours are not clipped by the simulation itself.
SCANNER_PRIMARIES = np.array([[0.7977, 0.1352, 0.0313],
                              [0.2880, 0.7119, 0.0001],
                              [0.0000, 0.0000, 0.8249]])      # columns = R, G, B XYZ (D50)
SCANNER_GAMMA = 1.8
XYZ_TO_RGB = np.linalg.inv(SCANNER_PRIMARIES)


def _s15(values):
    import struct
    return b"".join(struct.pack(">i", round(v * 65536)) for v in values)


def make_matrix_profile(primaries=SCANNER_PRIMARIES, gamma=SCANNER_GAMMA, description="Synthetic scanner"):
    """Minimal ICC v2 matrix/TRC RGB profile (monitor class), built by hand."""
    import struct

    def text(s):
        data = s.encode("ascii") + b"\0"
        return b"desc" + bytes(4) + struct.pack(">I", len(data)) + data + bytes(4) + bytes(4) + bytes(2) + bytes(1) + bytes(67)

    def xyz(v):
        return b"XYZ " + bytes(4) + _s15(v)

    table = [round(65535 * (i / 1023) ** gamma) for i in range(1024)]
    curve = b"curv" + bytes(4) + struct.pack(">I", 1024) + b"".join(struct.pack(">H", v) for v in table)
    tags = [("desc", text(description)), ("cprt", b"text" + bytes(4) + b"Public domain\0"),
            ("wtpt", xyz(selphy_core.D50)),
            ("rXYZ", xyz(primaries[:, 0])), ("gXYZ", xyz(primaries[:, 1])), ("bXYZ", xyz(primaries[:, 2])),
            ("rTRC", curve), ("gTRC", None), ("bTRC", None)]
    offset = 128 + 4 + 12 * len(tags)
    body, table_entries, curve_offset = b"", b"", None
    for sig, data in tags:
        if data is None:                                   # g/b curves share the red curve
            table_entries += sig.encode() + struct.pack(">II", curve_offset, len(curve))
            continue
        pad = (-len(data)) % 4
        if sig == "rTRC":
            curve_offset = offset + len(body)
        table_entries += sig.encode() + struct.pack(">II", offset + len(body), len(data))
        body += data + bytes(pad)
    size = 128 + 4 + len(table_entries) + len(body)
    header = (struct.pack(">I", size) + b"lcms" + struct.pack(">I", 0x02400000) + b"mntr" + b"RGB " + b"XYZ "
              + struct.pack(">6H", 2024, 1, 1, 0, 0, 0) + b"acsp" + b"APPL" + bytes(4 + 4 + 4 + 8 + 4)
              + _s15(selphy_core.D50) + b"lcms" + bytes(16) + bytes(28))
    assert len(header) == 128, len(header)
    return header + struct.pack(">I", len(tags)) + table_entries + body


VARIANTS = {
    "V0": None,
    "V1": (selphy_core.INTENT_PERCEPTUAL, False),
    "V2": (selphy_core.INTENT_RELATIVE, False),
}


def scanner_icc():
    return make_matrix_profile()


def device_values(printer_icc, variant, srgb8):
    """sRGB 8-bit values (N x 3) -> device RGB sent to the printer for this variant."""
    rgb16 = np.asarray(srgb8, dtype=np.uint16) * 257
    spec = VARIANTS[variant]
    if spec is None:
        return rgb16
    return selphy_core.correct(printer_icc, rgb16, intent=spec[0], black_point_compensation=spec[1])


def predicted_lab(printer_icc, variant, srgb8):
    return selphy_core.printer_predict_lab(printer_icc, device_values(printer_icc, variant, srgb8))


def _lab_to_scanner_rgb(lab_rel, paper_xyz):
    xyz = selphy_core.lab_to_xyz(lab_rel) / selphy_core.D50 * paper_xyz
    linear = np.clip(xyz @ XYZ_TO_RGB.T, 0, 1)
    return linear ** (1 / SCANNER_GAMMA)


def simulate(manifest, printer_icc, variant, out_path, angle_deg=2.0, scale=2.0, quarter_turns=0,
             noise=0.0015, paper_scale=(0.97, 0.98, 0.93), seed=1, lid=0.92):
    """Writes the synthetic scan; returns the predicted paper-relative Lab of each patch."""
    paper_xyz = selphy_core.D50 * np.array(paper_scale)
    width, height = manifest["width"], manifest["height"]
    srgb = [p["srgb"] for p in manifest["patches"]]
    labs = predicted_lab(printer_icc, variant, np.vstack([srgb, [[255, 255, 255], [0, 0, 0]]]))
    patch_lab, white_lab, black_lab = labs[:-2], labs[-2], labs[-1]
    # Paper-relative predictions: the printed white is the reference.
    pred = selphy_core.normalise_to_paper_white(patch_lab, white_lab)
    rgb_patch = _lab_to_scanner_rgb(patch_lab, paper_xyz)
    rgb_white = _lab_to_scanner_rgb(white_lab, paper_xyz)
    rgb_black = _lab_to_scanner_rgb(black_lab, paper_xyz)

    chart = np.empty((height, width, 3), dtype=np.float32)
    chart[:] = rgb_white
    for p, color in zip(manifest["patches"], rgb_patch):
        x, y, w, h = p["rect"]
        chart[y:y + h, x:x + w] = color
    for f in manifest["fiducials"]:
        half = f["size"] / 2
        x0, y0 = round(f["centre"][0] - half), round(f["centre"][1] - half)
        x1, y1 = round(f["centre"][0] + half), round(f["centre"][1] + half)
        chart[y0:y1, x0:x1] = rgb_black

    # Place on a larger bed with a lid colour, rotated by angle (+ quarter turns).
    theta = np.deg2rad(angle_deg) + quarter_turns * np.pi / 2
    out_w = out_h = int(max(width, height) * scale * 1.3)      # large enough for any quarter turn
    c_in = np.array([width / 2, height / 2])
    c_out = np.array([out_w / 2 + 40, out_h / 2 - 25])
    rot = np.array([[np.cos(theta), -np.sin(theta)], [np.sin(theta), np.cos(theta)]])
    inv = np.linalg.inv(rot * scale)                     # output offset -> input offset
    coeffs = (inv[0, 0], inv[0, 1], c_in[0] - inv[0] @ c_out,
              inv[1, 0], inv[1, 1], c_in[1] - inv[1] @ c_out)
    scan = np.empty((out_h, out_w, 3), dtype=np.float32)
    mask = Image.new("F", (width, height), 1.0).transform((out_w, out_h), Image.AFFINE, coeffs, Image.BILINEAR)
    mask = np.asarray(mask)
    for channel in range(3):
        warped = Image.fromarray(chart[..., channel], mode="F").transform(
            (out_w, out_h), Image.AFFINE, coeffs, Image.BILINEAR)
        scan[..., channel] = np.asarray(warped) * mask + lid * (1 - mask)
    rng = np.random.default_rng(seed)
    scan += rng.normal(0, noise, scan.shape).astype(np.float32)
    data = np.clip(np.rint(scan * 65535), 0, 65535).astype(np.uint16)
    icc = scanner_icc()
    tifffile.imwrite(out_path, data, photometric="rgb", extratags=[(34675, "B", len(icc), icc, True)])
    return pred
