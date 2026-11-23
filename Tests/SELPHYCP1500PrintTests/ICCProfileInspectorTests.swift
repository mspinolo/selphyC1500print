import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SELPHYCP1500Print

final class ICCProfileInspectorTests: XCTestCase {
    func testRejectsTooShortFile() throws {
        let url = try temporaryFile(data: Data(repeating: 0, count: 80))
        XCTAssertThrowsError(try ICCProfileInspector.inspect(url: url)) { error in
            guard case ICCProfileInspector.InspectionError.tooShort = error else {
                return XCTFail("Expected tooShort, got \(error)")
            }
        }
    }

    func testRejectsWrongDeclaredSize() throws {
        var data = Self.minimalICCProfile()
        data[3] = data[3] &- 1
        let url = try temporaryFile(data: data)
        XCTAssertThrowsError(try ICCProfileInspector.inspect(url: url)) { error in
            guard case ICCProfileInspector.InspectionError.invalidDeclaredSize = error else {
                return XCTFail("Expected invalidDeclaredSize, got \(error)")
            }
        }
    }

    func testRejectsMissingICCSignature() throws {
        var data = Self.minimalICCProfile()
        data.replaceSubrange(36..<40, with: Data("nope".utf8))
        let url = try temporaryFile(data: data)
        XCTAssertThrowsError(try ICCProfileInspector.inspect(url: url)) { error in
            guard case ICCProfileInspector.InspectionError.missingSignature = error else {
                return XCTFail("Expected missingSignature, got \(error)")
            }
        }
    }

    func testReadsPrinterProfileHeaderAndIntentTags() throws {
        let data = Self.minimalICCProfile(tagSignatures: [
            "A2B0", "B2A0", "A2B1", "B2A1", "A2B2", "B2A2"
        ])
        let url = try temporaryFile(data: data)
        let report = try ICCProfileInspector.inspect(url: url)

        XCTAssertEqual(report.version, "4.3")
        XCTAssertEqual(report.profileClass, "prtr")
        XCTAssertEqual(report.colorSpace, "RGB ")
        XCTAssertEqual(report.connectionSpace, "Lab ")
        XCTAssertEqual(Set(report.availableIntents), Set(RenderingIntent.allCases))
        XCTAssertTrue(report.isExpectedPrinterProfile)
    }

    func testDoesNotAdvertiseIntentWithoutBothTransformDirections() throws {
        let data = Self.minimalICCProfile(tagSignatures: ["A2B0", "B2A0", "A2B1"])
        let url = try temporaryFile(data: data)
        let report = try ICCProfileInspector.inspect(url: url)

        XCTAssertEqual(report.availableIntents, [.perceptual])
    }

    func testRejectsTagOutsideFileBounds() throws {
        var data = Self.minimalICCProfile(tagSignatures: ["A2B0"])
        // First tag entry starts at byte 132; its offset is outside the file.
        data[136] = 0x7f
        data[137] = 0xff
        data[138] = 0xff
        data[139] = 0xff
        let url = try temporaryFile(data: data)
        XCTAssertThrowsError(try ICCProfileInspector.inspect(url: url)) { error in
            guard case ICCProfileInspector.InspectionError.invalidTagTable = error else {
                return XCTFail("Expected invalidTagTable, got \(error)")
            }
        }
    }

    func testRealFarbenwerkProfileWhenPathIsProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["SELPHY_TEST_PRINTER_PROFILE"] else {
            throw XCTSkip("Set SELPHY_TEST_PRINTER_PROFILE to the licensed Farbenwerk ICC file.")
        }
        let report = try ICCProfileInspector.inspect(url: URL(fileURLWithPath: path))
        XCTAssertTrue(report.isExpectedPrinterProfile)
        XCTAssertEqual(Set(report.availableIntents), Set(RenderingIntent.allCases))
    }

    private func temporaryFile(data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SELPHY-ICC-Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("fixture.icc")
        try data.write(to: url)
        return url
    }

    private static func minimalICCProfile(tagSignatures: [String] = []) -> Data {
        let headerSize = 132 + tagSignatures.count * 12
        var data = Data(repeating: 0, count: headerSize)
        func put32(_ value: UInt32, at offset: Int) {
            data[offset] = UInt8((value >> 24) & 0xff)
            data[offset + 1] = UInt8((value >> 16) & 0xff)
            data[offset + 2] = UInt8((value >> 8) & 0xff)
            data[offset + 3] = UInt8(value & 0xff)
        }
        func putSignature(_ value: String, at offset: Int) {
            data.replaceSubrange(offset..<(offset + 4), with: Data(value.utf8))
        }

        put32(UInt32(headerSize), at: 0)
        data[8] = 4
        data[9] = 0x30
        putSignature("prtr", at: 12)
        putSignature("RGB ", at: 16)
        putSignature("Lab ", at: 20)
        putSignature("acsp", at: 36)
        put32(0, at: 64)
        put32(UInt32(tagSignatures.count), at: 128)

        for (index, signature) in tagSignatures.enumerated() {
            let entry = 132 + index * 12
            putSignature(signature, at: entry)
            put32(UInt32(headerSize), at: entry + 4)
            put32(0, at: entry + 8)
        }
        return data
    }
}

final class ColorCorrectionIntegrationTests: XCTestCase {
    func testEndToEndConversionWithRealFarbenwerkProfile() throws {
        guard let profilePath = ProcessInfo.processInfo.environment["SELPHY_TEST_PRINTER_PROFILE"] else {
            throw XCTSkip("Set SELPHY_TEST_PRINTER_PROFILE to run real-profile ColorSync integration tests.")
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
        ))
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
        ))

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
        ))
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
    }

    private func realProfileURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["SELPHY_TEST_PRINTER_PROFILE"] else {
            throw XCTSkip("Set SELPHY_TEST_PRINTER_PROFILE to run real-profile integration tests.")
        }
        return URL(fileURLWithPath: path)
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
