import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import SELPHYCP1500Print

@MainActor
final class PrintServiceTests: XCTestCase {
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: Layout

    func testFitKeepsTheWholeImageAndCentresIt() {
        let sheet = CGRect(x: 0, y: 0, width: 283, height: 420)             // Postcard, portrait
        let rect = PrintLayout.imageRect(imageSize: CGSize(width: 3000, height: 2000), in: sheet, fit: .fit)
        XCTAssertEqual(rect.width, 283, accuracy: 0.01)
        XCTAssertEqual(rect.height, 283 * 2000 / 3000, accuracy: 0.01)
        XCTAssertEqual(rect.midX, sheet.midX, accuracy: 0.01)
        XCTAssertEqual(rect.midY, sheet.midY, accuracy: 0.01)
        XCTAssertTrue(sheet.contains(rect), "fit never leaves the sheet")
    }

    func testFillCoversTheSheetAndCropsTheOverflow() {
        let sheet = CGRect(x: 0, y: 0, width: 283, height: 420)
        let rect = PrintLayout.imageRect(imageSize: CGSize(width: 3000, height: 2000), in: sheet, fit: .fill)
        XCTAssertEqual(rect.height, 420, accuracy: 0.01)
        XCTAssertEqual(rect.width, 420 * 3000 / 2000, accuracy: 0.01)
        XCTAssertTrue(rect.contains(sheet), "fill covers the whole sheet")
        XCTAssertEqual(rect.midX, sheet.midX, accuracy: 0.01)
    }

    func testDegenerateSizesDoNotCrash() {
        let sheet = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(PrintLayout.imageRect(imageSize: .zero, in: sheet, fit: .fit), sheet)
        XCTAssertEqual(PrintLayout.imageRect(imageSize: CGSize(width: 10, height: 10), in: .zero, fit: .fill), .zero)
    }

    func testOrientationFollowsTheImage() {
        XCTAssertEqual(PrintLayout.orientation(for: CGSize(width: 3000, height: 2000)), .landscape)
        XCTAssertEqual(PrintLayout.orientation(for: CGSize(width: 2000, height: 3000)), .portrait)
        XCTAssertEqual(PrintLayout.orientation(for: CGSize(width: 2000, height: 2000)), .portrait)
    }

    // MARK: Drawing: the pixels reach the page untouched

    private func makeBandsImage(width: Int = 300, height: Int = 100) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bands: [[CGFloat]] = [[200, 40, 40], [40, 200, 40], [40, 40, 200]]
        for (index, band) in bands.enumerated() {
            let color = try XCTUnwrap(CGColor(colorSpace: sRGB, components: band.map { $0 / 255 } + [1]))
            context.setFillColor(color)
            context.fill(CGRect(x: index * width / 3, y: 0, width: width / 3, height: height))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func render(_ view: NSView, width: Int, height: Int) throws -> CGContext {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return context
    }

    private func pixel(_ context: CGContext, x: Int, yFromTop y: Int) throws -> [Int] {
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = y * context.bytesPerRow + x * 4
        return (0..<4).map { Int(data[offset + $0]) }
    }

    private func assertPixel(_ actual: [Int], _ expected: [Int], tolerance: Int = 1, file: StaticString = #filePath, line: UInt = #line) {
        for channel in 0..<4 {
            XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), tolerance,
                                     "channel \(channel): \(actual) vs \(expected)", file: file, line: line)
        }
    }

    func testFitDrawsTheSourceColoursUnchangedAndLeavesTheRestBlank() throws {
        let view = PrintImageView(image: try makeBandsImage(), fit: .fit, size: CGSize(width: 300, height: 100))
        let context = try render(view, width: 300, height: 100)
        assertPixel(try pixel(context, x: 50, yFromTop: 50), [200, 40, 40, 255])
        assertPixel(try pixel(context, x: 150, yFromTop: 50), [40, 200, 40, 255])
        assertPixel(try pixel(context, x: 250, yFromTop: 50), [40, 40, 200, 255])
    }

    func testFitIntoASquareLeavesBlankMargins() throws {
        let view = PrintImageView(image: try makeBandsImage(), fit: .fit, size: CGSize(width: 100, height: 100))
        let context = try render(view, width: 100, height: 100)
        XCTAssertEqual(try pixel(context, x: 50, yFromTop: 5)[3], 0, "above the image: nothing drawn")
        XCTAssertEqual(try pixel(context, x: 50, yFromTop: 95)[3], 0, "below the image: nothing drawn")
        assertPixel(try pixel(context, x: 50, yFromTop: 50), [40, 200, 40, 255])
    }

    func testFillCropsToTheMiddleOfTheImage() throws {
        let view = PrintImageView(image: try makeBandsImage(), fit: .fill, size: CGSize(width: 100, height: 100))
        let context = try render(view, width: 100, height: 100)
        for x in [5, 50, 95] {
            assertPixel(try pixel(context, x: x, yFromTop: 50), [40, 200, 40, 255])
        }
        XCTAssertEqual(try pixel(context, x: 5, yFromTop: 5)[3], 255, "fill covers the corners")
    }

    // MARK: Operation

    private func writePNG(_ image: CGImage) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selphy-print-\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testOperationIsBuiltFromTheFile() throws {
        let url = try writePNG(try makeBandsImage())
        defer { try? FileManager.default.removeItem(at: url) }
        let operation = try PrintService.makeOperation(for: url, fit: .fit, printInfo: PrintService.defaultPrintInfo(), showsPanel: true)
        XCTAssertEqual(operation.jobTitle, url.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(operation.printInfo.orientation, .landscape, "a wide image is printed landscape")
        XCTAssertTrue(operation.showsPrintPanel)
        XCTAssertTrue(operation.view is PrintImageView)
        let second = try PrintService.makeOperation(for: url, fit: .fill, printInfo: PrintService.defaultPrintInfo(), showsPanel: false)
        XCTAssertFalse(second.showsPrintPanel, "the panel is shown for the first sheet only")
    }

    func testUnreadableFilesFailWithAMessage() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).png")
        XCTAssertThrowsError(try PrintService.makeOperation(for: missing, fit: .fit, printInfo: PrintService.defaultPrintInfo(), showsPanel: false)) { error in
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains(missing.lastPathComponent) == true)
        }
        let notAnImage = FileManager.default.temporaryDirectory.appendingPathComponent("selphy-print-\(UUID().uuidString).png")
        try Data("not an image".utf8).write(to: notAnImage)
        defer { try? FileManager.default.removeItem(at: notAnImage) }
        XCTAssertThrowsError(try PrintService.loadImage(from: notAnImage))
    }

    func testDefaultPrintInfoUsesTheWholePageAtFullScale() {
        let info = PrintService.defaultPrintInfo()
        XCTAssertEqual(info.topMargin, 0)
        XCTAssertEqual(info.leftMargin, 0)
        XCTAssertEqual(info.scalingFactor, 1)
        XCTAssertTrue(info.isHorizontallyCentered && info.isVerticallyCentered)
    }
}
