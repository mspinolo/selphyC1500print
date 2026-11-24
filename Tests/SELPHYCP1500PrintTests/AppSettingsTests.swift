import XCTest
@testable import SELPHYCP1500Print

@MainActor
final class AppSettingsTests: XCTestCase {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "selphy-tests-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selphy-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func testDefaultsAndOutputFormatPersistence() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.outputFormat, .png, "PNG is the default")
        XCTAssertNil(settings.saveFolderBookmark)
        settings.outputFormat = .jpeg
        settings.renderingIntent = .relativeColorimetric
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.outputFormat, .jpeg)
        XCTAssertEqual(reloaded.renderingIntent, .relativeColorimetric)
    }

    func testSaveFolderIsRememberedAcrossLaunches() throws {
        let (defaults, suite) = try makeDefaults()
        let folder = try makeFolder()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let settings = AppSettings(defaults: defaults)
        try settings.chooseSaveFolder(at: folder)
        XCTAssertEqual(settings.saveFolderDisplayName, folder.lastPathComponent)

        // A new launch (new settings object, same stored defaults) resolves the same folder.
        let reloaded = AppSettings(defaults: defaults)
        let resolved = try XCTUnwrap(try reloaded.resolveSaveFolderURL())
        XCTAssertEqual(resolved.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        XCTAssertEqual(reloaded.saveFolderDisplayName, folder.lastPathComponent)

        // The remembered folder is usable for saving.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("selphy-copy-\(UUID().uuidString).png")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try ExportService.save(copies: [file], to: resolved).count, 1)

        reloaded.clearSaveFolder()
        XCTAssertNil(try reloaded.resolveSaveFolderURL())
        XCTAssertNil(AppSettings(defaults: defaults).saveFolderBookmark)
    }

    func testDeletedSaveFolderReportsAnError() throws {
        let (defaults, suite) = try makeDefaults()
        let folder = try makeFolder()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        try settings.chooseSaveFolder(at: folder)
        try FileManager.default.removeItem(at: folder)
        // A bookmark to a deleted folder either fails to resolve or resolves to a missing folder;
        // saving must then fail cleanly instead of writing somewhere else.
        if let resolved = try? settings.resolveSaveFolderURL() {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("selphy-copy-\(UUID().uuidString).png")
            try Data("x".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            XCTAssertThrowsError(try ExportService.save(copies: [file], to: resolved))
        }
    }
}
