import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import SELPHYCP1500Print

/// The validation session survives what can happen to its file between the two sessions of the
/// physical test (an unreadable file, a file from an older version, a failed save), and the
/// files it refers to stay reachable when they are moved.
@MainActor
final class SessionStorageTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selphy-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func settings() throws -> AppSettings {
        let suite = "selphy-session-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    private func files(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func testAnUnreadableSessionIsKeptAsideAndReported() throws {
        let folder = try folder()
        let store = folder.appendingPathComponent("validation-session.json")
        let garbage = Data("{ not a session".utf8)
        try garbage.write(to: store)

        let model = ValidationModel(settings: try settings(), storeURL: store)
        XCTAssertEqual(model.data.mode, ValidationSessionData().mode, "a new session")
        let warning = try XCTUnwrap(model.storageWarning)
        let kept = try XCTUnwrap(try files(in: folder).first { $0.hasPrefix("validation-session-unreadable-") })
        XCTAssertTrue(warning.contains(kept), warning)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(kept)), garbage, "kept untouched")

        // Working on the new session saves it without touching the copy.
        model.data.mode = .visual
        XCTAssertEqual(ValidationModel(settings: try settings(), storeURL: store).data.mode, .visual)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(kept)), garbage)
        XCTAssertNotNil(model.storageWarning, "the warning stays until a new session is started")
        model.reset()
        XCTAssertNil(model.storageWarning)
    }

    func testASessionFromAFutureVersionIsNotOverwritten() throws {
        let folder = try folder()
        let store = folder.appendingPathComponent("validation-session.json")
        // A mode this version does not know: unreadable here, but it must survive.
        let future = Data(#"{"mode":"spectrophotometer","record":"keep me"}"#.utf8)
        try future.write(to: store)
        let model = ValidationModel(settings: try settings(), storeURL: store)
        XCTAssertNotNil(model.storageWarning)
        model.data.record = "new"
        let kept = try XCTUnwrap(try files(in: folder).first { $0.contains("unreadable") })
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(kept)), future)
    }

    func testASessionWrittenByAnOlderVersionLoadsWithItsValues() throws {
        var data = ValidationSessionData()
        data.mode = .visual
        data.record = "printed on Tuesday"
        data.checklist = ["fresh cartridge": true]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(data)) as? [String: Any])
        // An older version did not have these fields.
        for key in ["visual", "corners", "printerProfileDigest", "scans", "importedReference"] { object.removeValue(forKey: key) }
        let older = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ValidationSessionData.self, from: older)
        XCTAssertEqual(decoded.mode, .visual)
        XCTAssertEqual(decoded.record, "printed on Tuesday")
        XCTAssertEqual(decoded.checklist, ["fresh cartridge": true])
        XCTAssertEqual(decoded.scans, [:])
        XCTAssertEqual(decoded.visual, [])

        let folder = try folder()
        let store = folder.appendingPathComponent("validation-session.json")
        try older.write(to: store)
        let model = ValidationModel(settings: try settings(), storeURL: store)
        XCTAssertNil(model.storageWarning)
        XCTAssertEqual(model.data.record, "printed on Tuesday")
        XCTAssertEqual(model.data.visual.count, PhotoRole.allCases.count, "missing parts get their defaults")
        // Every field still round-trips.
        XCTAssertEqual(try JSONDecoder().decode(ValidationSessionData.self, from: JSONEncoder().encode(model.data)), model.data)
    }

    func testAFailedSaveIsReportedAndClearedOnceSavingWorksAgain() throws {
        let folder = try folder()
        let missing = folder.appendingPathComponent("not-yet", isDirectory: true)
        let store = missing.appendingPathComponent("validation-session.json")
        let model = ValidationModel(settings: try settings(), storeURL: store)
        model.data.record = "first"
        XCTAssertNotNil(model.storageWarning, "the folder does not exist: the save fails")

        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        model.data.record = "second"
        XCTAssertNil(model.storageWarning)
        XCTAssertEqual(ValidationModel(settings: try settings(), storeURL: store).data.record, "second")
    }

    func testBookmarksOfMovedFilesAreRenewed() throws {
        let folder = try folder()
        let original = folder.appendingPathComponent("scan.tif")
        try Data("scan".utf8).write(to: original)
        let bookmark = try Bookmarks.make(original)
        XCTAssertNil(Bookmarks.renewed(bookmark), "a current bookmark is left alone")

        let moved = folder.appendingPathComponent("scan renamed.tif")
        try FileManager.default.moveItem(at: original, to: moved)
        var stale = false
        let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        XCTAssertEqual(resolved.standardizedFileURL.path, moved.standardizedFileURL.path, "the system finds the moved file")
        guard stale else { return }   // the system decides when a bookmark is stale

        let renewed = try XCTUnwrap(Bookmarks.renewed(bookmark))
        var stillStale = true
        let again = try URL(resolvingBookmarkData: renewed, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stillStale)
        XCTAssertFalse(stillStale)
        XCTAssertEqual(again.standardizedFileURL.path, moved.standardizedFileURL.path)

        var session = ValidationSessionData()
        session.scans["A1"] = ScanEntry(name: "scan.tif", bookmark: bookmark)
        session.colorCheckerScanBookmark = bookmark
        XCTAssertTrue(session.renewStaleBookmarks())
        XCTAssertNotEqual(session.scans["A1"]?.bookmark, bookmark)
        XCTAssertNotEqual(session.colorCheckerScanBookmark, bookmark)
        XCTAssertFalse(session.renewStaleBookmarks(), "nothing left to renew")
    }

    func testScopedAccessReturnsAndRethrows() throws {
        let url = FileManager.default.temporaryDirectory
        XCTAssertEqual(url.withSecurityScope { $0 }, url)
        struct Failure: Error {}
        XCTAssertThrowsError(try url.withSecurityScope { _ in throw Failure() })
    }
}

/// The sRGB copy of a photo with its own profile (the "uncorrected" layers) is made from the
/// pixels already decoded, in parallel strips, and matches decoding the file again into sRGB.
final class SRGBConversionTests: XCTestCase {
    private func writeP3Photo(width: Int, height: Int) throws -> URL {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Saturated ramps (outside sRGB too), neutrals and a hard edge across strip boundaries.
        for x in 0..<width {
            let t = CGFloat(x) / CGFloat(width - 1)
            context.setFillColor(CGColor(colorSpace: space, components: [t, 1 - t, 0.3 + 0.7 * t * t, 1])!)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height / 2))
            context.setFillColor(CGColor(colorSpace: space, components: [t, t, t, 1])!)
            context.fill(CGRect(x: x, y: height / 2, width: 1, height: height - height / 2))
        }
        context.setFillColor(CGColor(colorSpace: space, components: [0, 0.9, 0.1, 1])!)
        context.fill(CGRect(x: width / 3, y: height / 4, width: width / 3, height: height / 2))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selphy-p3-\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func eightBit(_ loaded: ColorCorrectionService.LoadedSource) throws -> [UInt8] {
        [UInt8](try ColorCorrectionService.convertRGBX16Pixels(
            loaded.pixels, width: loaded.width, height: loaded.height, transform: nil, orientation: loaded.orientation))
    }

    func testTheInMemoryConversionMatchesDecodingAgainIntoSRGB() throws {
        let url = try writeP3Photo(width: 997, height: 613)
        let loaded = try ColorCorrectionService.loadSource(from: url)
        XCTAssertNotNil(loaded.embeddedICC, "the test photo carries Display P3")
        let converted = try ColorCorrectionService.convertedToSRGB(loaded)
        XCTAssertNil(converted.embeddedICC)
        XCTAssertEqual(converted.interpretation, .convertedToSRGB)
        let reference = try eightBit(ColorCorrectionService.loadSource(from: url, forceSRGB: true))
        let fast = try eightBit(converted)
        XCTAssertEqual(reference.count, fast.count)
        var maximum = 0, differing = 0
        for index in reference.indices where index % 4 != 3 {
            let delta = abs(Int(reference[index]) - Int(fast[index]))
            maximum = max(maximum, delta)
            if delta > 0 { differing += 1 }
        }
        XCTAssertLessThanOrEqual(maximum, 1, "same ColorSync conversion, at most a rounding step apart")
        XCTAssertLessThan(Double(differing) / Double(reference.count * 3 / 4), 0.01)
        print("Preview check sRGB copy: max difference \(maximum), \(differing) of \(reference.count * 3 / 4) channels differ")
    }

    func testTheStripsDoNotChangeTheResult() throws {
        let url = try writeP3Photo(width: 640, height: 481)
        let loaded = try ColorCorrectionService.loadSource(from: url)
        let whole = try ColorCorrectionService.convertedToSRGB(loaded, strips: 1).pixels
        for strips in [2, 7, 481, 2000] {
            XCTAssertEqual(try ColorCorrectionService.convertedToSRGB(loaded, strips: strips).pixels, whole, "\(strips) strips")
        }
    }

    func testAPhotoWithoutProfileIsLeftAsItIs() throws {
        let loaded = ColorCorrectionService.LoadedSource(
            pixels: Data(repeating: 7, count: 8 * 8 * 8), width: 8, height: 8, orientation: 1, embeddedICC: nil,
            interpretation: .assumedSRGB, dpi: nil, profileName: nil, colorModel: nil)
        XCTAssertEqual(try ColorCorrectionService.convertedToSRGB(loaded).pixels, loaded.pixels)
    }
}
