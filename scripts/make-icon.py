#!/usr/bin/env python3
"""Draws the app icon (original artwork: a photo coming out of a printer) and writes
Packaging/AppIcon.icns plus a PNG preview. Needs Pillow only.
Usage: python3 scripts/make-icon.py [output-dir]   (default: Packaging)
"""
import io
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
SS = 2  # supersampling


def draw_icon(px=SIZE):
    s = px * SS
    k = s / 160.0 * (824 / 1024)           # art coordinates (0..160) -> pixels
    off = s * (100 / 1024)                 # macOS icon grid: 824 px tile inside 1024
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    def box(x, y, w, h):
        return [off + x * k, off + y * k, off + (x + w) * k, off + (y + h) * k]

    # tile
    d.rounded_rectangle(box(0, 0, 160, 160), radius=36 * k, fill="#185FA5")
    # photo (drawn first, the printer body hides its lower part)
    d.rounded_rectangle(box(44, 30, 72, 76), radius=4 * k, fill="#FFFFFF")
    d.ellipse(box(56, 46, 16, 16), fill="#EF9F27")
    d.polygon([(off + x * k, off + y * k) for x, y in
               [(44, 94), (72, 64), (90, 82), (100, 72), (116, 88), (116, 106), (44, 106)]],
              fill="#1D9E75")
    # printer body and paper slot
    d.rounded_rectangle(box(22, 84, 116, 48), radius=11 * k, fill="#E6F1FB")
    d.rounded_rectangle(box(34, 90, 92, 7), radius=3.5 * k, fill="#0C447C")
    d.ellipse(box(120, 114, 8, 8), fill="#1D9E75")
    return img.resize((px, px), Image.LANCZOS)


ICNS_TYPES = [  # (type, pixel size)
    ("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256),
    ("ic09", 512), ("ic10", 1024), ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512),
]


def build_icns(master):
    chunks = []
    for code, px in ICNS_TYPES:
        buf = io.BytesIO()
        master.resize((px, px), Image.LANCZOS).save(buf, "PNG", optimize=True)
        data = buf.getvalue()
        chunks.append(code.encode() + struct.pack(">I", len(data) + 8) + data)
    body = b"".join(chunks)
    return b"icns" + struct.pack(">I", len(body) + 8) + body


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "Packaging")
    out.mkdir(parents=True, exist_ok=True)
    master = draw_icon()
    (out / "AppIcon.icns").write_bytes(build_icns(master))
    master.save(out / "AppIcon-preview.png", optimize=True)
    print(out / "AppIcon.icns")


if __name__ == "__main__":
    main()
