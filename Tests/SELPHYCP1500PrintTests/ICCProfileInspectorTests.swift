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
