import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SELPHYCP1500Print

@MainActor
final class FullScreenTests: XCTestCase {
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func writeImage(width: Int, height: Int, type: UTType = .png, orientation: Int? = nil) throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: sRGB, colors: [
            NSColor(hue: 0.05, saturation: 0.8, brightness: 0.9, alpha: 1).cgColor,
            NSColor(hue: 0.6, saturation: 0.6, brightness: 0.2, alpha: 1).cgColor] as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let image = try XCTUnwrap(context.makeImage())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("selphy-full-\(UUID().uuidString).\(type == .png ? "png" : "jpg")")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeSettings() throws -> (AppSettings, () -> Void) {
        let suite = "selphy-full-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (AppSettings(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    // MARK: Image size and geometry

    func testOrientedPixelSizeReadsTheHeaderAndSwapsRotatedPhotos() throws {
        let upright = try writeImage(width: 300, height: 200, type: .jpeg)
        let rotated = try writeImage(width: 300, height: 200, type: .jpeg, orientation: 6)
        defer { [upright, rotated].forEach { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertEqual(ImageInfo.orientedPixelSize(of: upright), CGSize(width: 300, height: 200))
        XCTAssertEqual(ImageInfo.orientedPixelSize(of: rotated), CGSize(width: 200, height: 300))
        XCTAssertNil(ImageInfo.orientedPixelSize(of: URL(fileURLWithPath: "/tmp/selphy-missing-\(UUID().uuidString).jpg")))
    }

    func testGeometry() {
        XCTAssertEqual(FullScreenGeometry.fitScale(image: CGSize(width: 6000, height: 4000), in: CGSize(width: 1500, height: 1000)), 0.25)
        XCTAssertEqual(FullScreenGeometry.fitScale(image: CGSize(width: 1000, height: 4000), in: CGSize(width: 1500, height: 1000)), 0.25)
        XCTAssertEqual(FullScreenGeometry.actualPixelsScale(backingScale: 2), 0.5)
        XCTAssertEqual(FullScreenGeometry.actualPixelsScale(backingScale: 1), 1)
        // Fits: no offset; larger: at most half the overflow.
        XCTAssertEqual(FullScreenGeometry.clampedOffset(CGSize(width: 50, height: -50), display: CGSize(width: 800, height: 600),
                                                       area: CGSize(width: 1000, height: 700)), .zero)
        XCTAssertEqual(FullScreenGeometry.clampedOffset(CGSize(width: 900, height: -900), display: CGSize(width: 3000, height: 2000),
                                                       area: CGSize(width: 1000, height: 1000)), CGSize(width: 900, height: -500))
    }

    // MARK: Keys and commands

    func testKeysAndModifiers() {
        func command(_ characters: String, _ keyCode: UInt16 = 0, _ modifiers: NSEvent.ModifierFlags = []) -> FullScreenModel.Command? {
            FullScreenModel.command(characters: characters, keyCode: keyCode, modifiers: modifiers)
        }
        XCTAssertEqual(command("1"), .mode(.original))
        XCTAssertEqual(command("2"), .mode(.uncorrected))
        XCTAssertEqual(command("3"), .mode(.corrected))
        XCTAssertEqual(command("4"), .mode(.compare))
        XCTAssertEqual(command("S"), .toggleSideBySide)
        XCTAssertEqual(command("z"), .toggleActualPixels)
        XCTAssertEqual(command("+"), .zoomIn)
        XCTAssertEqual(command("-"), .zoomOut)
        XCTAssertEqual(command("i"), .toggleHUD)
        XCTAssertEqual(command("", 53), .close)
        XCTAssertEqual(command("", 123), .previous)
        XCTAssertEqual(command("", 124), .next)
        XCTAssertNil(command("f", 3, [.command, .shift]), "menu shortcuts are left to the menu")
        XCTAssertNil(command("1", 18, [.option]))
        XCTAssertNil(command("q"))
    }

    func testZoomNavigationAndIndications() throws {
        let (settings, cleanup) = try makeSettings()
        defer { cleanup() }
        let photos = (0..<3).map { URL(fileURLWithPath: "/tmp/selphy-full-\($0).png") }
        let selection = PhotoSelection()
        let model = FullScreenModel(photos: photos, current: photos[1], settings: settings, selection: selection)
        XCTAssertEqual(model.index, 1)
        model.backingScale = 2
        model.area = CGSize(width: 1500, height: 1000)
        model.handle(.mode(.corrected))
        // No photo decoded (missing files): the header size is unknown, so give it here through a preview-less path.
        XCTAssertEqual(model.effectiveImageSize, .zero)

        model.handle(.toggleSideBySide)
        XCTAssertEqual(model.mode, .compare)
        XCTAssertTrue(model.sideBySide)
        XCTAssertEqual(model.paneArea, CGSize(width: 750, height: 1000))
        model.handle(.toggleSideBySide)
        XCTAssertFalse(model.sideBySide)

        model.handle(.next)
        XCTAssertEqual(model.index, 2)
        XCTAssertEqual(selection.selected, photos[2], "the main window follows the photo shown")
        model.handle(.next)
        XCTAssertEqual(model.index, 2, "stops at the last photo")
        model.handle(.previous)
        model.handle(.previous)
        model.handle(.previous)
        XCTAssertEqual(model.index, 0)
        model.select(1)
        XCTAssertEqual(model.index, 1)
        XCTAssertNotNil(model.errorMessage, "no profile chosen in these settings")

        XCTAssertTrue(model.hudVisible)
        model.handle(.toggleHUD)
        XCTAssertFalse(model.hudVisible)
        model.activity()
        XCTAssertFalse(model.hudVisible, "hidden indications stay hidden until I is pressed again")
        model.handle(.toggleHUD)
        XCTAssertTrue(model.hudVisible)

        var closed = false
        model.onClose = { closed = true }
        model.handle(.close)
        XCTAssertTrue(closed)
        model.stop()
    }

    func testZoomStepsAndActualPixelsWithAKnownImage() throws {
        let (settings, cleanup) = try makeSettings()
        defer { cleanup() }
        let url = try writeImage(width: 3000, height: 2000)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = FullScreenModel(photos: [url], current: url, settings: settings, selection: nil)
        model.backingScale = 2
        model.area = CGSize(width: 1500, height: 1000)
        model.load()      // fails on the missing profile, but reads the image size from the header
        XCTAssertEqual(model.effectiveImageSize, CGSize(width: 3000, height: 2000))
        XCTAssertEqual(model.fitScale, 0.5)
        XCTAssertNil(model.zoom)
        XCTAssertEqual(model.zoomPercent, 100, "fit happens to be 100% on a 2x screen here")

        model.area = CGSize(width: 750, height: 500)
        XCTAssertEqual(model.zoomPercent, 50)
        model.handle(.toggleActualPixels)
        XCTAssertEqual(model.zoom, 0.5)
        XCTAssertEqual(model.zoomPercent, 100)
        XCTAssertEqual(model.displaySize, CGSize(width: 1500, height: 1000))
        model.pan(by: CGSize(width: 10_000, height: -10_000))
        XCTAssertEqual(model.offset, CGSize(width: 375, height: -250), "stops at the image edge")
        model.handle(.zoomIn)
        XCTAssertEqual(model.zoomPercent, 150)
        for _ in 0..<20 { model.handle(.zoomIn) }
        XCTAssertEqual(model.zoomPercent, 800, "at most 800%")
        for _ in 0..<20 { model.handle(.zoomOut) }
        XCTAssertNil(model.zoom, "zooming out ends at fit")
        XCTAssertEqual(model.offset, .zero)
        model.handle(.toggleActualPixels)
        model.handle(.toggleActualPixels)
        XCTAssertNil(model.zoom)
        model.stop()
    }

    // MARK: Full resolution

    func testFullResolutionPreviewKeepsEveryPixel() throws {
        guard let path = ProcessInfo.processInfo.environment["SELPHY_TEST_PRINTER_PROFILE"] else {
            throw XCTSkip("Set SELPHY_TEST_PRINTER_PROFILE to run real-profile tests.")
        }
        let profile = try Data(contentsOf: URL(fileURLWithPath: path))
        let url = try writeImage(width: 2400, height: 1600)
        let rotated = try writeImage(width: 2400, height: 1600, type: .jpeg, orientation: 6)
        defer { [url, rotated].forEach { try? FileManager.default.removeItem(at: $0) } }
        var options = PreviewService.Options(intent: .perceptual, blackPointCompensation: false)
        let reduced = try PreviewSession().makePreview(sourceURL: url, printerICC: profile, display: nil, options: options)
        XCTAssertEqual(max(reduced.original.width, reduced.original.height), options.maxDimension)
        options.maxDimension = Int.max
        let session = PreviewSession(corrections: 2, transforms: 2, renders: 2)
        let full = try session.makePreview(sourceURL: url, printerICC: profile, display: nil, options: options)
        for image in [full.original, full.uncorrected, full.corrected] {
            XCTAssertEqual(image.width, 2400)
            XCTAssertEqual(image.height, 1600)
        }
        let turned = try session.makePreview(sourceURL: rotated, printerICC: profile, display: nil, options: options)
        XCTAssertEqual(turned.corrected.width, 1600)
        XCTAssertEqual(turned.corrected.height, 2400)
        // The statistics stay on the reduced analysis copy, so they match the panel's.
        XCTAssertEqual(full.stats.meanDeltaE, reduced.stats.meanDeltaE, accuracy: 0.3)
    }

    func testFullResolutionLayersArriveInTheOrderAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["SELPHY_TEST_PRINTER_PROFILE"] else {
            throw XCTSkip("Set SELPHY_TEST_PRINTER_PROFILE to run real-profile tests.")
        }
        let profile = try Data(contentsOf: URL(fileURLWithPath: path))
        let url = try writeImage(width: 2400, height: 1600)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = PreviewSession(corrections: 2, transforms: 2, renders: 2)
        let options = PreviewService.Options(intent: .perceptual, blackPointCompensation: false)
        var delivered: [PreviewSession.FullLayer] = []
        try session.fullResolutionLayers(sourceURL: url, printerICC: profile, display: nil, options: options,
                                         order: [.original, .corrected, .uncorrected]) { layer, image in
            delivered.append(layer)
            XCTAssertEqual(image.width, 2400)
            XCTAssertEqual(image.height, 1600)
        }
        XCTAssertEqual(delivered, [.original, .corrected, .uncorrected])
        XCTAssertEqual(session.counters.corrections, 1, "one correction stage for both rendered layers")
        // Asked again: from the cache, nothing recomputed.
        delivered = []
        try session.fullResolutionLayers(sourceURL: url, printerICC: profile, display: nil, options: options,
                                         order: [.uncorrected, .corrected]) { layer, _ in delivered.append(layer) }
        XCTAssertEqual(delivered, [.uncorrected, .corrected])
        XCTAssertEqual(session.counters.corrections, 1)
        // Only the original: no correction needed at all.
        let fresh = PreviewSession()
        try fresh.fullResolutionLayers(sourceURL: url, printerICC: profile, display: nil, options: options, order: [.original]) { _, _ in }
        XCTAssertEqual(fresh.counters.corrections, 0)
        // Cancelled before starting: nothing delivered.
        var none = 0
        try PreviewSession().fullResolutionLayers(sourceURL: url, printerICC: profile, display: nil, options: options,
                                                  order: [.corrected], isCancelled: { true }) { _, _ in none += 1 }
        XCTAssertEqual(none, 0)
    }

    func testFullResolutionTimingOf24Megapixels() throws {
        guard let path = ProcessInfo.processInfo.environment["SELPHY_TEST_PRINTER_PROFILE"] else {
            throw XCTSkip("Set SELPHY_TEST_PRINTER_PROFILE to run real-profile tests.")
        }
        let profile = try Data(contentsOf: URL(fileURLWithPath: path))
        let url = try writeImage(width: 6000, height: 4000, type: .jpeg)
        defer { try? FileManager.default.removeItem(at: url) }
        var options = PreviewService.Options(intent: .perceptual, blackPointCompensation: false)
        options.maxDimension = Int.max
        let session = PreviewSession(corrections: 2, transforms: 2, renders: 2)
        let start = Date()
        let full = try session.makePreview(sourceURL: url, printerICC: profile, display: nil, options: options)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(full.corrected.width, 6000)
        let stages = session.timings.sorted { $0.key < $1.key }.map { String(format: "%@=%.2f", $0.key, $0.value) }.joined(separator: " ")
        print(String(format: "Preview check timing full-res 6000x4000: %.2f s; stages %@; %d cores",
                     elapsed, stages, ProcessInfo.processInfo.activeProcessorCount))

        // The path of the full-screen view: one layer at a time, the needed one first.
        let screen = PreviewSession(corrections: 2, transforms: 2, renders: 2)
        var delivered: [(PreviewSession.FullLayer, TimeInterval)] = []
        let layersStart = Date()
        try screen.fullResolutionLayers(sourceURL: url, printerICC: profile, display: nil, options: options,
                                        order: [.corrected, .uncorrected, .original]) { layer, image in
            XCTAssertEqual(image.width, 6000)
            delivered.append((layer, Date().timeIntervalSince(layersStart)))
        }
        XCTAssertEqual(delivered.map(\.0), [.corrected, .uncorrected, .original])
        let layerStages = screen.timings.sorted { $0.key < $1.key }.map { String(format: "%@=%.2f", $0.key, $0.value) }.joined(separator: " ")
        print(String(format: "Preview check timing full-screen layers 6000x4000: corrected after %.2f s, uncorrected %.2f s, original %.2f s; stages %@",
                     delivered[0].1, delivered[1].1, delivered[2].1, layerStages))
    }
}
