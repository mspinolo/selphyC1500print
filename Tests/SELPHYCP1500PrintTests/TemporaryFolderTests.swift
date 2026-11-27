import XCTest
@testable import SELPHYCP1500Print

/// The folder chosen for the temporary corrected copies, and the 24-hour clean-up.
final class TemporaryFolderTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selphy-tmpfolder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func age(_ url: URL, hours: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -hours * 3600)], ofItemAtPath: url.path)
    }

    func testSessionsGoToTheChosenFolderInTheirOwnSubfolder() throws {
        let parent = try folder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try ColorCorrectionService.makeSessionFolder(in: parent)
        XCTAssertEqual(session.deletingLastPathComponent().lastPathComponent, ColorCorrectionService.temporarySubfolderName)
        XCTAssertEqual(session.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path, parent.standardizedFileURL.path)
        XCTAssertNotNil(UUID(uuidString: session.lastPathComponent))
        XCTAssertEqual(ColorCorrectionService.sessionRoot(in: nil).deletingLastPathComponent().standardizedFileURL.path,
                       FileManager.default.temporaryDirectory.standardizedFileURL.path)
    }

    /// Only the app's own old session folders go; the user's files and recent sessions stay.
    func testCleanUpRemovesOnlyOldSessionsOfTheApp() throws {
        let parent = try folder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = ColorCorrectionService.sessionRoot(in: parent)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldSession = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recentSession = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let userFolder = root.appendingPathComponent("my prints", isDirectory: true)
        let userFile = root.appendingPathComponent(UUID().uuidString)          // a file, even if UUID-named
        let outside = parent.appendingPathComponent("holiday.jpg")
        for dir in [oldSession, recentSession, userFolder] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        for file in [userFile, outside] { try Data("x".utf8).write(to: file) }
        for item in [oldSession, userFolder, userFile, outside] { try age(item, hours: 48) }
        try age(recentSession, hours: 2)

        _ = try ColorCorrectionService.makeSessionFolder(in: parent)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: oldSession.path), "an abandoned session is removed")
        XCTAssertTrue(fm.fileExists(atPath: recentSession.path))
        XCTAssertTrue(fm.fileExists(atPath: userFolder.path), "a folder not made by the app is kept")
        XCTAssertTrue(fm.fileExists(atPath: userFile.path), "a file is never removed")
        XCTAssertTrue(fm.fileExists(atPath: outside.path), "nothing outside the app's subfolder is touched")
    }

    func testCopiesAreWrittenToTheChosenFolder() throws {
        guard let path = ProcessInfo.processInfo.environment["SELPHY_TEST_PRINTER_PROFILE"] else {
            throw XCTSkip("Set SELPHY_TEST_PRINTER_PROFILE to run real-profile tests.")
        }
        let parent = try folder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let chart = parent.appendingPathComponent("chart.png")
        try ValidationChart.standard.writePNG(to: chart)
        let result = try ColorCorrectionService.prepareCopies(
            from: [chart], printerProfileURL: URL(fileURLWithPath: path), intent: .perceptual,
            blackPointCompensation: false, temporaryParent: parent)
        XCTAssertEqual(result.folder.deletingLastPathComponent().lastPathComponent, ColorCorrectionService.temporarySubfolderName)
        XCTAssertEqual(result.files.count, 1)
        XCTAssertTrue(result.files[0].standardizedFileURL.path.hasPrefix(parent.standardizedFileURL.path))
    }

    @MainActor
    func testTheChoiceIsRememberedAndCanBeUndone() throws {
        let suite = "selphy-tmpfolder-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let chosen = try folder()
        defer { try? FileManager.default.removeItem(at: chosen) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertNil(try settings.temporaryFolder(), "none chosen: the system folder")
        try settings.chooseTemporaryFolder(at: chosen)
        let again = AppSettings(defaults: defaults)
        XCTAssertEqual(try again.temporaryFolder()?.standardizedFileURL.path, chosen.standardizedFileURL.path)
        XCTAssertEqual(again.temporaryFolderDisplayName, chosen.path)
        again.clearTemporaryFolder()
        XCTAssertNil(try AppSettings(defaults: defaults).temporaryFolder())

        // A folder that has disappeared is reported, so the app can fall back to the system one.
        let gone = try folder()
        try settings.chooseTemporaryFolder(at: gone)
        try FileManager.default.removeItem(at: gone)
        XCTAssertThrowsError(try AppSettings(defaults: defaults).temporaryFolder())
    }
}
