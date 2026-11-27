import AppKit
import CoreGraphics
import ImageIO
import SELPHYColorCore
import UniformTypeIdentifiers
import XCTest
@testable import SELPHYCP1500Print

/// The print validation assistant (M3.3): reference data, chart, scan analysis, report, plan.
final class ValidationTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selphy-validation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Reference values

    func testBuiltInReferencesMatchTheRepositoryData() throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("validation/references/colour_targets.json"))) as! [String: Any]
        let sets = json["sets"] as! [[String: Any]]
        XCTAssertEqual(sets.count, ReferenceSet.builtIn.count)
        for (entry, set) in zip(sets, ReferenceSet.builtIn) {
            XCTAssertEqual(entry["id"] as? String, set.id)
            let patches = entry["patches"] as! [[String: Any]]
            XCTAssertEqual(patches.count, set.model.patchCount)
            for (p, q) in zip(patches, set.patches) {
                XCTAssertEqual(p["name"] as? String, q.name)
                XCTAssertEqual(p["lab"] as! [Double], q.lab)
            }
        }
        XCTAssertEqual(ReferenceSet.default.id, "classic-before-2014", "the owner's chart is from before 2014")
        XCTAssertEqual(ReferenceSet.default.patches[0].l, 37.986)
        XCTAssertEqual(Set(ReferenceSet.builtIn.map(\.model)), [.classic24, .sg140])
        XCTAssertEqual(ReferenceSet.builtIn.filter { $0.model == .classic24 }.count, 5)
    }

    func testImportOfCSVAndCGATS() throws {
        let classic = ReferenceSet.default.patches
        let csv = "patch;name;L;a;b\n" + classic.enumerated().map { "\($0.offset + 1);\($0.element.name);\($0.element.l);\($0.element.a);\($0.element.b)" }.joined(separator: "\n")
        let fromCSV = try ReferenceImport.parse(csv, name: "mine.csv")
        XCTAssertEqual(fromCSV.model, .classic24)
        XCTAssertEqual(fromCSV.patches.map(\.lab), classic.map(\.lab))
        XCTAssertTrue(fromCSV.isImported)

        var cgats = "CGATS.17\nORIGINATOR \"test\"\nNUMBER_OF_FIELDS 4\nBEGIN_DATA_FORMAT\nSAMPLE_ID LAB_L LAB_A LAB_B\nEND_DATA_FORMAT\nNUMBER_OF_SETS 24\nBEGIN_DATA\n"
        cgats += classic.enumerated().map { "\($0.offset + 1) \($0.element.l) \($0.element.a) \($0.element.b)" }.joined(separator: "\n")
        cgats += "\nEND_DATA\n"
        XCTAssertEqual(try ReferenceImport.parse(cgats, name: "mine.cgats").patches.map(\.lab), classic.map(\.lab))

        // XYZ data (white Y = 100) are converted to Lab D50.
        var xyz = "BEGIN_DATA_FORMAT\nSAMPLE_NAME XYZ_X XYZ_Y XYZ_Z\nEND_DATA_FORMAT\nBEGIN_DATA\n"
        xyz += classic.map { p in
            let v = LabMath.labToXYZ(p.lab)
            return "\"\(p.name)\" \(v[0] * 100) \(v[1] * 100) \(v[2] * 100)"
        }.joined(separator: "\n") + "\nEND_DATA\n"
        let fromXYZ = try ReferenceImport.parse(xyz, name: "xyz.txt")
        for (p, q) in zip(fromXYZ.patches, classic) {
            XCTAssertEqual(p.l, q.l, accuracy: 1e-6)
            XCTAssertEqual(p.a, q.a, accuracy: 1e-6)
            XCTAssertEqual(p.b, q.b, accuracy: 1e-6)
        }

        XCTAssertThrowsError(try ReferenceImport.parse("L,a,b\n1,2,3\n", name: "short.csv")) {
            XCTAssertEqual($0 as? ReferenceImport.ImportError, .wrongCount(1))
        }
        XCTAssertThrowsError(try ReferenceImport.parse("x,y\n1,2\n", name: "bad.csv")) {
            XCTAssertEqual($0 as? ReferenceImport.ImportError, .missingColumns)
        }
        XCTAssertThrowsError(try ReferenceImport.parse("L,a,b\n1,x,3\n", name: "bad.csv")) {
            XCTAssertEqual($0 as? ReferenceImport.ImportError, .badValue(2))
        }
    }

    // MARK: Chart

    func testChartMatchesTheCommittedManifestAndImage() throws {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("validation/charts/selphy_chart_v1.json"))) as! [String: Any]
        let chart = ValidationChart.standard
        XCTAssertEqual(manifest["width"] as? Int, chart.width)
        XCTAssertEqual(manifest["height"] as? Int, chart.height)
        let patches = manifest["patches"] as! [[String: Any]]
        XCTAssertEqual(patches.count, chart.patches.count)
        for (p, q) in zip(patches, chart.patches) {
            XCTAssertEqual(p["id"] as? String, q.id)
            XCTAssertEqual(p["group"] as? String, q.group)
            XCTAssertEqual(p["name"] as? String, q.name)
            XCTAssertEqual(p["srgb"] as? [Int], q.srgb)
            XCTAssertEqual(p["rect"] as? [Int], q.rect, q.id)
            for (a, b) in zip(p["lab_intended"] as! [Double], q.labIntended) { XCTAssertEqual(a, b, accuracy: 1.1e-4, q.id) }
        }
        let fiducials = manifest["fiducials"] as! [[String: Any]]
        XCTAssertEqual(fiducials.map { $0["centre"] as! [Double] }, chart.fiducials.map(\.centre))
        XCTAssertEqual((manifest["white_samples"] as! [[String: Any]]).map { $0["rect"] as! [Int] }, chart.whiteSamples.map(\.rect))

        // Pixel for pixel the same as the PNG made by validation/make_chart.py.
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(root.appendingPathComponent("validation/charts/selphy_chart_v1.png") as CFURL, nil))
        let committed = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var decoded = [UInt8](repeating: 0, count: chart.width * chart.height * 4)
        // Decoded in the file's own colour space: no conversion, the stored numbers.
        let context = try XCTUnwrap(CGContext(data: &decoded, width: chart.width, height: chart.height, bitsPerComponent: 8,
                                              bytesPerRow: chart.width * 4, space: committed.colorSpace ?? sRGB,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(committed, in: CGRect(x: 0, y: 0, width: chart.width, height: chart.height))
        let mine = chart.pixels()
        var differing = 0
        for i in stride(from: 0, to: mine.count, by: 4) where mine[i] != decoded[i] || mine[i + 1] != decoded[i + 1] || mine[i + 2] != decoded[i + 2] {
            differing += 1
        }
        XCTAssertEqual(differing, 0, "pixels differing from the committed chart")

        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appendingPathComponent("chart.png")
        try chart.writePNG(to: png)
        let written = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(written, 0, nil) as! [CFString: Any]
        XCTAssertEqual(properties[kCGImagePropertyDPIWidth] as! Double, 300, accuracy: 0.1)
        XCTAssertEqual(chart.aspect, hypot(1073 - 122, 108 - 122) / hypot(108 - 122, 1640 - 122.0), accuracy: 1e-12)
    }

    // MARK: Scan analysis

    /// The chart as a "scan": scaled up 2x (nearest), turned by quarter turns, on a light lid,
    /// written as a TIFF tagged sRGB (the "scanner profile").
    private func syntheticScan(quarterTurns: Int, to url: URL) throws {
        let chart = ValidationChart.standard
        let pixels = chart.pixels()
        let scale = 2, border = 60
        let w = chart.width * scale, h = chart.height * scale
        let turned = quarterTurns % 2 == 1
        let outW = (turned ? h : w) + 2 * border, outH = (turned ? w : h) + 2 * border
        var out = [UInt8](repeating: 236, count: outW * outH * 4)
        for y in 0..<h {
            for x in 0..<w {
                let s = ((y / scale) * chart.width + x / scale) * 4
                var (tx, ty) = (x, y)
                switch quarterTurns % 4 {
                case 1: (tx, ty) = (h - 1 - y, x)
                case 2: (tx, ty) = (w - 1 - x, h - 1 - y)
                case 3: (tx, ty) = (y, w - 1 - x)
                default: break
                }
                let o = ((ty + border) * outW + tx + border) * 4
                out[o] = pixels[s]; out[o + 1] = pixels[s + 1]; out[o + 2] = pixels[s + 2]
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(out) as CFData))
        let image = try XCTUnwrap(CGImage(width: outW, height: outH, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: outW * 4, space: sRGB,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                                          decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testAnalysisRecoversTheChartThroughScaleAndRotation() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for turns in [0, 1, 2] {
            let url = folder.appendingPathComponent("P0\(turns + 1).tif")
            try syntheticScan(quarterTurns: turns, to: url)
            let scan = try ScanImage.load(url)
            XCTAssertNotNil(scan.embeddedICC, "the TIFF carries its profile")
            let result = try ChartScanAnalysis.analyse(scan, scannerICC: nil, label: "V1", scanName: url.lastPathComponent)
            XCTAssertEqual(result.patches.count, ValidationChart.standard.patches.count)
            XCTAssertLessThan(result.summary.all.mean, 0.05, "turns \(turns)")
            XCTAssertLessThan(result.summary.all.max, 0.3, "turns \(turns)")
            XCTAssertEqual(result.paperWhiteLab[0], 100, accuracy: 0.05)
            XCTAssertEqual(result.summary.darkStepsTotal, 10)
            XCTAssertLessThan(try XCTUnwrap(result.summary.uniformityMax), 0.05)
            XCTAssertEqual(result.marks.count, 4)
            let json = try JSONSerialization.jsonObject(with: ValidationReport.pythonJSON(result)) as! [String: Any]
            XCTAssertEqual(json["label"] as? String, "V1")
            XCTAssertNotNil((json["summary"] as! [String: Any])["colorchecker"])
            XCTAssertTrue(ValidationReport.csv(result).hasPrefix("id,group,name,R,G,B"))
        }
        // A scan without the chart fails with the core's message.
        let blank = folder.appendingPathComponent("blank.tif")
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(blank as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertThrowsError(try ChartScanAnalysis.analyse(try ScanImage.load(blank), scannerICC: nil, label: "V0", scanName: "blank")) {
            XCTAssertEqual(($0 as? ScanAnalysisError)?.errorDescription,
                           ScanAnalysisError.core(SELPHY_ERR_CHART_MARKS).errorDescription)
        }
    }

    func testStatisticsFollowNumpy() {
        XCTAssertEqual(DeltaStats.percentile([1, 2, 3, 4], 50), 2.5)
        XCTAssertEqual(DeltaStats.percentile([1, 2, 3, 4], 95), 3.85, accuracy: 1e-12)
        XCTAssertEqual(DeltaStats.percentile([5], 95), 5)
        let s = DeltaStats([0.1234, 1.98765, 3])
        XCTAssertEqual(s.mean, 1.704)
        XCTAssertEqual(s.median, 1.988)
        XCTAssertEqual(s.n, 3)
    }

    func testScannerCheckOnASyntheticColorChecker() throws {
        // 6 x 4 patches of known sRGB colours; their own Lab is the "reference".
        let columns = 6, rows = 4, pitch = 80, patch = 60
        let w = columns * pitch + 40, h = rows * pitch + 40
        var pixels = [UInt8](repeating: 30, count: w * h * 4)
        var colours: [[Int]] = []
        for r in 0..<rows {
            for c in 0..<columns {
                let rgb = [(r * 60 + c * 30) % 256, (c * 45 + 20) % 256, (r * 70 + 40) % 256]
                colours.append(rgb)
                for y in 0..<patch { for x in 0..<patch {
                    let o = ((20 + r * pitch + (pitch - patch) / 2 + y) * w + 20 + c * pitch + (pitch - patch) / 2 + x) * 4
                    pixels[o] = UInt8(rgb[0]); pixels[o + 1] = UInt8(rgb[1]); pixels[o + 2] = UInt8(rgb[2])
                } }
            }
        }
        let rgb16 = (0..<(w * h)).flatMap { i in (0..<3).map { UInt16(pixels[i * 4 + $0]) * 257 } }
        let scan = ScanImage(width: w, height: h, rgb16: rgb16, embeddedICC: nil, profileName: nil)
        let labs = try ChartScanAnalysis.lab(colours.flatMap { $0.map { UInt16($0) * 257 } }, icc: nil)
        let reference = ReferenceSet(id: "test", model: .classic24, edition: "test", note: "", source: "",
                                     patches: labs.map { ReferencePatch(name: "p", l: $0[0], a: $0[1], b: $0[2]) })
        func centre(_ r: Int, _ c: Int) -> CGPoint { CGPoint(x: 20 + c * pitch + pitch / 2, y: 20 + r * pitch + pitch / 2) }
        let corners = [centre(0, 0), centre(0, 5), centre(3, 0), centre(3, 5)]
        let result = try ScannerCheck.check(scan, corners: corners, reference: reference, scannerICC: nil)
        XCTAssertLessThan(result.summary.max, 0.01)
        XCTAssertTrue(result.isTrustworthy)
        XCTAssertEqual(result.resolution, 1)
        let interpolated = ScannerCheck.patchCentres(corners: corners, columns: 6, rows: 4)[7]
        XCTAssertEqual(interpolated.x, centre(1, 1).x, accuracy: 1e-9)
        XCTAssertEqual(interpolated.y, centre(1, 1).y, accuracy: 1e-9)
        XCTAssertThrowsError(try ScannerCheck.check(scan, corners: [CGPoint(x: 1, y: 1)] + corners.dropFirst(), reference: reference, scannerICC: nil))
    }

    // MARK: Report

    private func result(_ label: String, mean: Double, p95: Double, neutral: Double = 2, uniformity: Double = 0.4, de: Double) -> ChartScanResult {
        let patches = (0..<20).map { MeasuredPatch(id: "p\($0)", group: "colorchecker", name: "p", srgb: [0, 0, 0], intendedLab: [50, 0, 0], measuredLab: [50, 0, 0], de00: de) }
        var summary = ScanSummary.make(patches)
        summary.all = DeltaStats(mean: mean, median: mean, p95: p95, max: p95 + 1, n: 20)
        summary.neutralChromaP95 = neutral
        summary.uniformityMax = uniformity
        return ChartScanResult(label: label, scan: "\(label).tif", paperWhiteLab: [95, 0, 2], patches: patches, summary: summary, marks: [])
    }

    func testGatesAndMarkdown() {
        let results: [ChartVariant: ChartScanResult] = [
            .v0: result("V0", mean: 8.9, p95: 15, de: 9), .v1: result("V1", mean: 4.9, p95: 9, de: 5),
            .v2: result("V2", mean: 3.0, p95: 7, de: 3), .v3: result("V3", mean: 7.2, p95: 12, uniformity: 1.3, de: 7),
        ]
        let gates = ValidationReport.gates(results)
        func gate(_ prefix: String) -> ValidationReport.Gate? { gates.first { $0.name.hasPrefix(prefix) } }
        XCTAssertEqual(gate("G1 ")?.passed, true)
        XCTAssertEqual(gate("G1b")?.passed, true)
        XCTAssertEqual(gate("G1b")?.detail, "20 improved, 0 worsened of 20")
        XCTAssertEqual(gate("G2")?.passed, true)
        XCTAssertEqual(gate("G3")?.passed, true, "V3 worse than V1 by more than 1 dE00")
        XCTAssertEqual(gate("G4 sheet uniformity V3")?.passed, false)
        let text = ValidationReport.markdown(results: results, models: [:], scannerCheck: nil,
                                             visual: [VisualVerdict(photoRole: "portrait", choice: .corrected, notes: "skin better")],
                                             record: "Date: today")
        XCTAssertTrue(text.contains("| V1 | corrected, Perceptual, Image Optimize OFF (main result) | 4.90 |"))
        XCTAssertTrue(text.contains("Lower mean dE00: **V2 (Relative colorimetric)**"))
        XCTAssertTrue(text.contains("| portrait | corrected (V1) | skin better |"))
        XCTAssertTrue(text.contains("Scanner chain not checked"))
        XCTAssertTrue(text.contains("## Session record"))
    }

    func testModelPredictionAgreesWithTheProcedure() throws {
        guard let path = ProcessInfo.processInfo.environment["SELPHY_TEST_PRINTER_PROFILE"] else {
            throw XCTSkip("Set SELPHY_TEST_PRINTER_PROFILE to run real-profile tests.")
        }
        let icc = try Data(contentsOf: URL(fileURLWithPath: path))
        // Documentation/PHYSICAL_VALIDATION.md: about 8.9 (V0), 4.9 (V1), 3.0 (V2).
        let v0 = try ValidationReport.modelSummary(printerICC: icc, variant: .v0).all.mean
        let v1 = try ValidationReport.modelSummary(printerICC: icc, variant: .v1).all.mean
        let v2 = try ValidationReport.modelSummary(printerICC: icc, variant: .v2).all.mean
        XCTAssertEqual(v0, 8.9, accuracy: 0.3)
        XCTAssertEqual(v1, 4.9, accuracy: 0.3)
        XCTAssertEqual(v2, 3.0, accuracy: 0.3)
        XCTAssertEqual(try ValidationReport.modelSummary(printerICC: icc, variant: .v3).all.mean, v1)
    }

    // MARK: Plan and session

    func testPlanIsCompleteBlindAndReproducible() {
        let plan = ValidationPlan.make(mode: .scanner, photos: PhotoRole.allCases, seed: 20261128)
        XCTAssertEqual(plan.count, 13)
        XCTAssertEqual(Set(plan.map(\.code)).count, 13)
        XCTAssertEqual(plan.first?.code, "P01")
        XCTAssertEqual(plan.filter { $0.imageOptimizeOn }.count, 2, "V3 and V4")
        XCTAssertEqual(Set(plan.compactMap(\.chartVariant)), Set(ChartVariant.allCases))
        XCTAssertEqual(ValidationPlan.make(mode: .scanner, photos: PhotoRole.allCases, seed: 20261128), plan)
        XCTAssertNotEqual(ValidationPlan.make(mode: .scanner, photos: PhotoRole.allCases, seed: 1).map(\.variantLabel), plan.map(\.variantLabel))
        let visual = ValidationPlan.make(mode: .visual, photos: [.portrait], seed: 3)
        XCTAssertEqual(Set(visual.map(\.variantLabel)), ["V0", "V1", "portrait/V0", "portrait/V1"])
        let key = ValidationPlan.keyCSV(plan)
        XCTAssertTrue(key.hasPrefix("print_order_code,variant,content,printer_image_optimize\n"))
        let order = ValidationPlan.printOrderCSV(plan)
        XCTAssertFalse(order.contains("V1"), "the print order does not reveal the content")
        XCTAssertTrue(ValidationModel.readme(plan: plan).contains("P13"))
        XCTAssertTrue(ValidationModel.name(URL(fileURLWithPath: "/x/P05.tif"), matches: "P05"))
        XCTAssertTrue(ValidationModel.name(URL(fileURLWithPath: "/x/p05 scan.tiff"), matches: "P05"))
        XCTAssertFalse(ValidationModel.name(URL(fileURLWithPath: "/x/P050.tif"), matches: "P05"))
        XCTAssertFalse(ValidationModel.name(URL(fileURLWithPath: "/x/P06.tif"), matches: "P05"))
    }

    @MainActor
    func testSessionIsSavedAndRestored() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent("session.json")
        let suite = "selphy-validation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = ValidationModel(settings: settings, storeURL: store)
        XCTAssertEqual(model.data.reference.id, ReferenceSet.defaultID)
        XCTAssertEqual(model.data.visual.count, PhotoRole.allCases.count)
        model.data.mode = .visual
        model.makePlan()
        model.data.record = "Date: Saturday"
        model.data.referenceID = "classic-after-2014"
        let restored = ValidationModel(settings: settings, storeURL: store)
        XCTAssertEqual(restored.data, model.data)
        XCTAssertEqual(restored.data.reference.edition, "from November 2014")
        restored.reset()
        XCTAssertEqual(ValidationModel(settings: settings, storeURL: store).data.mode, .scanner)
    }

    @MainActor
    func testExportOfThePrintSet() throws {
        guard let path = ProcessInfo.processInfo.environment["SELPHY_TEST_PRINTER_PROFILE"] else {
            throw XCTSkip("Set SELPHY_TEST_PRINTER_PROFILE to run real-profile tests.")
        }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let plan = ValidationPlan.make(mode: .scanner, photos: [], seed: 5)
        let target = try ValidationModel.writePrintSet(plan: plan, photos: [], folder: folder, profileURL: URL(fileURLWithPath: path))
        let names = try FileManager.default.contentsOfDirectory(atPath: target.path).sorted()
        XCTAssertEqual(names, ["KEY - open only after scanning", "P01.png", "P02.png", "P03.png", "P04.png", "P05.png", "READ ME.txt", "print-order.csv"])
        // V0 and V4 are the same file, as V1 and V3; V1 and V2 differ from the original.
        func data(_ variant: ChartVariant) throws -> Data {
            let code = plan.first { $0.chartVariant == variant }!.code
            return try Data(contentsOf: target.appendingPathComponent("\(code).png"))
        }
        XCTAssertEqual(try data(.v0), try data(.v4))
        XCTAssertEqual(try data(.v1), try data(.v3))
        XCTAssertNotEqual(try data(.v0), try data(.v1))
        XCTAssertNotEqual(try data(.v1), try data(.v2))
        let key = try String(contentsOf: target.appendingPathComponent("KEY - open only after scanning/run-plan.csv"), encoding: .utf8)
        XCTAssertEqual(key, ValidationPlan.keyCSV(plan))
    }
}

final class CGATSTokenTests: XCTestCase {
    func testQuotedNamesStayWhole() {
        XCTAssertEqual(ReferenceImport.cgatsTokens("\"dark skin\" 37.9 13.5\t14.0"), ["dark skin", "37.9", "13.5", "14.0"])
        XCTAssertEqual(ReferenceImport.cgatsTokens("  A1   96.5  "), ["A1", "96.5"])
        XCTAssertEqual(ReferenceImport.cgatsTokens("\"\" 1"), ["", "1"])
    }
}
