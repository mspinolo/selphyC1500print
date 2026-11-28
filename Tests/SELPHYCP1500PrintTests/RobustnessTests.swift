import Foundation
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
