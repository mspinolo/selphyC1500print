import XCTest
@testable import SELPHYCP1500Print

final class AnalysisTests: XCTestCase {
    /// A 2 x 2 image: intended L* 5, 20, 50, 90; chroma loss 0, 10, 0, 20; dE 0.5, 2, 4, 8.
    private func makeMaps() -> PixelMaps {
        PixelMaps(
            width: 2, height: 2,
            deltaE: [0.5, 2, 4, 8],
            intendedLab: [5, 0, 0,   20, 30, 0,   50, 0, 0,   90, 40, 0],
            predictedLab: [6, 0, 0,  22, 20, 0,   52, 0, 0,   88, 20, 0]
        )
    }

    // MARK: Scale and colours

    func testStandardScaleKeepsTheOriginalRamp() {
        XCTAssertEqual(Overlays.heatColor(deltaE: 0.5).a, 0)
        XCTAssertEqual(Overlays.heatColor(deltaE: 1).a, 0, "not above the low end")
        XCTAssertEqual(Overlays.heatColor(deltaE: 8).a, 220, "red end: fully ramped")
        let old = PreviewService.heatColor(deltaE: 3)
        let new = Overlays.heatColor(deltaE: 3, scale: .standard)
        XCTAssertEqual(old.a, new.a)
        XCTAssertEqual(old.g, new.g)
    }

    func testAdjustableScaleMovesTheRamp() {
        let narrow = DeltaEScale(low: 2, high: 4)
        XCTAssertEqual(Overlays.heatColor(deltaE: 2, scale: narrow).a, 0)
        XCTAssertGreaterThan(Overlays.heatColor(deltaE: 2.5, scale: narrow).a, 0)
        XCTAssertEqual(Overlays.heatColor(deltaE: 4, scale: narrow).a, 220)
        XCTAssertEqual(Overlays.heatColor(deltaE: 1.5, scale: narrow).a, 0, "below the new low end: transparent")
        XCTAssertEqual(Overlays.heatColor(deltaE: .nan, scale: narrow).a, 0)
        XCTAssertEqual(Overlays.heatColor(deltaE: .infinity, scale: narrow).a, 0, "not finite: transparent")
    }

    func testScaleIsClampedToAUsableRange() {
        let inverted = DeltaEScale(low: 8, high: 3).clamped()
        XCTAssertEqual(inverted.low, 8)
        XCTAssertEqual(inverted.high, 8.5, accuracy: 0.001)
        let extreme = DeltaEScale(low: 90, high: 200).clamped()
        XCTAssertLessThan(extreme.low, extreme.high)
        XCTAssertLessThanOrEqual(extreme.high, 50)
        XCTAssertGreaterThanOrEqual(DeltaEScale(low: -3, high: 1).clamped().low, 0)
    }

    func testRampIsYellowToRedAndGrowsOpaque() {
        XCTAssertEqual(Overlays.ramp(0).green, 255)
        XCTAssertEqual(Overlays.ramp(1).green, 0)
        XCTAssertLessThan(Overlays.ramp(0).alpha, Overlays.ramp(1).alpha)
    }

    // MARK: Masks

    func testShadowMaskMarksPixelsBelowTheDarkestToneAndTheMargin() throws {
        let maps = makeMaps()
        XCTAssertEqual(Overlays.shadowShare(maps, darkestL: 10, margin: 0), 0.25, accuracy: 1e-9)
        XCTAssertEqual(Overlays.shadowShare(maps, darkestL: 10, margin: 12), 0.5, accuracy: 1e-9, "the margin widens the zone")
        XCTAssertEqual(Overlays.shadowShare(maps, darkestL: 0, margin: 0), 0)
        let mask = try XCTUnwrap(Overlays.shadowMask(maps, darkestL: 10, margin: 0))
        XCTAssertEqual(mask.width, 2)
        XCTAssertEqual(mask.height, 2)
        XCTAssertTrue(Overlays.isTooDark(maps, at: 0, darkestL: 10, margin: 0))
        XCTAssertFalse(Overlays.isTooDark(maps, at: 1, darkestL: 10, margin: 0))
    }

    func testGamutMaskMarksPixelsThatLoseChroma() throws {
        let maps = makeMaps()
        XCTAssertEqual(maps.chromaLoss(at: 0), 0, accuracy: 1e-5)
        XCTAssertEqual(maps.chromaLoss(at: 1), 10, accuracy: 1e-4)
        XCTAssertEqual(maps.chromaLoss(at: 3), 20, accuracy: 1e-4)
        XCTAssertEqual(Overlays.gamutShare(maps, minimumLoss: 5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Overlays.gamutShare(maps, minimumLoss: 15), 0.25, accuracy: 1e-9)
        XCTAssertEqual(Overlays.gamutShare(maps, minimumLoss: 25), 0)
        XCTAssertNotNil(Overlays.gamutMask(maps, minimumLoss: 5))
    }

    func testHeatMapHasTheMapSize() throws {
        let image = try XCTUnwrap(Overlays.heatMap(makeMaps(), scale: DeltaEScale(low: 1, high: 8)))
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        XCTAssertNil(Overlays.image(width: 0, height: 5) { _ in (0, 0, 0, 0) })
    }

    // MARK: Geometry and inspector

    func testContentSizeFitsOrZooms() {
        let image = CGSize(width: 1400, height: 700)
        let area = CGSize(width: 700, height: 500)
        let fit = PreviewGeometry.contentSize(imageSize: image, available: area, factor: nil)
        XCTAssertEqual(fit.width, 700, accuracy: 0.01)
        XCTAssertEqual(fit.height, 350, accuracy: 0.01)
        let zoomed = PreviewGeometry.contentSize(imageSize: image, available: area, factor: 2)
        XCTAssertEqual(zoomed.width, 2800, accuracy: 0.01)
        let small = PreviewGeometry.contentSize(imageSize: CGSize(width: 200, height: 100), available: area, factor: 1)
        XCTAssertEqual(small.width, 500, accuracy: 0.01, "a zoom below the fitted size keeps the fitted size")
        XCTAssertEqual(PreviewGeometry.contentSize(imageSize: .zero, available: area, factor: nil), area)
    }

    func testReadingPicksTheRightPixel() throws {
        let maps = makeMaps()
        let topLeft = try XCTUnwrap(PreviewGeometry.reading(maps: maps, u: 0.1, v: 0.1))
        XCTAssertEqual(topLeft.x, 0); XCTAssertEqual(topLeft.y, 0)
        XCTAssertEqual(topLeft.intended.l, 5); XCTAssertEqual(topLeft.deltaE, 0.5)
        let bottomRight = try XCTUnwrap(PreviewGeometry.reading(maps: maps, u: 1, v: 1))
        XCTAssertEqual(bottomRight.x, 1); XCTAssertEqual(bottomRight.y, 1)
        XCTAssertEqual(bottomRight.predicted.l, 88)
        let right = try XCTUnwrap(PreviewGeometry.reading(maps: maps, u: 0.9, v: 0.2))
        XCTAssertEqual(right.intended.l, 20)
        XCTAssertNil(PreviewGeometry.reading(maps: maps, u: -0.1, v: 0.5))
        XCTAssertNil(PreviewGeometry.reading(maps: maps, u: 0.5, v: 1.2))
    }
}
