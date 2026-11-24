"""Geometry and patches of the SELPHY CP1500 validation chart (portrait 100 x 148 mm).

Design units are pixels of a 1181 x 1748 px raster (300 dpi); everything scales with the
requested width. The chart has no text: ids are written on the back of the print.
"""

DESIGN_W, DESIGN_H = 1181, 1748
MARGIN = 80                 # ~6.8 mm: safe against the borderless crop of the print
FID_SMALL, FID_BIG = 56, 84  # the top-left fiducial is larger: it fixes the orientation

# ColorChecker Classic, sRGB approximations of the 24 patches (digital stand-ins; the physical
# chart is only used by check_scanner.py).
COLORCHECKER = [
    ("dark skin", (115, 82, 68)), ("light skin", (194, 150, 130)), ("blue sky", (98, 122, 157)),
    ("foliage", (87, 108, 67)), ("blue flower", (133, 128, 177)), ("bluish green", (103, 189, 170)),
    ("orange", (214, 126, 44)), ("purplish blue", (80, 91, 166)), ("moderate red", (193, 90, 99)),
    ("purple", (94, 60, 108)), ("yellow green", (157, 188, 64)), ("orange yellow", (224, 163, 46)),
    ("blue", (56, 61, 150)), ("green", (70, 148, 73)), ("red", (175, 54, 60)),
    ("yellow", (231, 199, 31)), ("magenta", (187, 86, 149)), ("cyan", (8, 133, 161)),
    ("white", (243, 243, 242)), ("neutral 8", (200, 200, 200)), ("neutral 6.5", (160, 160, 160)),
    ("neutral 5", (122, 122, 121)), ("neutral 3.5", (85, 85, 85)), ("black", (52, 52, 52)),
]
GREY_RAMP = [round(i * 25.5) for i in range(11)]          # 0 ... 255
DARK_STEPS = [0, 2, 4, 6, 8, 12, 16, 24, 32, 48]
PRIMARIES = [("red", (255, 0, 0)), ("green", (0, 255, 0)), ("blue", (0, 0, 255)),
             ("cyan", (0, 255, 255)), ("magenta", (255, 0, 255)), ("yellow", (255, 255, 0))]
SKIN = [(255, 224, 196), (234, 192, 160), (205, 150, 115), (170, 115, 80), (125, 80, 55), (90, 58, 42)]
NATURE = [("sky", (105, 150, 205)), ("deep sky", (30, 80, 170)), ("foliage", (60, 110, 50)),
          ("grass", (110, 160, 60)), ("sand", (205, 185, 140)), ("rust", (160, 80, 50))]
MID_GREY = (128, 128, 128)


def _row(items, x_left, y, w, h, gap, total_w=None):
    """Rect list for a centred row of equally sized patches."""
    n = len(items)
    width = n * w + (n - 1) * gap
    x0 = x_left + ((total_w - width) / 2 if total_w else 0)
    return [(x0 + i * (w + gap), y, w, h) for i in range(n)]


def design_patches():
    """[(id, group, name, srgb, (x, y, w, h))] in design units."""
    patches = []
    content_w = DESIGN_W - 2 * MARGIN

    def add(group, items, rects):
        for index, (item, rect) in enumerate(zip(items, rects)):
            name, rgb = item
            patches.append((f"{group}-{index + 1:02d}", group, name, rgb, rect))

    # 6 x 4 ColorChecker
    cc_rects = []
    for r in range(4):
        cc_rects += _row(range(6), MARGIN, 200 + r * 167, 150, 150, 17, content_w)
    add("colorchecker", COLORCHECKER, cc_rects)
    add("grey", [(f"grey {v}", (v, v, v)) for v in GREY_RAMP],
        _row(GREY_RAMP, MARGIN, 881, 85, 100, 8, content_w))
    add("dark", [(f"dark {v}", (v, v, v)) for v in DARK_STEPS],
        _row(DARK_STEPS, MARGIN, 1011, 96, 100, 6, content_w))
    add("primary", [(n, c) for n, c in PRIMARIES], _row(PRIMARIES, MARGIN, 1141, 150, 90, 17, content_w))
    add("primary50", [(n + " 50%", tuple(v // 2 if v else 0 for v in c)) for n, c in PRIMARIES],
        _row(PRIMARIES, MARGIN, 1248, 150, 90, 17, content_w))
    add("skin", [(f"skin {i + 1}", c) for i, c in enumerate(SKIN)], _row(SKIN, MARGIN, 1368, 150, 90, 17, content_w))
    add("nature", NATURE, _row(NATURE, MARGIN, 1488, 150, 90, 17, content_w))

    # Mid grey repeated in four places: within-sheet uniformity of print and scan.
    top, bottom = MARGIN, DESIGN_H - MARGIN - 60
    left_a, right_a = MARGIN + FID_BIG + 30, DESIGN_W - MARGIN - FID_SMALL - 30 - 60
    left_b, right_b = MARGIN + FID_SMALL + 30, right_a
    uniform = [("grey tl", MID_GREY, (left_a, top, 60, 60)), ("grey tr", MID_GREY, (right_a, top, 60, 60)),
               ("grey bl", MID_GREY, (left_b, bottom, 60, 60)), ("grey br", MID_GREY, (right_b, bottom, 60, 60))]
    for index, (name, rgb, rect) in enumerate(uniform):
        patches.append((f"uniformity-{index + 1:02d}", "uniformity", name, rgb, rect))
    return patches


def design_fiducials():
    """[(name, centre_x, centre_y, size)] in design units; order = clockwise from the big one."""
    big, small = FID_BIG, FID_SMALL
    return [
        ("tl", MARGIN + big / 2, MARGIN + big / 2, big),
        ("tr", DESIGN_W - MARGIN - small / 2, MARGIN + small / 2, small),
        ("br", DESIGN_W - MARGIN - small / 2, DESIGN_H - MARGIN - small / 2, small),
        ("bl", MARGIN + small / 2, DESIGN_H - MARGIN - small / 2, small),
    ]


def design_white_samples():
    """Unprinted paper areas (RGB 255) used as paper-white reference."""
    y_top = MARGIN + 10
    y_bottom = DESIGN_H - MARGIN - 56 + 10
    return [("white top", (330, y_top, 520, 36)), ("white bottom", (330, y_bottom, 520, 36))]
