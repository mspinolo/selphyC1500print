import XCTest
@testable import SELPHYCP1500Print

final class DeltaEScopeTests: XCTestCase {
    /// 10 x 10 pixels; ΔE00 = column index (0...9); L* = 10 * column + 5; hue set per row.
    private func maps(hueRows: Bool = false) -> PixelMaps {
        let width = 10, height = 10
        var deltaE: [Float] = []
        var lab: [Float] = []
        for y in 0..<height {
            for x in 0..<width {
                deltaE.append(Float(x))
                let l = Float(x * 10 + 5)
                if hueRows {
                    // Rows 0-4 neutral, 5-7 hue 0°, 8-9 hue 90°.
                    switch y {
                    case 0..<5: lab += [l, 0, 0]
                    case 5..<8: lab += [l, 20, 0]
                    default: lab += [l, 0, 20]
                    }
                } else {
                    lab += [l, 0, 0]
                }
            }
        }
        return PixelMaps(width: width, height: height, deltaE: deltaE, intendedLab: lab, predictedLab: lab)
    }

    func testWidthAxisIsOneHistogramPerColumn() throws {
        let scope = DeltaEScope.make(maps: maps(), axis: .width)
        XCTAssertEqual(scope.columns, 10)
        XCTAssertEqual(scope.columnTotals, Array(repeating: 10, count: 10))
        XCTAssertEqual(scope.plottedPixels, 100)
        for column in 0..<10 {
            let median = try XCTUnwrap(scope.median[column])
            XCTAssertEqual(median, Float(column), accuracy: DeltaEScope.binWidth, "column \(column)")
            XCTAssertEqual(try XCTUnwrap(scope.p95[column]), Float(column), accuracy: DeltaEScope.binWidth)
            let row = Int(Float(column) / DeltaEScope.binWidth)
            XCTAssertEqual(scope.counts[column * DeltaEScope.rows + row], 10)
        }
        XCTAssertEqual(scope.maxCount, 10)
        XCTAssertEqual(scope.column(at: 0), 0)
        XCTAssertEqual(scope.column(at: 0.55), 5)
        XCTAssertEqual(scope.column(at: 1), 9)
    }

    func testHeightAxisMixesTheColumns() throws {
        let scope = DeltaEScope.make(maps: maps(), axis: .height)
        XCTAssertEqual(scope.columns, 10)
        for row in 0..<10 {
            XCTAssertEqual(scope.columnTotals[row], 10)
            XCTAssertEqual(try XCTUnwrap(scope.median[row]), 4, accuracy: 0.2)
            XCTAssertEqual(try XCTUnwrap(scope.p95[row]), 9, accuracy: 0.2)
        }
    }

    func testLightnessAxisPutsEachToneInItsColumn() {
        let scope = DeltaEScope.make(maps: maps(), axis: .lightness)
        XCTAssertEqual(scope.columns, 100)
        for x in 0..<10 {
            XCTAssertEqual(scope.columnTotals[x * 10 + 5], 10, "L* \(x * 10 + 5)")
        }
        XCTAssertEqual(scope.columnTotals.reduce(0, +), 100)
        XCTAssertNil(scope.median[0], "an empty column has no lines")
    }

    func testHueAxisLeavesNeutralPixelsOut() {
        let scope = DeltaEScope.make(maps: maps(hueRows: true), axis: .hue)
        XCTAssertEqual(scope.columns, 120)
        XCTAssertEqual(scope.plottedPixels, 50)
        XCTAssertEqual(scope.totalPixels, 100)
        XCTAssertEqual(scope.columnTotals[0], 30, "hue 0°")
        XCTAssertEqual(scope.columnTotals[29] + scope.columnTotals[30], 20, "hue 90°")
    }

    func testLargeDeviationsGoToTheTopRowAndTheImageIsMade() throws {
        let m = PixelMaps(width: 2, height: 1, deltaE: [50, .nan], intendedLab: [50, 0, 0, 50, 0, 0], predictedLab: [50, 0, 0, 50, 0, 0])
        let scope = DeltaEScope.make(maps: m, axis: .width)
        XCTAssertEqual(scope.counts[0 * DeltaEScope.rows + DeltaEScope.rows - 1], 1)
        XCTAssertEqual(scope.counts[1 * DeltaEScope.rows + DeltaEScope.rows - 1], 1)
        let image = try XCTUnwrap(scope.densityImage())
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, DeltaEScope.rows)
        XCTAssertNil(DeltaEScope.make(maps: PixelMaps(width: 1, height: 1, deltaE: [1], intendedLab: [50, 0, 0], predictedLab: [50, 0, 0]), axis: .hue)
                        .densityImage(), "nothing to draw")
    }
}

final class GamutPlotTests: XCTestCase {
    func testOutlineIsTheLargestChromaPerHue() {
        let outline = GamutOutline(labs: [[50, 40, 0], [60, 20, 0], [50, 0, 30], [50, -10, -10]])
        XCTAssertEqual(outline.chroma(atHue: 0), 40)
        XCTAssertEqual(outline.chroma(atHue: 90), 30)
        XCTAssertEqual(outline.chroma(atHue: 225), (200.0).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(outline.chroma(atHue: 360), 40, "hue wraps")
        XCTAssertEqual(outline.chroma.count, GamutOutline.bins)
    }

    func testSRGBOutlineHasTheKnownPrimaries() {
        // sRGB primaries in Lab D50 (relative): red C* about 104, blue about 131, green about 120.
        let s = GamutOutline.sRGB
        XCTAssertEqual(s.chroma.max() ?? 0, 131, accuracy: 6)
        XCTAssertGreaterThan(s.chroma(atHue: 40), 95)
        XCTAssertLessThan(s.chroma.min() ?? 0, s.chroma.max() ?? 0)
        XCTAssertEqual(GamutOutline.cubeSurface(steps: 5).count, 5 * 5 * 6 * 3)
    }

    func testPrinterGamutIsSmallerThanSRGBInTheBlues() throws {
        guard let path = ProcessInfo.processInfo.environment["SELPHY_TEST_PRINTER_PROFILE"] else {
            throw XCTSkip("Set SELPHY_TEST_PRINTER_PROFILE to run real-profile tests.")
        }
        let printer = try XCTUnwrap(GamutOutline.printer(icc: try Data(contentsOf: URL(fileURLWithPath: path))))
        // A dye-sublimation print does not reach the saturated sRGB blue.
        XCTAssertLessThan(printer.chroma(atHue: 300), GamutOutline.sRGB.chroma(atHue: 300))
        XCTAssertGreaterThan(printer.chroma.min() ?? 0, 10)
    }

    func testPointsAreSampledAndMarked() {
        let maps = PixelMaps(width: 10, height: 10, deltaE: Array(repeating: 1, count: 100),
                             intendedLab: (0..<100).flatMap { i -> [Float] in [50, Float(i % 2 == 0 ? 60 : 5), 0] },
                             predictedLab: Array(repeating: [Float(50), 30, 0], count: 100).flatMap { $0 })
        let points = GamutPoint.sample(maps, limit: 20)
        XCTAssertEqual(points.count, 20)
        XCTAssertTrue(points.contains { $0.dull }, "C* 60 printed at 30: dull")
        XCTAssertTrue(points.contains { !$0.dull })
    }
}
