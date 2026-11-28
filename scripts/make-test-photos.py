#!/usr/bin/env python3
"""Renders the four built-in test pictures of the validation assistant.

Deterministic (fixed seeds): running it again gives the same files. Synthetic on purpose: no
rights or likeness issues, and every tone is known. Each picture targets one typical printing
problem: skin tones, foliage and sky, dark tones, neutral greys. 1800 x 1200 pixels (6 x 4 in at
300 ppi), 8-bit sRGB PNG with an embedded sRGB profile; rendered in linear light and dithered.

    python3 scripts/make-test-photos.py [output folder]   (default: Packaging/TestPhotos)
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageCms

W, H = 1800, 1200
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "Packaging" / "TestPhotos"


# ---------------------------------------------------------------- colour helpers
def srgb_to_linear(c):
    c = np.asarray(c, dtype=np.float64)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def lab_to_linear_srgb(L, a, b):
    """CIE Lab (D65 white, as sRGB) to linear sRGB."""
    fy = (L + 16) / 116
    fx = fy + a / 500
    fz = fy - b / 200
    def finv(t):
        return np.where(t > 6 / 29, t ** 3, 3 * (6 / 29) ** 2 * (t - 4 / 29))
    X, Y, Z = 0.95047 * finv(fx), 1.0 * finv(fy), 1.08883 * finv(fz)
    M = np.array([[3.2404542, -1.5371385, -0.4985314],
                  [-0.9692660, 1.8760108, 0.0415560],
                  [0.0556434, -0.2040259, 1.0572252]])
    return np.clip(M @ np.array([X, Y, Z]), 0, 1)


def hex_linear(h):
    return srgb_to_linear([int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)])


def tonemap(x, exposure=1.0, white=1.6):
    """Soft shoulder (extended Reinhard on luminance) so highlights roll off instead of clipping."""
    x = np.maximum(x * exposure, 0)
    lum = 0.2126 * x[..., 0] + 0.7152 * x[..., 1] + 0.0722 * x[..., 2]
    mapped = lum * (1 + lum / white ** 2) / (1 + lum)
    scale = np.where(lum > 1e-8, mapped / np.maximum(lum, 1e-8), 0)
    return x * scale[..., None]


def save(linear, name, seed):
    rng = np.random.default_rng(seed)
    encoded = linear_to_srgb(linear) * 255
    # Triangular dither of +-1 LSB: smooth gradients without banding.
    dither = rng.random(encoded.shape) - rng.random(encoded.shape)
    if np.allclose(linear[..., 0], linear[..., 1]) and np.allclose(linear[..., 1], linear[..., 2]):
        dither = np.repeat(dither[..., :1], 3, axis=2)   # keep a neutral picture exactly neutral
    pixels = np.clip(np.round(encoded + dither), 0, 255).astype(np.uint8)
    profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    OUT.mkdir(parents=True, exist_ok=True)
    Image.fromarray(pixels, "RGB").save(OUT / name, icc_profile=profile, dpi=(300, 300), optimize=True)
    print("wrote", OUT / name)


# ---------------------------------------------------------------- noise
def value_noise(shape, scale, rng):
    """Smooth value noise at `scale` pixels per cell (bicubic-like smoothstep interpolation)."""
    h, w = shape
    gh, gw = int(np.ceil(h / scale)) + 2, int(np.ceil(w / scale)) + 2
    grid = rng.random((gh, gw))
    y = np.arange(h)[:, None] / scale
    x = np.arange(w)[None, :] / scale
    y0, x0 = np.floor(y).astype(int), np.floor(x).astype(int)
    fy, fx = y - y0, x - x0
    sy, sx = fy * fy * (3 - 2 * fy), fx * fx * (3 - 2 * fx)
    a = grid[y0, x0]; b = grid[y0, x0 + 1]; c = grid[y0 + 1, x0]; d = grid[y0 + 1, x0 + 1]
    return (a * (1 - sx) + b * sx) * (1 - sy) + (c * (1 - sx) + d * sx) * sy


def fbm(shape, scale, rng, octaves=5, gain=0.5):
    total = np.zeros(shape); amp = 1.0; norm = 0.0
    for _ in range(octaves):
        total += amp * value_noise(shape, max(scale, 1.0), rng)
        norm += amp; amp *= gain; scale /= 2
    return total / norm


# ---------------------------------------------------------------- tiny ray caster
class Scene:
    """Spheres on a floor in front of a seamless backdrop, lit by a soft key, a fill and the sky."""

    def __init__(self, spheres, floor_albedo, backdrop_albedo, key_dir, key_color, fill_color, ambient,
                 key_size=0.18, fov=0.62, camera=(0.0, 1.05, -6.2), target=(0.0, 0.75, 0.0)):
        self.spheres = spheres
        self.floor_albedo = np.asarray(floor_albedo, float)
        self.backdrop_albedo = np.asarray(backdrop_albedo, float)
        self.key_dir = np.asarray(key_dir, float) / np.linalg.norm(key_dir)
        self.key_color = np.asarray(key_color, float)
        self.fill_color = np.asarray(fill_color, float)
        self.ambient = np.asarray(ambient, float)
        self.key_size = key_size
        self.fov = fov
        self.camera = np.asarray(camera, float)
        self.target = np.asarray(target, float)

    def rays(self):
        forward = self.target - self.camera; forward /= np.linalg.norm(forward)
        right = np.cross([0, 1, 0], forward); right /= np.linalg.norm(right)
        up = np.cross(forward, right)
        aspect = W / H
        xs = (np.arange(W) + 0.5) / W * 2 - 1
        ys = 1 - (np.arange(H) + 0.5) / H * 2
        px, py = np.meshgrid(xs * np.tan(self.fov / 2) * aspect, ys * np.tan(self.fov / 2))
        d = forward[None, None] + px[..., None] * right + py[..., None] * up
        return d / np.linalg.norm(d, axis=-1, keepdims=True)

    @staticmethod
    def hit_sphere(origin, dirs, center, radius):
        oc = origin - center
        b = np.einsum("...k,...k->...", dirs, oc)
        c = np.einsum("...k,...k->...", oc, oc) - radius ** 2
        disc = b * b - c
        t = -b - np.sqrt(np.maximum(disc, 0))
        return np.where((disc > 0) & (t > 1e-4), t, np.inf)

    def occlusion(self, points, normals, direction, samples, rng, exclude=None):
        """Share of the key light (a disc of `key_size` radians) visible from each point, shadowed
        by the spheres other than `exclude` (a sphere's own shading is in its diffuse term)."""
        visible = np.zeros(points.shape[:-1])
        perp1 = np.cross(direction, [0.0, 0.0, 1.0]); perp1 /= np.linalg.norm(perp1)
        perp2 = np.cross(direction, perp1)
        offsets = rng.random((samples, 2))
        for u, v in offsets:
            r, a = self.key_size * np.sqrt(u), 2 * np.pi * v
            d = direction + r * np.cos(a) * perp1 + r * np.sin(a) * perp2
            d = d / np.linalg.norm(d)
            blocked = np.zeros(points.shape[:-1], bool)
            origin = points + normals * 1e-3
            for index, s in enumerate(self.spheres):
                if index == exclude:
                    continue
                oc = origin - s["center"]
                b = np.einsum("...k,k->...", oc, d)
                c = np.einsum("...k,...k->...", oc, oc) - s["radius"] ** 2
                disc = b * b - c
                t = -b - np.sqrt(np.maximum(disc, 0))
                blocked |= (disc > 0) & (t > 1e-4)
            visible += ~blocked
        return visible / samples

    def render(self, seed=1, shadow_samples=24):
        rng = np.random.default_rng(seed)
        dirs = self.rays()
        origin = np.broadcast_to(self.camera, dirs.shape)
        best = np.full(dirs.shape[:-1], np.inf)
        which = np.full(dirs.shape[:-1], -1)
        for i, s in enumerate(self.spheres):
            t = self.hit_sphere(origin, dirs, s["center"], s["radius"])
            closer = t < best
            best = np.where(closer, t, best); which = np.where(closer, i, which)
        # Floor (y = 0) curving into a backdrop: shade by distance as a seamless cove.
        t_floor = np.where(dirs[..., 1] < -1e-6, -self.camera[1] / np.minimum(dirs[..., 1], -1e-6), np.inf)
        floor = (t_floor < best) & np.isfinite(t_floor)
        points = origin + dirs * np.where(np.isfinite(best), best, 0)[..., None]
        image = np.zeros(dirs.shape)

        # Backdrop: vertical light falloff, slightly brighter behind the subject.
        yy = np.linspace(1, 0, H)[:, None]
        xx = np.linspace(-1, 1, W)[None, :]
        back = self.backdrop_albedo * (0.55 + 0.45 * np.exp(-(xx ** 2) * 1.4) * (0.6 + 0.4 * yy))[..., None]
        image[:] = back

        # Floor
        fp = origin + dirs * np.where(floor, t_floor, 0)[..., None]
        fn = np.zeros_like(fp); fn[..., 1] = 1
        fvis = self.occlusion(fp, fn, self.key_dir, shadow_samples, rng)
        ndl = np.maximum(fn @ self.key_dir, 0)
        depth_fade = np.clip(1.1 - (fp[..., 2] + 1.5) / 9, 0.35, 1)
        # Contact shading near each sphere (a cheap ambient occlusion).
        ao = np.ones(fp.shape[:-1])
        for s in self.spheres:
            d = np.linalg.norm(fp - s["center"], axis=-1) - s["radius"]
            ao *= 1 - 0.55 * np.exp(-np.maximum(d, 0) / (0.35 * s["radius"]))
        floor_light = (self.key_color * (ndl * fvis)[..., None] + self.fill_color * 0.35 + self.ambient) * ao[..., None]
        floor_color = self.floor_albedo * floor_light * depth_fade[..., None]
        # Blend floor into backdrop towards the horizon (seamless paper).
        horizon = np.clip((t_floor - 6) / 10, 0, 1)
        image = np.where(floor[..., None], floor_color * (1 - horizon[..., None]) + back * horizon[..., None], image)

        # Spheres
        for i, s in enumerate(self.spheres):
            mask = (which == i) & ~floor & np.isfinite(best)
            if not mask.any():
                continue
            p = points[mask]
            n = (p - s["center"]) / s["radius"]
            v = -dirs[mask]
            albedo = np.broadcast_to(np.asarray(s["albedo"], float), p.shape).copy()
            if "texture" in s:
                albedo *= s["texture"](p, n)[..., None]
            vis = self.occlusion(p, n, self.key_dir, shadow_samples, rng, exclude=i)
            ndl = n @ self.key_dir
            wrap = np.asarray(s.get("wrap", (0.0, 0.0, 0.0)), float)    # subsurface: red wraps further
            # Wrapped diffuse: with a larger wrap for red, the terminator of skin turns warmer and
            # more saturated, as light scattered under the surface does.
            wrapped = np.maximum((ndl[..., None] + wrap) / (1 + wrap), 0)
            diffuse = wrapped * vis[..., None] + wrapped * (1 - vis[..., None]) * wrap * 0.35
            fill_dir = np.array([-self.key_dir[0], 0.25, self.key_dir[2]]); fill_dir /= np.linalg.norm(fill_dir)
            fill = np.maximum(n @ fill_dir, 0)[..., None] * self.fill_color
            sky = (0.6 + 0.4 * n[..., 1:2]) * self.ambient
            bounce = np.clip(-n[..., 1:2], 0, 1) * self.floor_albedo * 0.25 * self.key_color
            h = v + self.key_dir; h /= np.linalg.norm(h, axis=-1, keepdims=True)
            spec = s.get("specular", 0.04) * np.power(np.maximum(np.einsum("ij,ij->i", n, h), 0), s.get("shininess", 30))[..., None]
            fresnel = 0.04 + 0.96 * np.power(1 - np.maximum(np.einsum("ij,ij->i", n, v), 0), 5)[..., None]
            color = albedo * (self.key_color * diffuse + fill + sky + bounce) + (spec * vis[..., None] + s.get("sheen", 0.0) * fresnel * self.ambient) * self.key_color
            image[mask] = color
        return image


def skin_texture(scale, amount, seed):
    """Fine, low-contrast mottling (pores and blotches) as a function of the surface point."""
    rng = np.random.default_rng(seed)
    table = rng.random((64, 64, 64))
    def lookup(p, n):
        q = (p * scale) % 64
        i = q.astype(int)
        return 1 - amount / 2 + amount * table[i[:, 0], i[:, 1], i[:, 2]] * 0.5 + amount * 0.5 * table[(i[:, 0] * 3) % 64, (i[:, 1] * 5) % 64, (i[:, 2] * 7) % 64] * 0.5
    return lookup


# ---------------------------------------------------------------- 1. skin tones
def skin_tones():
    # Six skin tones from light to deep (CIE Lab, typical of measured skin).
    tones = [(76, 11, 17), (68, 14, 19), (60, 16, 22), (50, 17, 23), (40, 15, 20), (30, 12, 14)]
    spheres = []
    xs = np.linspace(-2.6, 2.6, 6)
    for k, ((L, a, b), x) in enumerate(zip(tones, xs)):
        albedo = lab_to_linear_srgb(L, a, b)
        spheres.append({
            "center": np.array([x, 0.44, 0.0]), "radius": 0.44,
            "albedo": albedo, "wrap": (0.36, 0.29, 0.26), "specular": 0.05, "shininess": 18, "sheen": 0.04,
            "texture": skin_texture(42.0, 0.10, 100 + k),
        })
    scene = Scene(spheres, floor_albedo=hex_linear("b8aea3"), backdrop_albedo=hex_linear("8f8d8a"),
                  key_dir=(-0.62, 0.62, -0.48), key_color=(1.0, 0.97, 0.92), fill_color=(0.14, 0.15, 0.17),
                  ambient=(0.07, 0.075, 0.085), key_size=0.25, camera=(0.0, 1.0, -6.6), target=(0.0, 0.42, 0.0))
    image = scene.render(seed=11)
    save(tonemap(image, exposure=1.05), "portrait-skin-tones.png", 1)


# ---------------------------------------------------------------- 2. foliage and sky
def foliage_sky():
    rng = np.random.default_rng(22)
    y = np.linspace(0, 1, H)[:, None] * np.ones((1, W))
    x = np.ones((H, 1)) * np.linspace(0, 1, W)[None, :]
    horizon = 0.56
    # Sky: deep saturated blue at the top to a pale haze at the horizon.
    zenith, haze = hex_linear("1d4fa8"), hex_linear("cfe2f2")
    t = np.clip(y / horizon, 0, 1) ** 1.6
    sky = zenith * (1 - t[..., None]) + haze * t[..., None]
    sun = np.exp(-((x - 0.78) ** 2 + (y - 0.12) ** 2 * 2.2) / 0.02)
    sky = sky + np.array([0.35, 0.30, 0.22]) * sun[..., None] * 0.6
    # Clouds: fBm, thresholded softly, lit from the sun side.
    c = fbm((H, W), 420, rng, octaves=6)
    clouds = np.clip((c - 0.52) * 3.2, 0, 1) * np.clip(1 - y / (horizon * 0.95), 0, 1) ** 0.7
    shade = 0.78 + 0.22 * np.clip(fbm((H, W), 120, rng, octaves=4) * 1.4 - 0.2, 0, 1)
    sky = sky * (1 - clouds[..., None]) + (np.array([0.93, 0.93, 0.95]) * shade[..., None]) * clouds[..., None]

    image = sky.copy()
    # Distant hills (blue-green, hazy), then tree line, then a meadow.
    ridge = horizon - 0.06 - 0.05 * fbm((1, W), 300, rng, octaves=4)[0]
    hills = y > ridge[None, :]
    image = np.where(hills[..., None], hex_linear("6e8f86") * (0.85 + 0.25 * fbm((H, W), 90, rng, 4))[..., None], image)

    meadow_top = horizon + 0.17 + 0.02 * np.sin(np.linspace(0, 6, W))
    meadow = y > meadow_top[None, :]
    depth = np.clip((y - meadow_top[None, :]) / (1 - meadow_top.min()), 0, 1)
    # Grass: vertical strokes (noise stretched upwards), larger near the camera, and patches.
    strokes = np.repeat(value_noise((H // 6 + 1, W), 1.5, rng), 6, axis=0)[:H]
    patches = fbm((H, W), 160, rng, octaves=4)
    green = hex_linear("6f9a33") * (1 - depth[..., None]) + hex_linear("2f5a1a") * depth[..., None]
    meadow_color = green * (0.55 + 0.7 * patches + (0.15 + 0.45 * depth) * (strokes - 0.5))[..., None]
    # A few yellow and white flowers, more visible in front.
    flowers = (value_noise((H, W), 3.0, rng) > 0.965) & (rng.random((H, W)) < 0.6 * depth + 0.05)
    meadow_color = np.where(flowers[..., None], np.where((rng.random((H, W)) < 0.6)[..., None], hex_linear("f2d03b"), hex_linear("f4f1e8")), meadow_color)
    # Shade of the trees on the near grass.
    under = 0.5 + 0.5 * np.clip((y - meadow_top[None, :]) / 0.07, 0, 1)
    image = np.where(meadow[..., None], meadow_color * under[..., None], image)
    # Tree line: overlapping crowns, back to front, each lit like a rough ball from the sun
    # (upper right), with leaf texture and dark gaps.
    yy, xx = np.mgrid[0:H, 0:W].astype(float)
    leaf = fbm((H, W), 7, rng, octaves=4)
    leaf_coarse = fbm((H, W), 40, rng, octaves=3)
    sunlit, shadow, yellow = hex_linear("86ad3f"), hex_linear("1c4426"), hex_linear("c2c64e")
    base_y = (horizon + 0.21) * H
    crowns = []
    for _ in range(150):
        cx = rng.uniform(-60, W + 60)
        r = rng.uniform(45, 120)
        cy = base_y - rng.uniform(0.6, 1.9) * r - rng.uniform(0, 70)
        tint = rng.uniform(-0.12, 0.12)
        crowns.append((cy + r, cx, cy, r, tint))
    crowns.sort()  # higher (farther) crowns first
    for _, cx, cy, r, tint in crowns:
        x0, x1 = int(max(cx - r - 2, 0)), int(min(cx + r + 2, W))
        y0, y1 = int(max(cy - r - 2, 0)), int(min(cy + r + 2, H))
        if x0 >= x1 or y0 >= y1:
            continue
        dx = (xx[y0:y1, x0:x1] - cx) / r
        dy = (yy[y0:y1, x0:x1] - cy) / r
        edge = 1 + 0.28 * (leaf_coarse[y0:y1, x0:x1] - 0.5) + 0.18 * (leaf[y0:y1, x0:x1] - 0.5)
        inside = dx * dx + dy * dy < edge * edge
        dz = np.sqrt(np.clip(1 - dx * dx - dy * dy, 0, 1))
        ndl = np.clip(0.55 * dx - 0.6 * dy + 0.58 * dz, 0, 1)            # sun from upper right
        clumps = np.clip((leaf[y0:y1, x0:x1] - 0.30) * 2.4, 0, 1)
        light = np.clip(ndl * (0.35 + 0.9 * clumps), 0, 1)
        color = shadow * (1 - light[..., None]) + sunlit * light[..., None]
        color = np.where((clumps * ndl > 0.62)[..., None], yellow * (0.8 + 0.4 * ndl[..., None]), color)
        color = color * (1 + tint) * (0.35 + 0.8 * light[..., None])
        gaps = leaf[y0:y1, x0:x1] < 0.22                                    # sky through the leaves
        draw = inside & ~(gaps & (dx * dx + dy * dy > 0.55))
        image[y0:y1, x0:x1] = np.where(draw[..., None], color, image[y0:y1, x0:x1])
    # Atmospheric haze near the horizon.
    haze_amount = np.exp(-np.abs(y - (horizon - 0.02)) / 0.03) * 0.10
    image = image * (1 - haze_amount[..., None]) + haze * haze_amount[..., None]
    save(tonemap(image, exposure=1.0, white=2.0), "foliage-sky.png", 2)


# ---------------------------------------------------------------- 3. low-key
def low_key():
    wine, navy, brass = lab_to_linear_srgb(28, 32, 12), lab_to_linear_srgb(22, 4, -24), lab_to_linear_srgb(52, 6, 34)
    spheres = [
        {"center": np.array([-1.0, 0.75, 0.3]), "radius": 0.75, "albedo": wine, "specular": 0.25, "shininess": 60},
        {"center": np.array([0.55, 0.5, -0.3]), "radius": 0.5, "albedo": navy, "specular": 0.12, "shininess": 40},
        {"center": np.array([1.75, 0.32, -0.9]), "radius": 0.32, "albedo": brass, "specular": 0.6, "shininess": 120},
        {"center": np.array([-2.3, 0.28, -0.6]), "radius": 0.28, "albedo": hex_linear("2a2826"), "specular": 0.08, "shininess": 20},
    ]
    cloth = fbm((H, W), 9, np.random.default_rng(33), octaves=3)
    scene = Scene(spheres, floor_albedo=hex_linear("2e2a27"), backdrop_albedo=hex_linear("1a1918"),
                  key_dir=(-0.75, 0.42, -0.5), key_color=(0.95, 0.88, 0.78), fill_color=(0.010, 0.011, 0.014),
                  ambient=(0.006, 0.006, 0.008), key_size=0.10, camera=(0.0, 1.25, -6.0), target=(0.0, 0.5, 0.0))
    image = scene.render(seed=31)
    # A woven texture on the dark cloth (visible only if the shadows keep their detail).
    floor_rows = np.linspace(0, 1, H)[:, None] > 0.55
    image = image * np.where(floor_rows, 0.85 + 0.3 * cloth, 1)[..., None]
    # Vignette towards near black.
    yy, xx = np.mgrid[0:H, 0:W]
    vignette = 1 - 0.55 * (((xx - W * 0.45) / W) ** 2 + ((yy - H * 0.5) / H) ** 2) * 2.4
    save(tonemap(image * np.clip(vignette, 0.2, 1)[..., None], exposure=1.1), "low-key.png", 3)


# ---------------------------------------------------------------- 4. black and white
def black_and_white():
    grey = lambda v: np.array([v, v, v], float)
    spheres = [
        {"center": np.array([-1.7, 0.7, 0.2]), "radius": 0.7, "albedo": grey(0.80), "specular": 0.05, "shininess": 25},
        {"center": np.array([-0.3, 0.45, -0.4]), "radius": 0.45, "albedo": grey(0.18), "specular": 0.08, "shininess": 40},
        {"center": np.array([0.95, 0.6, 0.1]), "radius": 0.6, "albedo": grey(0.035), "specular": 0.30, "shininess": 90},
        {"center": np.array([2.15, 0.35, -0.5]), "radius": 0.35, "albedo": grey(0.45), "specular": 0.05, "shininess": 20},
    ]
    scene = Scene(spheres, floor_albedo=grey(0.55), backdrop_albedo=grey(0.30),
                  key_dir=(0.6, 0.55, -0.58), key_color=grey(1.05), fill_color=grey(0.06),
                  ambient=grey(0.05), key_size=0.22, camera=(0.0, 1.15, -6.4), target=(0.0, 0.5, 0.0))
    image = scene.render(seed=41)
    image = np.repeat(image.mean(axis=2, keepdims=True), 3, axis=2)   # exactly neutral
    # A grey step wedge along the bottom edge: 0 to 100 % in 21 steps (reference for the eye).
    steps = 21
    band = slice(H - 70, H - 20)
    for k in range(steps):
        x0, x1 = 60 + k * (W - 120) // steps, 60 + (k + 1) * (W - 120) // steps
        image[band, x0:x1] = srgb_to_linear(k / (steps - 1))
    save(tonemap_bw(image), "black-and-white.png", 4)


def tonemap_bw(image):
    mapped = tonemap(image, exposure=1.0, white=1.4)
    wedge = np.zeros(image.shape[:2], bool); wedge[H - 70:H - 20, 60:W - 60] = True
    return np.where(wedge[..., None], image, mapped)   # the wedge keeps its exact values


if __name__ == "__main__":
    skin_tones()
    foliage_sky()
    low_key()
    black_and_white()
