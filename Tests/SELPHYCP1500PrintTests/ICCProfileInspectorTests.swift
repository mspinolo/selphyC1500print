import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SELPHYICCReference
import ColorSync
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

    func testRejectsTagPayloadOverlappingTagTable() throws {
        var data = Self.minimalICCProfile(tagSignatures: ["A2B0"])
        // Point the tag payload back into its own table entry.
        data[136] = 0
        data[137] = 0
        data[138] = 0
        data[139] = 132
        let url = try temporaryFile(data: data)
        XCTAssertThrowsError(try ICCProfileInspector.inspect(url: url)) { error in
            guard case ICCProfileInspector.InspectionError.invalidTagTable = error else {
                return XCTFail("Expected invalidTagTable, got \(error)")
            }
        }
    }

    func testRejectsEmptyTagPayload() throws {
        var data = Self.minimalICCProfile(tagSignatures: ["A2B0"])
        data[140] = 0
        data[141] = 0
        data[142] = 0
        data[143] = 0
        let url = try temporaryFile(data: data)
        XCTAssertThrowsError(try ICCProfileInspector.inspect(url: url)) { error in
            guard case ICCProfileInspector.InspectionError.invalidTagTable = error else {
                return XCTFail("Expected invalidTagTable, got \(error)")
            }
        }
    }

    func testRejectsUnalignedTagPayloadOffset() throws {
        var data = Self.minimalICCProfile(tagSignatures: ["A2B0"])
        data[139] = data[139] &+ 1
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

        // All fixture tags share one valid 4-byte payload, as ICC permits
        // identical tag data to be referenced by multiple signatures.
        if !tagSignatures.isEmpty {
            data.append(contentsOf: [0, 0, 0, 0])
            put32(UInt32(data.count), at: 0)
        }
        for (index, signature) in tagSignatures.enumerated() {
            let entry = 132 + index * 12
            putSignature(signature, at: entry)
            put32(UInt32(headerSize), at: entry + 4)
            put32(4, at: entry + 8)
        }
        return data
    }
}

final class ColorCorrectionIntegrationTests: XCTestCase {
    func testColorSyncDiagnosticTransforms() throws {
        let profileURL = try realProfileURL()
        let printerProfile = try ColorCorrectionService.loadProfile(at: profileURL)
        guard let unmanagedSRGB = ColorSyncProfileCreateWithName(
            kColorSyncSRGBProfile.takeUnretainedValue()
        ) else {
            return XCTFail("System sRGB ColorSync profile unavailable")
        }
        let sRGBProfile = unmanagedSRGB.takeRetainedValue()
        let report = try ICCProfileInspector.inspect(url: profileURL)
        print("Diagnostic printer ICC header: class=\(report.profileClass), colorSpace=\(report.colorSpace), PCS=\(report.connectionSpace)")

        func convert(
            source: ColorSyncProfile,
            destination: ColorSyncProfile,
            layout: UInt32,
            bytesPerPixel: Int
        ) -> Bool {
            let profileKey = kColorSyncProfile.takeUnretainedValue()
            let intentKey = kColorSyncRenderingIntent.takeUnretainedValue()
            let tagKey = kColorSyncTransformTag.takeUnretainedValue()
            let sourceEntry: [CFString: Any] = [
                profileKey: source,
                intentKey: kColorSyncRenderingIntentPerceptual.takeUnretainedValue(),
                tagKey: kColorSyncTransformDeviceToPCS.takeUnretainedValue()
            ]
            let destinationEntry: [CFString: Any] = [
                profileKey: destination,
                intentKey: kColorSyncRenderingIntentPerceptual.takeUnretainedValue(),
                tagKey: kColorSyncTransformPCSToDevice.takeUnretainedValue()
            ]
            guard let transform = ColorSyncTransformCreate(
                [sourceEntry as CFDictionary, destinationEntry as CFDictionary] as CFArray,
                nil
            )?.takeRetainedValue() else {
                print("Diagnostic transform creation failed")
                return false
            }
            let input = Data([128, 64, 32] + (bytesPerPixel == 4 ? [0] : []))
            var output = Data(count: bytesPerPixel)
            return output.withUnsafeMutableBytes { dst in
                input.withUnsafeBytes { src in
                    ColorSyncTransformConvert(
                        transform, 1, 1,
                        dst.baseAddress, kColorSync8BitInteger, layout, bytesPerPixel,
                        src.baseAddress, kColorSync8BitInteger, layout, bytesPerPixel,
                        nil
                    )
                }
            }
        }

        let rgbxLayout = UInt32(kColorSyncByteOrder32Big) | UInt32(kColorSyncAlphaNoneSkipLast.rawValue)
        let rgbLayout = UInt32(kColorSyncAlphaNone.rawValue)
        let identityRGBX = convert(source: sRGBProfile, destination: sRGBProfile, layout: rgbxLayout, bytesPerPixel: 4)
        let printerRGBX = convert(source: sRGBProfile, destination: printerProfile, layout: rgbxLayout, bytesPerPixel: 4)
        let identityRGB = convert(source: sRGBProfile, destination: sRGBProfile, layout: rgbLayout, bytesPerPixel: 3)
        let printerRGB = convert(source: sRGBProfile, destination: printerProfile, layout: rgbLayout, bytesPerPixel: 3)
        print("ColorSync diagnostic results: sRGB->sRGB RGBX=\(identityRGBX), sRGB->printer RGBX=\(printerRGBX), sRGB->sRGB packed RGB=\(identityRGB), sRGB->printer packed RGB=\(printerRGB)")
        XCTAssertTrue(identityRGB, "Packed RGB identity transform must succeed")
        XCTAssertTrue(printerRGB, "Packed RGB transform to the Farbenwerk profile must succeed")
    }
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

    func testColorSyncMatchesIndependentLittleCMSReference() throws {
        let profileURL = try realProfileURL()
        let sourceURL = try makeColorChartJPEG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let source = try rgbaPixels(from: sourceURL)
        XCTAssertEqual(source.width, 64)
        XCTAssertEqual(source.height, 48)

        let sourceImageSource = try XCTUnwrap(CGImageSourceCreateWithURL(sourceURL as CFURL, nil))
        let sourceImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(sourceImageSource, 0, nil))
        let embeddedSourceICC = sourceImage.colorSpace?.copyICCData()
        let sourceProfile: ColorSyncProfile
        let sourceProfileURL: URL?

        if let embeddedSourceICC {
            guard let unmanaged = ColorSyncProfileCreate(embeddedSourceICC, nil) else {
                return XCTFail("Cannot create ColorSync profile from embedded source ICC")
            }
            sourceProfile = unmanaged.takeRetainedValue()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("selphy-source-profile-\(UUID().uuidString).icc")
            try (embeddedSourceICC as Data).write(to: url)
            sourceProfileURL = url
        } else {
            guard let unmanaged = ColorSyncProfileCreateWithName(
                kColorSyncSRGBProfile.takeUnretainedValue()
            ) else {
                return XCTFail("System sRGB ColorSync profile unavailable")
            }
            sourceProfile = unmanaged.takeRetainedValue()
            sourceProfileURL = nil
        }
        defer {
            if let sourceProfileURL {
                try? FileManager.default.removeItem(at: sourceProfileURL)
            }
        }

        let printerProfile = try ColorCorrectionService.loadProfile(at: profileURL)
        let inputBuffer = Data(source.pixels)

        // Sample the center of each of the 32 color patches to avoid JPEG
        // ringing and chroma-subsampling artifacts at patch boundaries.
        var inputRGB: [UInt8] = []
        let sampleOffsets: [Int] = (0..<4).flatMap { row in
            (0..<8).map { column in
                ((row * 12 + 6) * source.width + (column * 8 + 4)) * 4
            }
        }
        for offset in sampleOffsets {
            inputRGB.append(contentsOf: [
                source.pixels[offset],
                source.pixels[offset + 1],
                source.pixels[offset + 2]
            ])
        }

        for intent in RenderingIntent.allCases {
            for bpc in [false, true] {
                var referenceRGB = [UInt8](repeating: 0, count: inputRGB.count)
                let referenceSucceeded: Int32
                if let sourceProfileURL {
                    referenceSucceeded = sourceProfileURL.path.withCString { sourcePath in
                        profileURL.path.withCString { printerPath in
                            inputRGB.withUnsafeBufferPointer { input in
                                referenceRGB.withUnsafeMutableBufferPointer { output in
                                    selphy_lcms_srgb_to_printer(
                                        sourcePath,
                                        printerPath,
                                        intent.lcmsIntent,
                                        bpc ? 1 : 0,
                                        input.baseAddress,
                                        output.baseAddress,
                                        inputRGB.count / 3
                                    )
                                }
                            }
                        }
                    }
                } else {
                    referenceSucceeded = profileURL.path.withCString { printerPath in
                        inputRGB.withUnsafeBufferPointer { input in
                            referenceRGB.withUnsafeMutableBufferPointer { output in
                                selphy_lcms_srgb_to_printer(
                                    nil,
                                    printerPath,
                                    intent.lcmsIntent,
                                    bpc ? 1 : 0,
                                    input.baseAddress,
                                    output.baseAddress,
                                    inputRGB.count / 3
                                )
                            }
                        }
                    }
                }
                XCTAssertEqual(referenceSucceeded, 1, "LittleCMS reference transform failed for \(intent), BPC=\(bpc)")

                let colorSyncBuffer = try ColorCorrectionService.convertRGBPixels(
                    inputBuffer,
                    width: source.width,
                    height: source.height,
                    sourceProfile: sourceProfile,
                    printerProfile: printerProfile,
                    intent: intent,
                    blackPointCompensation: bpc
                )
                let colorSyncRGBX = [UInt8](colorSyncBuffer)

                var absoluteDifferences: [Int] = []
                for (sampleIndex, offset) in sampleOffsets.enumerated() {
                    for channel in 0..<3 {
                        let actual = Int(colorSyncRGBX[offset + channel])
                        let expected = Int(referenceRGB[sampleIndex * 3 + channel])
                        absoluteDifferences.append(abs(actual - expected))
                    }
                }

                let sortedDifferences = absoluteDifferences.sorted()
                let meanDifference = Double(absoluteDifferences.reduce(0, +)) / Double(absoluteDifferences.count)
                let percentile95 = sortedDifferences[Int(Double(sortedDifferences.count - 1) * 0.95)]
                let maximumDifference = sortedDifferences.last ?? 0
                let worstIndex = absoluteDifferences.firstIndex(of: maximumDifference) ?? 0
                let worstSample = worstIndex / 3
                let worstChannel = worstIndex % 3
                let worstOffset = sampleOffsets[worstSample]
                let worstInput = Array(source.pixels[worstOffset..<(worstOffset + 3)])
                let worstColorSync = colorSyncRGBX[worstOffset + worstChannel]
                let worstLittleCMS = referenceRGB[worstSample * 3 + worstChannel]
                print("ICC numeric comparison: intent=\(intent), BPC=\(bpc), mean=\(meanDifference), p95=\(percentile95), max=\(maximumDifference), worstPatch=\(worstSample), channel=\(worstChannel), input=\(worstInput), ColorSync=\(worstColorSync), LittleCMS=\(worstLittleCMS)")

                XCTAssertLessThanOrEqual(
                    meanDifference,
                    2.0,
                    "ColorSync/LittleCMS mean raw RGB error \(meanDifference) for \(intent), BPC=\(bpc)"
                )
                XCTAssertLessThanOrEqual(
                    percentile95,
                    5,
                    "ColorSync/LittleCMS p95 raw RGB error \(percentile95) for \(intent), BPC=\(bpc)"
                )
                XCTAssertLessThanOrEqual(
                    maximumDifference,
                    10,
                    "ColorSync/LittleCMS maximum raw RGB error \(maximumDifference) for \(intent), BPC=\(bpc)"
                )
            }
        }
    }

    func testColorSyncBPCPlacementDiagnostic() throws {
        let profileURL = try realProfileURL()
        let sourceURL = try makeColorChartJPEG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let source = try rgbaPixels(from: sourceURL)
        let sourceImageSource = try XCTUnwrap(CGImageSourceCreateWithURL(sourceURL as CFURL, nil))
        let sourceImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(sourceImageSource, 0, nil))
        let sourceICC = try XCTUnwrap(sourceImage.colorSpace?.copyICCData())
        let sourceProfile = try XCTUnwrap(ColorSyncProfileCreate(sourceICC, nil)?.takeRetainedValue())
        let sourceProfileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("selphy-bpc-source-\(UUID().uuidString).icc")
        try (sourceICC as Data).write(to: sourceProfileURL)
        defer { try? FileManager.default.removeItem(at: sourceProfileURL) }

        let printerProfile = try ColorCorrectionService.loadProfile(at: profileURL)
        var inputRGB: [UInt8] = []
        let offsets = (0..<4).flatMap { row in
            (0..<8).map { column in ((row * 12 + 6) * source.width + (column * 8 + 4)) * 4 }
        }
        for offset in offsets {
            inputRGB.append(contentsOf: [source.pixels[offset], source.pixels[offset + 1], source.pixels[offset + 2]])
        }

        let profileKey = kColorSyncProfile.takeUnretainedValue()
        let intentKey = kColorSyncRenderingIntent.takeUnretainedValue()
        let tagKey = kColorSyncTransformTag.takeUnretainedValue()
        let bpcKey = kColorSyncBlackPointCompensation.takeUnretainedValue()
        let sourceTag = kColorSyncTransformDeviceToPCS.takeUnretainedValue()
        let destinationTag = kColorSyncTransformPCSToDevice.takeUnretainedValue()

        for intent in [RenderingIntent.relativeColorimetric, .perceptual] {
            var blackPointValues = [Double](repeating: .nan, count: 14)
            let blackPointInspection = sourceProfileURL.path.withCString { sourcePath in
                profileURL.path.withCString { printerPath in
                    blackPointValues.withUnsafeMutableBufferPointer { values in
                        selphy_lcms_inspect_black_points(sourcePath, printerPath, intent.lcmsIntent, values.baseAddress)
                    }
                }
            }
            XCTAssertEqual(blackPointInspection, 1, "LittleCMS black-point estimation failed for intent=\(intent)")
            if blackPointInspection == 1 {
                print(
                    "LCMS black-point diagnostics: intent=\(intent), " +
                    "sourceDetectedXYZ=\(Array(blackPointValues[0...2])), sourceL*=\(blackPointValues[3]), " +
                    "destinationDetectedXYZ=\(Array(blackPointValues[4...6])), destinationL*=\(blackPointValues[7]), " +
                    "sourceMediaBlackPointTagXYZ=\(Array(blackPointValues[8...10])), " +
                    "destinationMediaBlackPointTagXYZ=\(Array(blackPointValues[11...13]))"
                )
            }

            // LittleCMS BPC is indexed by the PCS connection after each
            // profile: BPC[0] is the connection from source profile 0 to
            // destination profile 1. This two-profile chain has no second
            // connection after the final profile, so the destination-entry
            // ColorSync option cannot be represented as another BPC operation.
            var lcmsReferences: [String: [UInt8]] = [:]
            for sourceBPC in [false, true] {
                for destinationBPC in [false, true] {
                    var reference = [UInt8](repeating: 0, count: inputRGB.count)
                    let succeeded = sourceProfileURL.path.withCString { sourcePath in
                        profileURL.path.withCString { printerPath in
                            inputRGB.withUnsafeBufferPointer { input in
                                reference.withUnsafeMutableBufferPointer { output in
                                    selphy_lcms_srgb_to_printer_profile_bpc(
                                        sourcePath,
                                        printerPath,
                                        intent.lcmsIntent,
                                        sourceBPC ? 1 : 0,
                                        destinationBPC ? 1 : 0,
                                        input.baseAddress,
                                        output.baseAddress,
                                        inputRGB.count / 3
                                    )
                                }
                            }
                        }
                    }
                    XCTAssertEqual(
                        succeeded, 1,
                        "LittleCMS per-profile reference failed for \(intent), source BPC=\(sourceBPC), destination BPC=\(destinationBPC)"
                    )
                    lcmsReferences["\(sourceBPC)-\(destinationBPC)"] = reference
                }
            }

            for placement in ["none", "source", "destination", "both"] {
                let sourceBPC = placement == "source" || placement == "both"
                let destinationBPC = placement == "destination" || placement == "both"
                let sourceEntry: [CFString: Any] = [
                    profileKey: sourceProfile,
                    intentKey: intent.colorSyncValueForTests,
                    tagKey: sourceTag,
                    bpcKey: sourceBPC
                ]
                let destinationEntry: [CFString: Any] = [
                    profileKey: printerProfile,
                    intentKey: intent.colorSyncValueForTests,
                    tagKey: destinationTag,
                    bpcKey: destinationBPC
                ]
                let sequence = [sourceEntry as CFDictionary, destinationEntry as CFDictionary] as CFArray
                let transform = try XCTUnwrap(ColorSyncTransformCreate(sequence, nil)?.takeRetainedValue())

                var output = [UInt8](repeating: 0, count: inputRGB.count)
                let converted = output.withUnsafeMutableBytes { destination in
                    inputRGB.withUnsafeBytes { sourceBytes in
                        ColorSyncTransformConvert(
                            transform, inputRGB.count / 3, 1,
                            destination.baseAddress, kColorSync8BitInteger,
                            UInt32(kColorSyncAlphaNone.rawValue), inputRGB.count,
                            sourceBytes.baseAddress, kColorSync8BitInteger,
                            UInt32(kColorSyncAlphaNone.rawValue), inputRGB.count, nil
                        )
                    }
                }
                XCTAssertTrue(converted, "ColorSync conversion failed for \(intent), BPC placement=\(placement)")
                guard converted else { continue }

                func differenceSummary(against reference: [UInt8]) -> String {
                    let differences = zip(output, reference).map { abs(Int($0) - Int($1)) }
                    let sorted = differences.sorted()
                    let mean = Double(differences.reduce(0, +)) / Double(max(differences.count, 1))
                    let p95 = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]
                    let maximum = sorted.last ?? 0
                    return "mean=\(String(format: "%.3f", mean)), p95=\(p95), max=\(maximum)"
                }

                let matchingKey = "\(sourceBPC)-\(destinationBPC)"
                let matchingReference = try XCTUnwrap(lcmsReferences[matchingKey])
                let allReferenceComparisons = lcmsReferences
                    .map { key, reference in "\(key): {\(differenceSummary(against: reference))}" }
                    .sorted()
                    .joined(separator: "; ")
                print(
                    "BPC semantic comparison: intent=\(intent), placement=\(placement), " +
                    "matching-LCMS-connection-BPC {\(differenceSummary(against: matchingReference))}, " +
                    "all-LCMS-references=[\(allReferenceComparisons)], " +
                    "sample=\(Array(output.prefix(12)))"
                )

                // LUT-based printer transforms need not expose a parametric
                // fragment. Inspect full/simplified data and transform metadata too.
                let propertyRequests: [(String, CFString)] = [
                    ("parametric", kColorSyncTransformParametricConversionData.takeUnretainedValue()),
                    ("full", kColorSyncTransformFullConversionData.takeUnretainedValue()),
                    ("simplified", kColorSyncTransformSimplifiedConversionData.takeUnretainedValue()),
                    ("info", kColorSyncTransformInfo.takeUnretainedValue())
                ]
                for (name, key) in propertyRequests {
                    guard let value = ColorSyncTransformCopyProperty(
                        transform, key, nil
                    )?.takeRetainedValue() else {
                        print("ColorSync transform property unavailable: name=\(name), intent=\(intent), placement=\(placement)")
                        continue
                    }

                    let typeID = CFGetTypeID(value)
                    var detail = "typeID=\(typeID)"
                    if typeID == CFDataGetTypeID() {
                        detail += ", dataBytes=\(CFDataGetLength(value as! CFData))"
                    } else if typeID == CFArrayGetTypeID() {
                        detail += ", arrayCount=\(CFArrayGetCount(value as! CFArray))"
                    } else if typeID == CFDictionaryGetTypeID() {
                        detail += ", dictionaryCount=\(CFDictionaryGetCount(value as! CFDictionary))"
                    }
                    if name == "parametric",
                       let dictionary = value as? [CFString: Any] {
                        let bpcComponentKey = kColorSyncConversionBPC.takeUnretainedValue()
                        detail += ", BPCComponent=\(String(describing: dictionary[bpcComponentKey]))"
                    }
                    if name == "full", let components = value as? [Any] {
                        let bpcComponentKey = kColorSyncConversionBPC.takeUnretainedValue()
                        let summaries = components.enumerated().map { index, component -> String in
                            if let dictionary = component as? [CFString: Any] {
                                let keys = dictionary.keys.map { String(describing: $0) }.sorted()
                                let bpcObject = dictionary[bpcComponentKey]
                                let bpc = String(describing: bpcObject ?? "nil")
                                let bpcNumbers = (bpcObject as? [NSNumber])?.map { $0.doubleValue }
                                return "\(index):dict(keys=\(keys),BPC=\(bpc),BPCFloatValues=\(String(describing: bpcNumbers)))"
                            }
                            if let data = component as? Data {
                                return "\(index):data(bytes=\(data.count))"
                            }
                            return "\(index):\(type(of: component))"
                        }
                        detail += ", components=[\(summaries.joined(separator: "; "))]"
                    }
                    print("ColorSync transform property: name=\(name), intent=\(intent), placement=\(placement), \(detail)")
                }

                let creatorKey = kColorSyncTransformCreator.takeUnretainedValue()
                if let creator = ColorSyncTransformCopyProperty(
                    transform, creatorKey, nil
                )?.takeRetainedValue() {
                    print("ColorSync CMM: \(creator)")
                }
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

private extension RenderingIntent {
    var colorSyncValueForTests: CFString {
        switch self {
        case .perceptual:
            kColorSyncRenderingIntentPerceptual.takeUnretainedValue()
        case .relativeColorimetric:
            kColorSyncRenderingIntentRelative.takeUnretainedValue()
        case .saturation:
            kColorSyncRenderingIntentSaturation.takeUnretainedValue()
        }
    }

    var lcmsIntent: UInt32 {
        switch self {
        case .perceptual: 0
        case .relativeColorimetric: 1
        case .saturation: 2
        }
    }
}
