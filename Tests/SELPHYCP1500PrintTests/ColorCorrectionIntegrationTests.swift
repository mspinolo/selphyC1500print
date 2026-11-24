import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SELPHYColorCore
@testable import SELPHYCP1500Print

/// Integration tests for the colour pipeline. The numerical behaviour of the core itself is
/// tested separately and portably in Tests/CoreTests (CMake/ctest, runs on Linux).
final class ColorCorrectionIntegrationTests: XCTestCase {
    func testEndToEndConversionWithRealFarbenwerkProfile() throws {
        guard let profilePath = ProcessInfo.processInfo.environment["SELPHY_TEST_PRINTER_PROFILE"] else {
            throw XCTSkip("Set SELPHY_TEST_PRINTER_PROFILE to run real-profile integration tests.")
        }

        let profileURL = URL(fileURLWithPath: profilePath)
        let sourceURL = try makeRGBJPEG()
        let originalBytes = try Data(contentsOf: sourceURL)

        for intent in RenderingIntent.allCases {
            for bpc in [false, true] {
                let result = try ColorCorrectionService.prepareCopies(
                    from: [sourceURL],
                    printerProfileURL: profileURL,
                    intent: intent,
                    blackPointCompensation: bpc
                )
                defer { try? FileManager.default.removeItem(at: result.folder) }

                XCTAssertEqual(result.files.count, 1)
                let outputURL = try XCTUnwrap(result.files.first)
                XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
                XCTAssertNotEqual(outputURL.standardizedFileURL, sourceURL.standardizedFileURL)
                XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes, "Source JPEG changed for \(intent), BPC=\(bpc)")

                let outputSource = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
                let outputImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(outputSource, 0, nil))
                XCTAssertEqual(outputImage.width, 64)
                XCTAssertEqual(outputImage.height, 48)
                XCTAssertEqual(outputImage.colorSpace?.model, .rgb)
                XCTAssertEqual(outputImage.colorSpace?.name, CGColorSpace.sRGB)
            }
        }
    }

    func testInvalidProfileFailsWithoutChangingSource() throws {
        let invalidProfile = FileManager.default.temporaryDirectory
            .appendingPathComponent("invalid-\(UUID().uuidString).icc")
        try Data("not an ICC profile".utf8).write(to: invalidProfile)
        defer { try? FileManager.default.removeItem(at: invalidProfile) }

        let sourceURL = try makeRGBJPEG()
        let originalBytes = try Data(contentsOf: sourceURL)

        XCTAssertThrowsError(try ColorCorrectionService.prepareCopies(
            from: [sourceURL],
            printerProfileURL: invalidProfile,
            intent: .perceptual,
            blackPointCompensation: false
        )) { error in
            guard case ColorCorrectionService.CorrectionError.profileLoad = error else {
                return XCTFail("Expected profileLoad, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
    }

    func testBatchFailureRemovesPartialSessionAndPreservesInputs() throws {
        let profileURL = try realProfileURL()
        let validURL = try makeRGBJPEG()
        let invalidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-source-\(UUID().uuidString).jpg")
        try Data("not a JPEG".utf8).write(to: invalidURL)
        defer {
            try? FileManager.default.removeItem(at: validURL)
            try? FileManager.default.removeItem(at: invalidURL)
        }

        let validBytes = try Data(contentsOf: validURL)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SELPHYCP1500Print", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))

        XCTAssertThrowsError(try ColorCorrectionService.prepareCopies(
            from: [validURL, invalidURL],
            printerProfileURL: profileURL,
            intent: .perceptual,
            blackPointCompensation: false
        )) { error in
            guard case ColorCorrectionService.CorrectionError.unreadableImage = error else {
                return XCTFail("Expected unreadableImage, got \(error)")
            }
        }

        let after = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        XCTAssertEqual(after, before, "A failed batch must remove its partially generated session")
        XCTAssertEqual(try Data(contentsOf: validURL), validBytes, "A failed batch must not modify any source")
    }

    func testSameBasenameInputsProduceDistinctOutputFiles() throws {
        let profileURL = try realProfileURL()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("SELPHY-Duplicate-Names-\(UUID().uuidString)", isDirectory: true)
        let firstFolder = parent.appendingPathComponent("one", isDirectory: true)
        let secondFolder = parent.appendingPathComponent("two", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let first = try makeRGBJPEG(at: firstFolder.appendingPathComponent("photo.jpg"))
        let second = try makeRGBJPEG(at: secondFolder.appendingPathComponent("photo.jpg"))
        let result = try ColorCorrectionService.prepareCopies(
            from: [first, second],
            printerProfileURL: profileURL,
            intent: .perceptual,
            blackPointCompensation: false
        )
        defer { try? FileManager.default.removeItem(at: result.folder) }

        XCTAssertEqual(result.files.count, 2)
        XCTAssertNotEqual(result.files[0].lastPathComponent, result.files[1].lastPathComponent)
        XCTAssertTrue(result.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testGrayscaleJPEGIsRejectedWithoutChangingSource() throws {
        let profileURL = try realProfileURL()
        let sourceURL = try makeGrayscaleJPEG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let original = try Data(contentsOf: sourceURL)

        XCTAssertThrowsError(try ColorCorrectionService.prepareCopies(
            from: [sourceURL],
            printerProfileURL: profileURL,
            intent: .perceptual,
            blackPointCompensation: false
        )) { error in
            guard case ColorCorrectionService.CorrectionError.unsupportedColorSpace = error else {
                return XCTFail("Expected unsupportedColorSpace, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
    }

    // MARK: - Colour-core integration

    private let neutralPatches = [2, 3, 4, 5, 6, 7]
    private let skinPatches = [16, 17, 18]

    /// Byte offsets of the centre of each chart patch, indexed like the colour table in
    /// `makeColorChartJPEG` (patch = row * 8 + column). CoreGraphics draws with the origin
    /// at the bottom left, so drawn row 0 ends up in the *bottom* image row of the decoded
    /// (top-left origin) pixels.
    private func patchOffsets() -> [Int] {
        (0..<4).flatMap { row in
            (0..<8).map { column in (((3 - row) * 12 + 6) * 64 + (column * 8 + 4)) * 4 }
        }
    }

    private func rgb(at offset: Int, in pixels: [UInt8]) -> [UInt8] {
        [pixels[offset], pixels[offset + 1], pixels[offset + 2]]
    }

    private func predictedLab(printerICC: Data, intent: selphy_intent, rgb8: [UInt8]) -> [Double] {
        let rgb16 = rgb8.map { UInt16($0) * 257 }
        var lab = [Double](repeating: 0, count: rgb8.count)
        let status: selphy_status = printerICC.withUnsafeBytes { raw in
            selphy_printer_predict_lab(
                raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
                intent, rgb16, &lab, rgb8.count / 3
            )
        }
        XCTAssertTrue(status == SELPHY_OK)
        return lab
    }

    private func intendedLab(rgb8: [UInt8]) -> [Double] {
        let rgb16 = rgb8.map { UInt16($0) * 257 }
        var lab = [Double](repeating: 0, count: rgb8.count)
        let status: selphy_status = selphy_source_to_lab(nil, 0, rgb16, &lab, rgb8.count / 3)
        XCTAssertTrue(status == SELPHY_OK)
        return lab
    }

    private func deltaE(_ a: [Double], _ b: [Double], patch: Int) -> Double {
        selphy_delta_e2000(Array(a[patch * 3..<patch * 3 + 3]), Array(b[patch * 3..<patch * 3 + 3]))
    }

    /// The Swift side only repacks buffers around the core. Verify the byte order of the
    /// 16-bit input, the channel order, the padding byte, the stride and the final rounding
    /// against a direct call to the core API.
    func testBufferConversionMatchesDirectCoreCall() throws {
        let printerICC = try Data(contentsOf: try realProfileURL())
        let sourceURL = try makeColorChartJPEG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let source = try rgbaPixels(from: sourceURL)
        let pixelCount = source.width * source.height

        // 16-bit big-endian RGBX, 8 bytes/pixel, values expanded as v * 257.
        var rgbx16 = [UInt8](repeating: 0xFF, count: pixelCount * 8)
        var input16 = [UInt16](repeating: 0, count: pixelCount * 3)
        for pixel in 0..<pixelCount {
            for channel in 0..<3 {
                let value = UInt16(source.pixels[pixel * 4 + channel]) * 257
                rgbx16[pixel * 8 + channel * 2] = UInt8(value >> 8)
                rgbx16[pixel * 8 + channel * 2 + 1] = UInt8(value & 0xFF)
                input16[pixel * 3 + channel] = value
            }
        }

        let transform = try ColorCorrectionService.ColorTransform(
            sourceICC: nil, printerICC: printerICC,
            intent: .relativeColorimetric, blackPointCompensation: false
        )
        let converted = try ColorCorrectionService.convertRGBX16Pixels(
            Data(rgbx16), width: source.width, height: source.height, transform: transform
        )
        XCTAssertEqual(converted.count, pixelCount * 4)

        var options = selphy_options(intent: SELPHY_INTENT_RELATIVE_COLORIMETRIC, black_point_compensation: 0, exact: 0)
        var direct: OpaquePointer?
        let status: selphy_status = printerICC.withUnsafeBytes { raw in
            selphy_transform_create(nil, 0, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &options, &direct)
        }
        XCTAssertTrue(status == SELPHY_OK)
        let handle = try XCTUnwrap(direct)
        defer { selphy_transform_free(handle) }
        var output16 = [UInt16](repeating: 0, count: pixelCount * 3)
        selphy_transform_apply_rgb16(handle, input16, &output16, pixelCount)

        let result = [UInt8](converted)
        var mismatches = 0
        for pixel in 0..<pixelCount {
            for channel in 0..<3 {
                let expected = UInt8((UInt32(output16[pixel * 3 + channel]) * 255 + 32767) / 65535)
                if result[pixel * 4 + channel] != expected { mismatches += 1 }
            }
            if result[pixel * 4 + 3] != 0 { mismatches += 1 }
        }
        XCTAssertEqual(mismatches, 0, "Swift buffer handling differs from the direct core call")
    }

    /// End to end: decode the generated PNG and ask the printer's own forward model what it
    /// would print. Neutral steps and skin tones must land on the intended appearance.
    /// 1.0 dE00 = 0.5 allowed by the core (see core_tests.c) plus 0.5 for rounding to 8 bit
    /// and for the (lossy) source JPEG decode. The output is lossless, so no codec error.
    func testEndToEndOutputMatchesIntendedAppearance() throws {
        let profileURL = try realProfileURL()
        let printerICC = try Data(contentsOf: profileURL)
        let sourceURL = try makeColorChartJPEG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let source = try rgbaPixels(from: sourceURL)

        let result = try ColorCorrectionService.prepareCopies(
            from: [sourceURL], printerProfileURL: profileURL,
            intent: .relativeColorimetric, blackPointCompensation: false
        )
        defer { try? FileManager.default.removeItem(at: result.folder) }
        let output = try rgbaPixels(from: try XCTUnwrap(result.files.first))
        XCTAssertEqual(output.width, source.width)
        XCTAssertEqual(output.height, source.height)

        let offsets = patchOffsets()
        let inputRGB = offsets.flatMap { rgb(at: $0, in: source.pixels) }
        let outputRGB = offsets.flatMap { rgb(at: $0, in: output.pixels) }
        let intended = intendedLab(rgb8: inputRGB)
        let predicted = predictedLab(printerICC: printerICC, intent: SELPHY_INTENT_RELATIVE_COLORIMETRIC, rgb8: outputRGB)
        let baseline = predictedLab(printerICC: printerICC, intent: SELPHY_INTENT_RELATIVE_COLORIMETRIC, rgb8: inputRGB)

        var sumCorrected = 0.0, sumBaseline = 0.0
        for patch in 0..<32 {
            sumCorrected += deltaE(predicted, intended, patch: patch)
            sumBaseline += deltaE(baseline, intended, patch: patch)
        }
        print("End-to-end model check: mean dE00 corrected=\(sumCorrected / 32), uncorrected=\(sumBaseline / 32)")
        for patch in neutralPatches + skinPatches {
            let de = deltaE(predicted, intended, patch: patch)
            print("End-to-end patch \(patch): dE00=\(de)")
            XCTAssertLessThanOrEqual(de, 1.0, "patch \(patch) dE00 \(de)")
        }
        XCTAssertLessThanOrEqual(sumCorrected, 0.5 * sumBaseline, "correction must at least halve the mean model deviation")
    }

    /// An embedded wide-gamut profile must be honoured, not read as sRGB.
    func testEmbeddedAdobeRGBSourceIsHonoured() throws {
        let profileURL = try realProfileURL()
        let adobe = try XCTUnwrap(CGColorSpace(name: CGColorSpace.adobeRGB1998))
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let adobeURL = try makeSolidJPEG(colorSpace: adobe, red: 0.30, green: 0.60, blue: 0.35)
        let srgbURL = try makeSolidJPEG(colorSpace: srgb, red: 0.30, green: 0.60, blue: 0.35)
        defer {
            try? FileManager.default.removeItem(at: adobeURL)
            try? FileManager.default.removeItem(at: srgbURL)
        }
        var centres: [[UInt8]] = []
        for url in [adobeURL, srgbURL] {
            let result = try ColorCorrectionService.prepareCopies(
                from: [url], printerProfileURL: profileURL,
                intent: .relativeColorimetric, blackPointCompensation: false
            )
            defer { try? FileManager.default.removeItem(at: result.folder) }
            let pixels = try rgbaPixels(from: try XCTUnwrap(result.files.first))
            centres.append(rgb(at: ((pixels.height / 2) * pixels.width + pixels.width / 2) * 4, in: pixels.pixels))
        }
        let largestDifference = zip(centres[0], centres[1]).map { abs(Int($0) - Int($1)) }.max() ?? 0
        // Flat patch, q=1.0 JPEG: codec noise is 1-2 levels; a profile that is honoured moves the result far more.
        XCTAssertGreaterThan(largestDifference, 3, "Adobe RGB and sRGB tagged images with equal numbers must convert differently")
    }

    /// BPC reporting: forced for v4 perceptual/saturation, as requested for relative.
    func testEffectiveBlackPointCompensationIsReported() throws {
        let printerICC = try Data(contentsOf: try realProfileURL())
        for intent in RenderingIntent.allCases {
            for requested in [false, true] {
                let transform = try ColorCorrectionService.ColorTransform(
                    sourceICC: nil, printerICC: printerICC, intent: intent, blackPointCompensation: requested
                )
                let expected = intent == .relativeColorimetric ? requested : true
                XCTAssertEqual(transform.effectiveBlackPointCompensation, expected, "\(intent), requested BPC=\(requested)")
            }
        }
    }

    /// Both output formats must be produced, with the right container, size and sRGB tag.
    func testBothOutputFormatsAreProduced() throws {
        let profileURL = try realProfileURL()
        let sourceURL = try makeRGBJPEG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let expectedTypes: [OutputFormat: String] = [.png: "public.png", .jpeg: "public.jpeg"]
        for format in OutputFormat.allCases {
            let result = try ColorCorrectionService.prepareCopies(
                from: [sourceURL], printerProfileURL: profileURL,
                intent: .relativeColorimetric, blackPointCompensation: false,
                outputFormat: format
            )
            defer { try? FileManager.default.removeItem(at: result.folder) }
            let url = try XCTUnwrap(result.files.first)
            XCTAssertEqual(url.pathExtension, format.fileExtension)
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, expectedTypes[format])
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
            XCTAssertEqual(image.width, 64)
            XCTAssertEqual(image.height, 48)
            XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB, "\(format)")
        }
    }

    /// PNG and TIFF sources with identical pixels must convert identically; JPEG XL, when the
    /// system can encode it, must at least be accepted with the right size.
    func testPNGTIFFAndJPEGXLInputsAreAccepted() throws {
        let profileURL = try realProfileURL()
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let pngURL = try makeSolidImageFile(type: .png, colorSpace: srgb, red: 0.55, green: 0.40, blue: 0.30)
        let tiffURL = try makeSolidImageFile(type: .tiff, colorSpace: srgb, red: 0.55, green: 0.40, blue: 0.30)
        defer {
            try? FileManager.default.removeItem(at: pngURL)
            try? FileManager.default.removeItem(at: tiffURL)
        }
        func centre(of url: URL) throws -> [UInt8] {
            let result = try ColorCorrectionService.prepareCopies(
                from: [url], printerProfileURL: profileURL,
                intent: .relativeColorimetric, blackPointCompensation: false
            )
            defer { try? FileManager.default.removeItem(at: result.folder) }
            let pixels = try rgbaPixels(from: try XCTUnwrap(result.files.first))
            return rgb(at: ((pixels.height / 2) * pixels.width + pixels.width / 2) * 4, in: pixels.pixels)
        }
        XCTAssertEqual(try centre(of: pngURL), try centre(of: tiffURL), "PNG and TIFF with equal pixels must convert identically")

        if let jxl = UTType("public.jpeg-xl"),
           (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(jxl.identifier) == true {
            let jxlURL = try makeSolidImageFile(type: jxl, colorSpace: srgb, red: 0.55, green: 0.40, blue: 0.30)
            defer { try? FileManager.default.removeItem(at: jxlURL) }
            let lossyCentre = try centre(of: jxlURL)
            let largestDifference = zip(lossyCentre, try centre(of: pngURL)).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(largestDifference, 3, "JPEG XL flat patch should convert like the lossless source")
        } else {
            print("JPEG XL encoding not available on this system; JXL input not exercised")
        }
    }

    /// Transparent areas are composited on white (the paper), not on black.
    func testTransparentPNGIsCompositedOnWhite() throws {
        let profileURL = try realProfileURL()
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let url = try makeSolidImageFile(type: .png, colorSpace: srgb, red: 0, green: 0, blue: 0, alpha: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try ColorCorrectionService.prepareCopies(
            from: [url], printerProfileURL: profileURL,
            intent: .relativeColorimetric, blackPointCompensation: false
        )
        defer { try? FileManager.default.removeItem(at: result.folder) }
        let pixels = try rgbaPixels(from: try XCTUnwrap(result.files.first))
        let centre = rgb(at: ((pixels.height / 2) * pixels.width + pixels.width / 2) * 4, in: pixels.pixels)
        // White maps to the printer's paper white, which is near 255 in every channel.
        XCTAssertGreaterThanOrEqual(centre.min() ?? 0, 245, "transparent pixels must become white, got \(centre)")
    }

    private func makeSolidImageFile(
        type: UTType, colorSpace: CGColorSpace,
        red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("selphy-solid-\(UUID().uuidString)")
            .appendingPathExtension(type.preferredFilenameExtension ?? "img")
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: 32, height: 32))
        if alpha > 0 {
            context.setFillColor(CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!)
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "cannot write \(type.identifier)")
        return url
    }

    private func makeSolidJPEG(colorSpace: CGColorSpace, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("selphy-solid-\(UUID().uuidString).jpg")
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [red, green, blue, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func realProfileURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["SELPHY_TEST_PRINTER_PROFILE"] else {
            throw XCTSkip("Set SELPHY_TEST_PRINTER_PROFILE to run real-profile integration tests.")
        }
        return URL(fileURLWithPath: path)
    }

    private func rgbaPixels(from url: URL) throws -> (width: Int, height: Int, pixels: [UInt8]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width
        let height = image.height
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
                ).rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(rendered)
        return (width, height, pixels)
    }

    private func makeColorChartJPEG() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("selphy-chart-\(UUID().uuidString).jpg")
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 64,
            height: 48,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (0.00, 0.00, 0.00), (0.10, 0.10, 0.10), (0.25, 0.25, 0.25), (0.50, 0.50, 0.50),
            (0.75, 0.75, 0.75), (0.90, 0.90, 0.90), (1.00, 1.00, 1.00), (0.95, 0.95, 0.90),
            (1.00, 0.00, 0.00), (0.00, 1.00, 0.00), (0.00, 0.00, 1.00), (1.00, 1.00, 0.00),
            (0.00, 1.00, 1.00), (1.00, 0.00, 1.00), (0.85, 0.20, 0.10), (0.10, 0.25, 0.85),
            (0.76, 0.52, 0.38), (0.65, 0.40, 0.30), (0.90, 0.65, 0.50), (0.35, 0.20, 0.15),
            (0.10, 0.35, 0.15), (0.25, 0.55, 0.30), (0.45, 0.65, 0.40), (0.75, 0.85, 0.65),
            (0.10, 0.20, 0.35), (0.25, 0.40, 0.60), (0.45, 0.60, 0.80), (0.70, 0.80, 0.95),
            (0.20, 0.10, 0.25), (0.45, 0.20, 0.50), (0.70, 0.40, 0.75), (0.90, 0.70, 0.85)
        ]

        for row in 0..<4 {
            for column in 0..<8 {
                let color = colors[row * 8 + column]
                context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
                context.fill(CGRect(x: column * 8, y: row * 12, width: 8, height: 12))
            }
        }

        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeRGBJPEG(at destinationURL: URL? = nil) throws -> URL {
        let url = destinationURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("selphy-source-\(UUID().uuidString).jpg")
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 64,
            height: 48,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeGrayscaleJPEG() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("selphy-gray-\(UUID().uuidString).jpg")
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 32,
            height: 24,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
