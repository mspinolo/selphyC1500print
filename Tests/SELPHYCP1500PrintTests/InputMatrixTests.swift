import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SELPHYCP1500Print

/// Validation-matrix gaps (VALIDATION_PLAN.md): 16-bit and linear inputs, Display P3 sources,
/// a very large image, and the wide-gamut original in the preview.
final class InputMatrixTests: XCTestCase {
    private func profileURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["SELPHY_TEST_PRINTER_PROFILE"] else {
            throw XCTSkip("Set SELPHY_TEST_PRINTER_PROFILE to run real-profile tests.")
        }
        return URL(fileURLWithPath: path)
    }

    private func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("selphy-matrix-\(UUID().uuidString).\(ext)")
    }

    /// A 16-bit RGB image from big-endian samples (three per pixel).
    private func write16(_ samples: [UInt16], width: Int, height: Int, space: CGColorSpace, type: UTType, to url: URL) throws {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 8)
        for p in 0..<(width * height) {
            for c in 0..<3 {
                let v = samples[p * 3 + c]
                bytes.append(UInt8(v >> 8)); bytes.append(UInt8(v & 0xFF))
            }
            bytes.append(0); bytes.append(0)
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8, space: space,
            bitmapInfo: CGBitmapInfo.byteOrder16Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func solid16(_ rgb: [Double], space: CGColorSpace, type: UTType = .png) throws -> URL {
        let url = temporaryURL(type == .png ? "png" : "tif")
        let v = rgb.map { UInt16(max(0, min(65535, ($0 * 65535).rounded()))) }
        try write16(Array(repeating: v, count: 16 * 16).flatMap { $0 }, width: 16, height: 16, space: space, type: type, to: url)
        return url
    }

    private func corrected(_ url: URL, intent: RenderingIntent = .relativeColorimetric) throws -> [UInt8] {
        let result = try ColorCorrectionService.prepareCopies(from: [url], printerProfileURL: try profileURL(),
                                                              intent: intent, blackPointCompensation: false)
        defer { try? FileManager.default.removeItem(at: result.folder) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(try XCTUnwrap(result.files.first) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: try XCTUnwrap(image.colorSpace),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    private func centre(_ pixels: [UInt8], width: Int = 16, height: Int = 16) -> [Int] {
        let o = ((height / 2) * width + width / 2) * 4
        return [Int(pixels[o]), Int(pixels[o + 1]), Int(pixels[o + 2])]
    }

    private func maxDifference(_ a: [Int], _ b: [Int]) -> Int { zip(a, b).map { abs($0 - $1) }.max() ?? 0 }

    // MARK: 16-bit

    /// Steps finer than one 8-bit level must survive the conversion: a 16-bit grey ramp gives
    /// more distinct, monotonic output levels than the same ramp quantised to 8 bits.
    func testSixteenBitInputKeepsItsPrecision() throws {
        let width = 256
        let ramp16 = (0..<width).map { UInt16(20_000 + $0 * 24) }          // 24/65535: about a tenth of an 8-bit step
        let ramp8 = ramp16.map { UInt16((Double($0) / 257).rounded()) * 257 }
        let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let url16 = temporaryURL("png"), url8 = temporaryURL("png")
        defer { [url16, url8].forEach { try? FileManager.default.removeItem(at: $0) } }
        try write16(ramp16.flatMap { [$0, $0, $0] }, width: width, height: 1, space: sRGB, type: .png, to: url16)
        try write16(ramp8.flatMap { [$0, $0, $0] }, width: width, height: 1, space: sRGB, type: .png, to: url8)
        let out16 = try corrected(url16), out8 = try corrected(url8)
        func channel(_ pixels: [UInt8], _ c: Int) -> [Int] { (0..<width).map { Int(pixels[$0 * 4 + c]) } }
        var distinct16 = 0, distinct8 = 0
        for c in 0..<3 {
            let a = channel(out16, c), b = channel(out8, c)
            // Monotonic, as the ramp: no reversal beyond rounding.
            for i in 1..<width { XCTAssertGreaterThanOrEqual(a[i], a[i - 1] - 1, "channel \(c) at \(i)") }
            distinct16 += Set(a).count
            distinct8 += Set(b).count
        }
        XCTAssertNotEqual(out16, out8, "16-bit values between 8-bit levels must change the result")
        XCTAssertGreaterThanOrEqual(distinct16, distinct8)
    }

    // MARK: Linear

    /// The same colours stored linear (16-bit, linear sRGB) or gamma-encoded give the same print.
    func testLinearInputMatchesTheEncodedOne() throws {
        let linear = try XCTUnwrap(CGColorSpace(name: CGColorSpace.linearSRGB))
        let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        func decode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        for colour in [[0.8, 0.45, 0.3], [0.2, 0.5, 0.75], [0.5, 0.5, 0.5], [0.1, 0.12, 0.09]] {
            let encodedURL = try solid16(colour, space: sRGB)
            let linearURL = try solid16(colour.map(decode), space: linear, type: .tiff)
            defer { [encodedURL, linearURL].forEach { try? FileManager.default.removeItem(at: $0) } }
            let a = centre(try corrected(encodedURL)), b = centre(try corrected(linearURL))
            XCTAssertLessThanOrEqual(maxDifference(a, b), 1, "colour \(colour): \(a) vs \(b)")
        }
    }

    // MARK: Display P3

    func testDisplayP3SourcesAreHonoured() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        // A colour inside sRGB written in P3 numbers prints as the same colour written in sRGB.
        for colour in [[0.7, 0.4, 0.25], [0.3, 0.55, 0.7]] {
            let inSRGB = try XCTUnwrap(CGColor(colorSpace: sRGB, components: colour.map { CGFloat($0) } + [1]))
            let asP3 = try XCTUnwrap(inSRGB.converted(to: p3, intent: .relativeColorimetric, options: nil)?.components)
            let srgbURL = try solid16(colour, space: sRGB)
            let p3URL = try solid16(asP3.prefix(3).map { Double($0) }, space: p3)
            defer { [srgbURL, p3URL].forEach { try? FileManager.default.removeItem(at: $0) } }
            let a = centre(try corrected(srgbURL)), b = centre(try corrected(p3URL))
            XCTAssertLessThanOrEqual(maxDifference(a, b), 1, "colour \(colour): \(a) vs \(b)")
        }
        // The same numbers mean a more saturated colour in P3: the result must differ.
        let redSRGB = try solid16([1, 0, 0], space: sRGB), redP3 = try solid16([1, 0, 0], space: p3)
        defer { [redSRGB, redP3].forEach { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertGreaterThan(maxDifference(centre(try corrected(redSRGB)), centre(try corrected(redP3))), 2)
    }

    /// The preview's Original view shows a P3 photo with its own colours, not clipped to sRGB.
    func testPreviewOriginalKeepsAWideGamut() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let url = try solid16([1, 0, 0], space: p3)
        defer { try? FileManager.default.removeItem(at: url) }
        let printerICC = try Data(contentsOf: try profileURL())
        let preview = try PreviewSession().makePreview(sourceURL: url, printerICC: printerICC, display: nil,
                                                       options: PreviewService.Options(intent: .perceptual, blackPointCompensation: false))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: p3,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(preview.original, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThanOrEqual(pixel[0], 250, "P3 red stays P3 red")
        XCTAssertLessThanOrEqual(pixel[1], 6)
        XCTAssertLessThanOrEqual(pixel[2], 6)
    }

    // MARK: Very large image

    func testVeryLargeImageTiming() throws {
        let width = 6000, height = 4000
        let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: sRGB, colors: [CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1),
                                                                         CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1)] as CFArray,
                                                locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let url = temporaryURL("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let start = Date()
        let result = try ColorCorrectionService.prepareCopies(from: [url], printerProfileURL: try profileURL(),
                                                              intent: .perceptual, blackPointCompensation: false)
        defer { try? FileManager.default.removeItem(at: result.folder) }
        let elapsed = Date().timeIntervalSince(start)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(try XCTUnwrap(result.files.first) as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, width)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, height)
        print(String(format: "Preview check timing export 6000x4000 (PNG): %.2f s; %d cores", elapsed, ProcessInfo.processInfo.activeProcessorCount))
    }
}
