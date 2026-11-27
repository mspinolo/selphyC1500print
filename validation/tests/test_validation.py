"""Self-test of the physical-validation tools with synthetic data (no printer, no scanner).

Run: SELPHY_CORE_LIB=build/libselphy_core_shared.so python3 -m unittest discover -s validation/tests
"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "validation"))

import analyze_scan  # noqa: E402
import check_scanner  # noqa: E402
import report  # noqa: E402
import chart_layout  # noqa: E402
import make_chart  # noqa: E402
import make_run_plan  # noqa: E402
import selphy_core  # noqa: E402
import simulate_scan  # noqa: E402

PROFILE = (ROOT / "ICC-Profile165-CP1500.icc").read_bytes()


class ChartTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.image, cls.manifest = make_chart.build()

    def test_geometry(self):
        m = self.manifest
        self.assertEqual((m["width"], m["height"]), (1181, 1748))
        margin = chart_layout.MARGIN
        rects = [(p["id"], p["rect"]) for p in m["patches"]]
        rects += [(f"fid-{f['name']}", [f["centre"][0] - f["size"] / 2, f["centre"][1] - f["size"] / 2, f["size"], f["size"]])
                  for f in m["fiducials"]]
        rects += [(w["name"], w["rect"]) for w in m["white_samples"]]
        for name, (x, y, w, h) in rects:
            self.assertGreaterEqual(x, margin - 1, name)
            self.assertGreaterEqual(y, margin - 1, name)
            self.assertLessEqual(x + w, m["width"] - margin + 1, name)
            self.assertLessEqual(y + h, m["height"] - margin + 1, name)
        for i, (na, a) in enumerate(rects):          # no overlaps, 2 px clearance
            for nb, b in rects[i + 1:]:
                overlap = a[0] < b[0] + b[2] + 2 and b[0] < a[0] + a[2] + 2 and a[1] < b[1] + b[3] + 2 and b[1] < a[1] + a[3] + 2
                self.assertFalse(overlap, f"{na} overlaps {nb}")

    def test_contents_and_intended_values(self):
        patches = {p["id"]: p for p in self.manifest["patches"]}
        self.assertEqual(len(patches), 73)
        self.assertEqual(sum(1 for p in patches.values() if p["group"] == "colorchecker"), 24)
        self.assertAlmostEqual(patches["grey-11"]["lab_intended"][0], 100.0, places=1)
        self.assertAlmostEqual(patches["dark-01"]["lab_intended"][0], 0.0, places=1)
        arr = np.asarray(self.image)
        for p in patches.values():
            x, y, w, h = p["rect"]
            self.assertEqual(tuple(arr[y + h // 2, x + w // 2]), tuple(p["srgb"]), p["id"])
        self.assertEqual(tuple(arr[5, 5]), (255, 255, 255))

    def test_scaled_chart_keeps_the_format(self):
        _, m = make_chart.build(1248)
        self.assertEqual(m["width"], 1248)
        self.assertAlmostEqual(m["height"] / m["width"], 1.48, places=2)

    def test_committed_chart_matches_the_generator(self):
        from PIL import Image
        committed = ROOT / "validation" / "charts"
        manifest = json.loads((committed / "selphy_chart_v1.json").read_text())
        self.assertEqual(manifest, json.loads(json.dumps(self.manifest)), "regenerate with make_chart.py")
        self.assertTrue(np.array_equal(np.asarray(Image.open(committed / "selphy_chart_v1.png").convert("RGB")),
                                       np.asarray(self.image)), "regenerate with make_chart.py")

    def test_png_file(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as tmp:
            png = make_chart.save(tmp)
            image = Image.open(png)
            self.assertIn("icc_profile", image.info)
            self.assertAlmostEqual(image.info["dpi"][0], 300, delta=1)
            self.assertEqual(image.size, (1181, 1748))


class AnalysisTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        _, cls.manifest = make_chart.build()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_variant(self, variant, **kw):
        path = Path(self.tmp.name) / f"{variant}-{len(kw)}-{kw.get('quarter_turns', 0)}.tif"
        predicted = simulate_scan.simulate(self.manifest, PROFILE, variant, str(path), **kw)
        result = analyze_scan.analyse(path, self.manifest, variant)
        return predicted, result

    def check_recovery(self, predicted, result, tolerance=0.8):
        measured = np.array([p["measured_lab"] for p in result["patches"]])
        error = selphy_core.delta_e2000(measured, predicted)
        self.assertLess(float(error.mean()), 0.35, f"mean recovery error {error.mean():.2f}")
        self.assertLess(float(error.max()), tolerance, f"max recovery error {error.max():.2f}")

    def test_recovers_the_prediction_through_rotation_scale_and_paper_white(self):
        predicted, result = self.run_variant("V1", angle_deg=2.3)
        self.check_recovery(predicted, result)
        self.assertAlmostEqual(result["paper_white_lab"][0], 98.9, delta=1.5)   # not D50: normalised away

    def test_orientation_is_found_when_the_print_is_upside_down_or_turned(self):
        for turns in (2, 1):
            predicted, result = self.run_variant("V0", angle_deg=-1.7, quarter_turns=turns)
            self.check_recovery(predicted, result)

    def test_correction_beats_no_correction_as_the_model_says(self):
        _, v0 = self.run_variant("V0")
        _, v1 = self.run_variant("V1")
        self.assertLess(v1["summary"]["all"]["mean"], v0["summary"]["all"]["mean"] - 2.0)
        self.assertLess(v1["summary"]["all"]["p95"], v0["summary"]["all"]["p95"])
        # Same order of magnitude as the app's own check (about 3 corrected vs about 9 uncorrected
        # on its test colours); the chart has other colours, so only loose bands are asserted.
        self.assertLess(v1["summary"]["all"]["mean"], 6.0)
        self.assertGreater(v0["summary"]["all"]["mean"], 6.0)

    def test_summary_fields(self):
        _, v1 = self.run_variant("V1")
        s = v1["summary"]
        for key in ("all", "colorchecker", "grey", "dark", "skin", "primary", "neutral_chroma_p95",
                    "dark_steps_distinguishable", "uniformity_de00_max"):
            self.assertIn(key, s)
        self.assertLess(s["uniformity_de00_max"], 0.5)        # a synthetic sheet is uniform
        self.assertEqual(s["dark_steps_total"], 10)
        with tempfile.TemporaryDirectory() as tmp:
            path = analyze_scan.write_outputs(v1, tmp)
            self.assertTrue(path.exists() and path.with_suffix(".csv").exists())

    def test_bad_scans_are_rejected_with_a_message(self):
        import tifffile
        blank = Path(self.tmp.name) / "blank.tif"
        icc = simulate_scan.scanner_icc()
        tifffile.imwrite(blank, np.full((600, 800, 3), 60000, np.uint16), photometric="rgb",
                         extratags=[(34675, "B", len(icc), icc, True)])
        with self.assertRaises(analyze_scan.ScanError):
            analyze_scan.analyse(blank, self.manifest, "X")
        noicc = Path(self.tmp.name) / "noicc.tif"
        tifffile.imwrite(noicc, np.full((600, 800, 3), 60000, np.uint16), photometric="rgb")
        with self.assertRaisesRegex(analyze_scan.ScanError, "scanner profile"):
            analyze_scan.analyse(noicc, self.manifest, "X")


class CoreChartAnalysisTests(unittest.TestCase):
    """The app's C implementation of the scan analysis against this Python reference."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        _, cls.manifest = make_chart.build()
        chart = np.array([f["centre"] for f in cls.manifest["fiducials"]])
        cls.aspect = np.linalg.norm(chart[1] - chart[0]) / np.linalg.norm(chart[3] - chart[0])

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_homography_matches_the_svd_solution(self):
        src = np.array([[0, 0], [100, 0], [100, 150], [0, 150]], float)
        dst = np.array([[12.5, 20.1], [230.2, 30.4], [225.0, 360.3], [5.2, 340.8]])
        np.testing.assert_allclose(selphy_core.core_homography(src, dst), analyze_scan.homography(src, dst), rtol=1e-9, atol=1e-9)

    def test_same_marks_and_samples_as_the_reference(self):
        import tifffile
        for variant, kw in (("V1", {"angle_deg": 2.3}), ("V0", {"angle_deg": -1.7, "quarter_turns": 2}),
                            ("V0", {"angle_deg": 0.8, "quarter_turns": 1, "scale": 1.0})):
            path = Path(self.tmp.name) / f"core-{variant}-{kw.get('quarter_turns', 0)}-{kw.get('scale', 2)}.tif"
            simulate_scan.simulate(self.manifest, PROFILE, variant, str(path), **kw)
            rgb, icc = analyze_scan.read_scan(path)
            py_marks, chart = analyze_scan.find_fiducials(rgb, icc, self.manifest)
            c_marks = selphy_core.core_find_marks(rgb, icc, self.aspect)
            np.testing.assert_allclose(c_marks, py_marks, atol=1e-6, err_msg=f"marks {variant} {kw}")
            h = analyze_scan.homography(chart, py_marks)
            rects = [p["rect"] for p in self.manifest["patches"]] + [w["rect"] for w in self.manifest["white_samples"]]
            py = np.array([analyze_scan.sample_rect(rgb, h, r) for r in rects])
            c = selphy_core.core_sample(rgb, selphy_core.core_homography(chart, c_marks), rects)
            # Identical except where a lattice point sits on a rounding tie: at most one 16-bit step.
            self.assertLessEqual(int(np.abs(c.astype(int) - py.astype(int)).max()), 1, f"samples {variant} {kw}")

    def test_errors_match_the_reference(self):
        icc = simulate_scan.scanner_icc()
        blank = np.full((600, 800, 3), 60000, np.uint16)
        with self.assertRaises(selphy_core.ChartError) as caught:
            selphy_core.core_find_marks(blank, icc, self.aspect)
        self.assertEqual(caught.exception.status, 9)


class ReferenceTests(unittest.TestCase):
    """The bundled ColorChecker reference editions."""

    def test_editions_are_complete_and_consistent(self):
        import json
        folder = Path(__file__).resolve().parents[1] / "references"
        data = json.loads((folder / "colour_targets.json").read_text())
        ids = {s["id"] for s in data["sets"]}
        self.assertEqual(ids, {"classic-before-2014", "classic-after-2014", "classic-2005", "classic-1976",
                               "classic-babelcolor", "sg-before-2014", "sg-after-2014"})
        for s in data["sets"]:
            values = check_scanner.read_reference(folder / f"{s['id']}.csv")
            self.assertEqual(len(values), 24 if s["target"] == "classic24" else 140)
            np.testing.assert_allclose(values, [p["lab"] for p in s["patches"]])
        before = check_scanner.read_reference(folder / "classic-before-2014.csv")
        # Published note: rounded, the 2005 data match the before-November-2014 values.
        self.assertLess(selphy_core.delta_e2000(before, check_scanner.read_reference(folder / "classic-2005.csv")).max(), 0.1)
        self.assertEqual(Path(check_scanner.DEFAULT_REFERENCE).name, "classic-before-2014.csv")
        self.assertAlmostEqual(before[0][0], 37.986)       # dark skin, X-Rite before November 2014
        self.assertEqual(len(check_scanner.patch_centres(np.array([[0, 0], [130, 0], [0, 90], [130, 90]], float), 14, 10)), 140)


class ScannerCheckTests(unittest.TestCase):
    def synthetic_colorchecker(self, folder, noise_offset=0.0):
        import tifffile
        rgb16 = np.array([c for _, c in chart_layout.COLORCHECKER], dtype=np.uint16) * 257
        reference = selphy_core.source_to_lab(None, rgb16)
        scanner_rgb = simulate_scan._lab_to_scanner_rgb(reference, selphy_core.D50) + noise_offset
        image = np.full((500, 700, 3), 0.9, dtype=np.float64)
        pitch, x0, y0 = 90, 80, 60
        for i, color in enumerate(scanner_rgb):
            r, c = divmod(i, 6)
            image[y0 + r * pitch:y0 + r * pitch + 70, x0 + c * pitch:x0 + c * pitch + 70] = color
        icc = simulate_scan.scanner_icc()
        path = Path(folder) / "cc.tif"
        tifffile.imwrite(path, np.clip(np.rint(image * 65535), 0, 65535).astype(np.uint16), photometric="rgb",
                         extratags=[(34675, "B", len(icc), icc, True)])
        centre = lambda r, c: (x0 + c * pitch + 35, y0 + r * pitch + 35)  # noqa: E731
        corners = np.array([centre(0, 0), centre(0, 5), centre(3, 0), centre(3, 5)], dtype=float)
        return path, corners, reference

    def test_scanner_check_on_a_synthetic_chart(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, corners, reference = self.synthetic_colorchecker(tmp)
            result = check_scanner.check(path, corners, reference)
            self.assertLess(result["summary"]["max"], 0.4)
            # A systematic scanner error is reported, not hidden.
            path2, corners2, reference2 = self.synthetic_colorchecker(tmp, noise_offset=0.03)
            self.assertGreater(check_scanner.check(path2, corners2, reference2)["summary"]["mean"], 2.0)

    def test_corner_parsing_and_reference_validation(self):
        corners = check_scanner.parse_corners("10,20 110,20 10,70 110,70")
        centres = check_scanner.patch_centres(corners)
        self.assertEqual(centres.shape, (24, 2))
        self.assertTrue(np.allclose(centres[0], (10, 20)) and np.allclose(centres[5], (110, 20)))
        self.assertTrue(np.allclose(centres[18], (10, 70)) and np.allclose(centres[23], (110, 70)))
        with self.assertRaises(analyze_scan.ScanError):
            check_scanner.parse_corners("1,2 3,4")
        with self.assertRaisesRegex(analyze_scan.ScanError, "missing"):
            check_scanner.read_reference(ROOT / "validation" / "colorchecker_reference_template.csv")


class ReportTests(unittest.TestCase):
    def test_report_gates(self):
        _, manifest = make_chart.build()
        results = {}
        with tempfile.TemporaryDirectory() as tmp:
            for variant in ("V0", "V1", "V2"):
                path = Path(tmp) / f"{variant}.tif"
                simulate_scan.simulate(manifest, PROFILE, variant, str(path))
                results[variant] = analyze_scan.analyse(path, manifest, variant)
        results["V3"] = json.loads(json.dumps(results["V0"]))      # pretend Image Optimize ON is as bad as no correction
        results["V3"]["label"] = "V3"
        text, gates = report.build_report(results, manifest, PROFILE)
        status = {name.split()[0]: ok for name, ok, _ in gates if name.startswith(("G1 ", "G2", "G3"))}
        self.assertTrue(status["G1"] and status["G2"] and status["G3"], gates)
        self.assertIn("## Intent choice", text)
        self.assertIn("Relative colorimetric", text)
        self.assertIn("Scanner chain not checked", text)
        # The model column is the profile's own prediction and matches the simulated measurement.
        model = report.model_summary(manifest, PROFILE, "V1")["all"]["mean"]
        self.assertAlmostEqual(model, results["V1"]["summary"]["all"]["mean"], delta=0.4)

    def test_failing_correction_is_reported_as_failure(self):
        _, manifest = make_chart.build()
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "a.tif"
            simulate_scan.simulate(manifest, PROFILE, "V1", str(path))
            good = analyze_scan.analyse(path, manifest, "V1")
            bad = json.loads(json.dumps(good))
            bad["label"] = "V0"
            for p in bad["patches"]:
                p["de00"] = round(p["de00"] * 0.5, 3)           # a baseline "better" than the correction
            bad["summary"] = analyze_scan.summarise(bad["patches"])
        text, gates = report.build_report({"V0": bad, "V1": good})
        g1 = [ok for name, ok, _ in gates if name.startswith("G1 ")]
        self.assertEqual(g1, [False])
        self.assertIn("FAIL", text)


class RunPlanTests(unittest.TestCase):
    def test_plan_is_complete_random_and_reproducible(self):
        rows = make_run_plan.plan(1)
        self.assertEqual(len(rows), 13)                       # 5 chart variants + 4 photos x 2
        self.assertEqual([r[0] for r in rows], [f"P{i:02d}" for i in range(1, 14)])
        self.assertEqual(len({r[1] for r in rows}), 13)
        self.assertEqual(rows, make_run_plan.plan(1))
        self.assertNotEqual([r[1] for r in rows], [r[1] for r in make_run_plan.plan(2)])
        self.assertEqual(sum(1 for r in rows if r[3] == "ON"), 2)


if __name__ == "__main__":
    unittest.main()
