"""ctypes wrapper around the portable colour core (the same C code the app uses).

Set SELPHY_CORE_LIB to the shared library, or build it first:
    cmake -S . -B build && cmake --build build --target selphy_core_shared
"""
import ctypes
import os
from pathlib import Path

import numpy as np

INTENT_PERCEPTUAL, INTENT_RELATIVE, INTENT_SATURATION = 0, 1, 2
D50 = np.array([0.9642, 1.0, 0.8249])


def _find_library():
    env = os.environ.get("SELPHY_CORE_LIB")
    if env:
        return env
    root = Path(__file__).resolve().parent.parent
    for name in ("libselphy_core_shared.so", "libselphy_core_shared.dylib", "selphy_core_shared.dll"):
        for folder in ("build", "build-validation", "."):
            candidate = root / folder / name
            if candidate.exists():
                return str(candidate)
    raise FileNotFoundError(
        "Colour core library not found. Build it with: cmake -S . -B build && "
        "cmake --build build --target selphy_core_shared (or set SELPHY_CORE_LIB).")


class _Options(ctypes.Structure):
    _fields_ = [("intent", ctypes.c_int), ("black_point_compensation", ctypes.c_int), ("exact", ctypes.c_int)]


_lib = None


def lib():
    global _lib
    if _lib is None:
        _lib = ctypes.CDLL(_find_library())
        u16 = np.ctypeslib.ndpointer(np.uint16, flags="C_CONTIGUOUS")
        f64 = np.ctypeslib.ndpointer(np.float64, flags="C_CONTIGUOUS")
        _lib.selphy_source_to_lab.argtypes = [ctypes.c_char_p, ctypes.c_size_t, u16, f64, ctypes.c_size_t]
        _lib.selphy_printer_predict_lab.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_int, u16, f64, ctypes.c_size_t]
        _lib.selphy_transform_create.argtypes = [
            ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t,
            ctypes.POINTER(_Options), ctypes.POINTER(ctypes.c_void_p)]
        _lib.selphy_transform_apply_rgb16.argtypes = [ctypes.c_void_p, u16, u16, ctypes.c_size_t]
        _lib.selphy_transform_free.argtypes = [ctypes.c_void_p]
        _lib.selphy_delta_e2000.argtypes = [ctypes.c_double * 3, ctypes.c_double * 3]
        _lib.selphy_delta_e2000.restype = ctypes.c_double
        _lib.selphy_status_message.restype = ctypes.c_char_p
        _lib.selphy_status_message.argtypes = [ctypes.c_int]
    return _lib


def _check(status):
    if status != 0:
        raise RuntimeError("colour core error: " + lib().selphy_status_message(status).decode())


def _rgb16(values):
    arr = np.ascontiguousarray(np.asarray(values, dtype=np.uint16).reshape(-1, 3))
    return arr


def source_to_lab(icc, rgb16):
    """RGB (uint16, N x 3) in the colour space of `icc` (bytes, None = sRGB) -> Lab D50, relative."""
    rgb = _rgb16(rgb16)
    out = np.zeros((len(rgb), 3), dtype=np.float64)
    _check(lib().selphy_source_to_lab(icc, len(icc) if icc else 0, rgb, out, len(rgb)))
    return out


def printer_predict_lab(printer_icc, rgb16, intent=INTENT_RELATIVE):
    """Device RGB sent to the printer -> predicted Lab through the profile's A2B table."""
    rgb = _rgb16(rgb16)
    out = np.zeros((len(rgb), 3), dtype=np.float64)
    _check(lib().selphy_printer_predict_lab(printer_icc, len(printer_icc), intent, rgb, out, len(rgb)))
    return out


def correct(printer_icc, rgb16, intent=INTENT_PERCEPTUAL, black_point_compensation=False, source_icc=None):
    """The app's correction: source RGB -> printer device RGB values (uint16)."""
    rgb = _rgb16(rgb16)
    handle = ctypes.c_void_p()
    options = _Options(intent, int(black_point_compensation), 0)
    _check(lib().selphy_transform_create(
        source_icc, len(source_icc) if source_icc else 0, printer_icc, len(printer_icc),
        ctypes.byref(options), ctypes.byref(handle)))
    try:
        out = np.zeros_like(rgb)
        lib().selphy_transform_apply_rgb16(handle, rgb, out, len(rgb))
        return out
    finally:
        lib().selphy_transform_free(handle)


def delta_e2000(lab1, lab2):
    a = np.atleast_2d(np.asarray(lab1, dtype=np.float64))
    b = np.atleast_2d(np.asarray(lab2, dtype=np.float64))
    a, b = np.broadcast_arrays(a, b)
    f = lib().selphy_delta_e2000
    return np.array([f((ctypes.c_double * 3)(*x), (ctypes.c_double * 3)(*y)) for x, y in zip(a, b)])


def lab_to_xyz(lab):
    lab = np.asarray(lab, dtype=np.float64)
    fy = (lab[..., 0] + 16) / 116
    fx = fy + lab[..., 1] / 500
    fz = fy - lab[..., 2] / 200
    d = 6 / 29

    def inv(t):
        return np.where(t > d, t ** 3, 3 * d * d * (t - 4 / 29))
    return np.stack([inv(fx), inv(fy), inv(fz)], axis=-1) * D50


def xyz_to_lab(xyz):
    t = np.asarray(xyz, dtype=np.float64) / D50
    d = 6 / 29

    def f(v):
        return np.where(v > d ** 3, np.cbrt(v), v / (3 * d * d) + 4 / 29)
    fx, fy, fz = f(t[..., 0]), f(t[..., 1]), f(t[..., 2])
    return np.stack([116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)], axis=-1)


def normalise_to_paper_white(lab, white_lab):
    """Re-express Lab relative to the paper white (media-relative), like the intended values."""
    xyz = lab_to_xyz(lab) / lab_to_xyz(np.asarray(white_lab)) * D50
    return xyz_to_lab(xyz)
