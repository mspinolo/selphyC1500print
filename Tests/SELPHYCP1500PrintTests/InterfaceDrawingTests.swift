import AppKit
import SwiftUI
import XCTest
@testable import SELPHYCP1500Print

/// The windows, checked by what they draw: each one is opened in a real window, something is
/// changed the way the rest of the app changes it (Settings, another window, the model), and the
/// drawing must change accordingly and come back when the change is undone. These need no
/// accessibility permission, so they always run; `InterfaceTests` adds the control-by-control
/// checks where the accessibility tree is available.
@MainActor
final class InterfaceDrawingTests: XCTestCase {
    private func reference(_ window: HostedView, settle: TimeInterval = 1.5) throws -> NSBitmapImageRep {
        window.pump(settle)
        return try XCTUnwrap(window.image())
    }

    func testTheOpenWindowsFollowTheLanguage() throws {
        let settings = try interfaceSettings(profile: true)
        let windows: [(String, HostedView)] = [
            ("main", HostedView(ContentView().environment(settings).environment(PhotoSelection()))),
            ("settings", HostedView(SettingsView().environment(settings), size: CGSize(width: 540, height: 680))),
            ("assistant", HostedView(ValidationAssistantView(model: ValidationModel(settings: settings, storeURL: nil)).environment(settings),
                                     size: CGSize(width: 1040, height: 760))),
        ]
        defer { windows.forEach { $0.1.close() } }
        let english = try windows.map { try reference($0.1) }
        settings.language = .italian
        for (index, (name, window)) in windows.enumerated() {
            let difference = window.waitForDrawing(comparedWith: english[index], changed: true)
            XCTAssertGreaterThan(difference, 0.002, "\(name): the window did not change language")
        }
        settings.language = .english
        for (index, (name, window)) in windows.enumerated() {
            let difference = window.waitForDrawing(comparedWith: english[index], changed: false)
            XCTAssertLessThanOrEqual(difference, 0.002, "\(name): the window did not come back to English")
        }
    }

    func testChoosingAndRemovingTheProfileUpdatesTheMainWindowAndTheAssistant() throws {
        let settings = try interfaceSettings(profile: false)
        let main = HostedView(ContentView().environment(settings).environment(PhotoSelection()))
        let assistant = HostedView(ValidationAssistantView(model: ValidationModel(settings: settings, storeURL: nil)).environment(settings),
                                   size: CGSize(width: 1040, height: 760))
        defer {
            main.close()
            assistant.close()
        }
        let mainBefore = try reference(main)
        let assistantBefore = try reference(assistant)
        try settings.chooseProfile(at: try interfaceProfileURL())
        XCTAssertGreaterThan(main.waitForDrawing(comparedWith: mainBefore, changed: true), 0.002, "the profile warning stayed")
        XCTAssertGreaterThan(assistant.waitForDrawing(comparedWith: assistantBefore, changed: true), 0.002)
        settings.clearProfile()
        XCTAssertLessThanOrEqual(main.waitForDrawing(comparedWith: mainBefore, changed: false), 0.002, "the warning did not come back")
        XCTAssertLessThanOrEqual(assistant.waitForDrawing(comparedWith: assistantBefore, changed: false), 0.002)
    }

    func testTheThemeRepaintsTheMainWindowWithTheDarktableGrey() throws {
        let settings = try interfaceSettings(profile: true)
        let photos = try interfacePhotos(1)
        let window = HostedView(ContentView(initialPhotos: photos).environment(settings).environment(PhotoSelection()))
        defer { window.close() }
        let system = try reference(window, settle: 4)
        settings.theme = .neutralGrey
        XCTAssertGreaterThan(window.waitForDrawing(comparedWith: system, changed: true, threshold: 0.2), 0.2,
                             "most of the window should turn grey")
        settings.theme = .system
        XCTAssertLessThanOrEqual(window.waitForDrawing(comparedWith: system, changed: false, threshold: 0.01), 0.01)
    }

    func testPreviewOptionsChangedInTheSettingsRedrawThePreview() throws {
        let settings = try interfaceSettings(profile: true)
        let photos = try interfacePhotos(1)
        let window = HostedView(ContentView(initialPhotos: photos).environment(settings).environment(PhotoSelection()))
        defer { window.close() }
        let before = try reference(window, settle: 6)
        // The same options as in the preview's menu, changed from elsewhere (Settings, full screen).
        settings.simulatePaperWhite = true
        XCTAssertGreaterThan(window.waitForDrawing(comparedWith: before, changed: true, timeout: 15), 0.002,
                             "the preview did not follow 'Simulate paper white'")
        settings.simulatePaperWhite = false
        XCTAssertLessThanOrEqual(window.waitForDrawing(comparedWith: before, changed: false, timeout: 15), 0.002)
    }

    func testTheFullScreenIndicationsFollowTheModelAndTheSettings() throws {
        let settings = try interfaceSettings(profile: true)
        let photos = try interfacePhotos(2)
        let model = FullScreenModel(photos: photos, current: photos[0], settings: settings, selection: nil)
        model.autoHidesHUD = false
        model.backingScale = 1
        model.start()
        let window = HostedView(FullScreenView(model: model).environment(settings), size: CGSize(width: 1280, height: 800))
        defer { window.close() }
        let compare = try reference(window, settle: 6)

        model.handle(.mode(.original))
        XCTAssertGreaterThan(window.waitForDrawing(comparedWith: compare, changed: true, timeout: 10), 0.002)
        model.handle(.mode(.compare))
        XCTAssertLessThanOrEqual(window.waitForDrawing(comparedWith: compare, changed: false, timeout: 10), 0.002)

        settings.renderingIntent = .saturation      // shown in the status line, owned by AppSettings
        XCTAssertGreaterThan(window.waitForDrawing(comparedWith: compare, changed: true, timeout: 10), 0.0005)
        settings.renderingIntent = .perceptual

        model.handle(.toggleHUD)
        XCTAssertGreaterThan(window.waitForDrawing(comparedWith: compare, changed: true, timeout: 10), 0.002, "the indications stayed")
    }

    func testTheStatisticsWindowFillsInAndFollowsTheSelection() throws {
        let settings = try interfaceSettings(profile: true)
        let photos = try interfacePhotos(3)
        let selection = PhotoSelection()
        let window = HostedView(StatisticsView().environment(settings).environment(selection), size: CGSize(width: 920, height: 760))
        defer { window.close() }
        let empty = try reference(window)
        selection.photos = photos
        selection.selected = photos[0]
        XCTAssertGreaterThan(window.waitForDrawing(comparedWith: empty, changed: true, threshold: 0.02, timeout: 30), 0.02,
                             "the photos did not appear")
        window.pump(8)
        let first = try XCTUnwrap(window.image())
        selection.selected = photos[2]
        XCTAssertGreaterThan(window.waitForDrawing(comparedWith: first, changed: true, timeout: 20), 0.002,
                             "the statistics did not follow the photo selected elsewhere")
    }
}
