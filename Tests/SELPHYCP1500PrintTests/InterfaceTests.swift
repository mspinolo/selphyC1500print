import AppKit
import ApplicationServices
import Observation
import SwiftUI
import XCTest
@testable import SELPHYCP1500Print

/// A SwiftUI view hosted in a real, off-screen window, read and driven through its accessibility
/// tree (what VoiceOver and UI tests see), with the AppKit controls underneath as a fallback for
/// menus and switches. The run loop is pumped between steps so that SwiftUI applies its updates.
@MainActor
final class HostedView {
    struct Node {
        let object: NSObject
        let role: String
        /// Label, title, value and help; for a control without its own label, also the text just
        /// before it (a Form row: "Language" [English ▾], "Show the notice…" [switch]).
        let texts: [String]
        let enabled: Bool
        let depth: Int
        /// The current value of a pop-up menu or switch.
        let value: String?

        func matches(_ text: String) -> Bool { texts.contains(text) }
        func mentions(_ text: String) -> Bool { texts.contains { $0.contains(text) } }
    }

    let window: NSWindow
    let host: NSView

    init<V: View>(_ view: V, size: CGSize = CGSize(width: 980, height: 680)) {
        Self.prepareApplication()
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        self.window = window
        self.host = host
        pump(0.5)
    }

    func close() { window.close() }

    /// Whether SwiftUI exposes its accessibility tree in this process (it does not when no
    /// assistive client has asked for it, as on a CI runner without accessibility permission).
    static var accessibilityAvailable: Bool {
        if let cachedAvailability { return cachedAvailability }
        let probe = HostedView(Button("Accessibility probe") {}.padding(), size: CGSize(width: 300, height: 120))
        defer { probe.close() }
        var available = probe.waitUntil(timeout: 1) { probe.control("Accessibility probe") != nil }
        if !available {
            clientStatus = AccessibilityClient.connect(pumping: probe)
            available = probe.waitUntil(timeout: 3) { probe.control("Accessibility probe") != nil }
        }
        print("Interface probe: client \(clientStatus) available=\(available)")
        cachedAvailability = available
        return available
    }

    private static var cachedAvailability: Bool?
    static var clientStatus = "not needed"
    private static var launched = false

    /// A test process creates NSApplication but never finishes launching it, so the app has no
    /// accessibility service; finishing the launch once gives it one, as in the real app.
    static func prepareApplication() {
        _ = NSApplication.shared
        guard !launched else { return }
        launched = true
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
    }

    /// The window as drawn (what a person sees), for comparisons before and after a change.
    func image() -> NSBitmapImageRep? {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Share of pixels that differ visibly between two drawings of the same window.
    static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
              let pa = a.bitmapData, let pb = b.bitmapData else { return 1 }
        var differing = 0
        let step = 2
        var total = 0
        for y in stride(from: 0, to: a.pixelsHigh, by: step) {
            for x in stride(from: 0, to: a.pixelsWide, by: step) {
                total += 1
                let ia = y * a.bytesPerRow + x * a.bitsPerPixel / 8
                let ib = y * b.bytesPerRow + x * b.bitsPerPixel / 8
                var delta = 0
                for c in 0..<3 { delta = max(delta, abs(Int(pa[ia + c]) - Int(pb[ib + c]))) }
                if delta > 24 { differing += 1 }
            }
        }
        return Double(differing) / Double(max(1, total))
    }

    /// Waits until the drawing differs from `reference` by more than `threshold` (or, with
    /// `same`, until it matches it again); returns the last difference.
    @discardableResult
    func waitForDrawing(comparedWith reference: NSBitmapImageRep, changed: Bool, threshold: Double = 0.002,
                        timeout: TimeInterval = 5) -> Double {
        var last = changed ? 0 : 1.0
        _ = waitUntil(timeout: timeout) {
            guard let now = image() else { return false }
            last = Self.difference(reference, now)
            return changed ? last > threshold : last <= threshold
        }
        return last
    }

    func pump(_ seconds: TimeInterval = 0.2) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < end
    }

    /// Pumps the run loop until `condition` holds or the time runs out; returns whether it held.
    @discardableResult
    func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump(0.1)
        }
        return condition()
    }

    // MARK: Accessibility tree

    private static func string(_ object: NSObject, _ key: String) -> String? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        let value = object.value(forKey: key)
        if let text = value as? String { return text }
        if let text = value as? NSAttributedString { return text.string }
        return nil
    }

    private static func children(of object: NSObject) -> [NSObject] {
        guard object.responds(to: NSSelectorFromString("accessibilityChildren")) else { return [] }
        return (object.value(forKey: "accessibilityChildren") as? [Any] ?? []).compactMap { $0 as? NSObject }
    }

    func nodes() -> [Node] {
        var result: [Node] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject, depth: Int, precedingText: String?) {
            guard depth < 60, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let role = Self.string(object, "accessibilityRole") ?? ""
            var texts: [String] = []
            for key in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityHelp"] {
                if let text = Self.string(object, key), !text.isEmpty { texts.append(text) }
            }
            var value: String?
            if object.responds(to: NSSelectorFromString("accessibilityValue")) {
                let raw = object.value(forKey: "accessibilityValue")
                value = (raw as? String) ?? (raw as? NSNumber).map { $0.stringValue }
            }
            if Self.controlRoles.contains(role), let precedingText, !texts.contains(precedingText) {
                texts.append(precedingText)
            }
            if let control = object as? NSButton, !control.title.isEmpty { texts.append(control.title) }
            if let field = object as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
            var enabled = true
            if object.responds(to: NSSelectorFromString("isAccessibilityEnabled")) {
                enabled = (object.value(forKey: "accessibilityEnabled") as? Bool) ?? true
            }
            if let control = object as? NSControl { enabled = enabled && control.isEnabled }
            result.append(Node(object: object, role: role, texts: texts, enabled: enabled, depth: depth, value: value))
            var text: String?
            for child in Self.children(of: object) + ((object as? NSView)?.subviews ?? []).map({ $0 as NSObject }) {
                visit(child, depth: depth + 1, precedingText: text)
                // The label of the next control: the last static text seen among the siblings.
                if Self.string(child, "accessibilityRole") == NSAccessibility.Role.staticText.rawValue {
                    text = Self.string(child, "accessibilityValue") ?? Self.string(child, "accessibilityLabel")
                } else if Self.controlRoles.contains(Self.string(child, "accessibilityRole") ?? "") {
                    text = nil
                }
            }
        }
        visit(host, depth: 0, precedingText: nil)
        return result
    }

    /// Everything readable in the window: labels, titles, values and help texts.
    func texts() -> [String] { nodes().flatMap(\.texts) }

    func shows(_ text: String) -> Bool { nodes().contains { $0.mentions(text) } }

    private static let controlRoles: Set<String> = [
        NSAccessibility.Role.button.rawValue, NSAccessibility.Role.checkBox.rawValue,
        NSAccessibility.Role.radioButton.rawValue, NSAccessibility.Role.popUpButton.rawValue,
        NSAccessibility.Role.menuButton.rawValue, "AXSwitch", NSAccessibility.Role.link.rawValue
    ]

    /// The control (button, switch, checkbox, link...) labelled exactly `label`.
    func control(_ label: String) -> Node? {
        nodes().first { Self.controlRoles.contains($0.role) && $0.matches(label) }
            ?? nodes().first { $0.object is NSControl && $0.matches(label) }
    }

    /// Clicks the control labelled `label`, as a user would.
    func press(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let node = control(label) else {
            XCTFail("No control labelled “\(label)”. Tree:\n\(dump())", file: file, line: line)
            return
        }
        XCTAssertTrue(node.enabled, "“\(label)” is disabled", file: file, line: line)
        if let button = node.object as? NSButton {
            button.performClick(nil)
        } else {
            // SwiftUI switches act on the press but report it as not handled: the tests check
            // the effect instead of this result.
            _ = (node.object as AnyObject).accessibilityPerformPress?()
        }
        pump(0.3)
    }

    /// The pop-up menus (menu-style pickers) of the window.
    func popUpMenus() -> [Node] { nodes().filter { $0.role == NSAccessibility.Role.popUpButton.rawValue } }

    /// The value shown by the pop-up menu labelled `label` (its selected item).
    func value(of label: String) -> String? {
        popUpMenus().first { $0.matches(label) }?.value
            ?? nodes().first { Self.controlRoles.contains($0.role) && $0.matches(label) }?.value
    }

    private final class MenuPick: @unchecked Sendable {
        var opened = false
        var picked = false
        var offered: [String] = []
    }

    /// Opens a pop-up menu as a person does (press) and, in the menu that appears, picks `item`;
    /// closes the menu without choosing if it does not offer it. Returns whether it was picked.
    private func pick(_ item: String, in popUp: Node) -> Bool {
        let state = MenuPick()
        let observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { note in
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated {
                guard let menu, !state.opened else { return }
                state.opened = true
                state.offered = menu.items.map(\.title)
                // Inside the menu's own event loop: pick, then close.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let index = menu.items.firstIndex(where: { $0.title == item && $0.isEnabled }) {
                            menu.cancelTrackingWithoutAnimation()
                            menu.performActionForItem(at: index)
                            state.picked = true
                        } else {
                            menu.cancelTrackingWithoutAnimation()
                        }
                    }
                }
                // Never leave a menu open (it would block the test).
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    MainActor.assumeIsolated { menu.cancelTracking() }
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = (popUp.object as AnyObject).accessibilityPerformPress?()
        waitUntil(timeout: 4) { state.picked || (state.opened && !state.offered.contains(item)) }
        pump(0.3)
        return state.picked
    }

    /// Chooses `item` in the pop-up menu that offers it (a menu-style Picker), as a person would:
    /// open the menu, click the item.
    func choose(_ item: String, file: StaticString = #filePath, line: UInt = #line) {
        // Radio groups and segmented pickers show their items directly.
        if let radio = nodes().first(where: { $0.role == NSAccessibility.Role.radioButton.rawValue && $0.matches(item) }) {
            _ = (radio.object as AnyObject).accessibilityPerformPress?()
            pump(0.3)
            return
        }
        let menus = popUpMenus()
        // The menu already showing the item first, then the others.
        for popUp in menus.sorted(by: { ($0.value == item ? 0 : 1) < ($1.value == item ? 0 : 1) }) {
            if pick(item, in: popUp) { return }
        }
        XCTFail("No pop-up menu offers “\(item)” (menus: \(menus.map(\.texts))). Tree:\n\(dump())", file: file, line: line)
    }

    func dump(limit: Int = 400) -> String {
        nodes().prefix(limit).map { node in
            String(repeating: " ", count: min(node.depth, 30)) + "\(node.role) \(node.texts)\(node.value.map { " = \($0)" } ?? "")\(node.enabled ? "" : " [disabled]")"
        }.joined(separator: "\n")
    }
}

/// Talks to this process through the system accessibility API, as VoiceOver would, so that
/// SwiftUI builds its accessibility tree. Runs on another thread: the main thread answers.
@MainActor
enum AccessibilityClient {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var text = ""
        var done = false
    }

    static func connect(pumping window: HostedView) -> String {
        let box = Box()
        let pid = getpid()
        let thread = Thread {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 3)
            let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var windows: CFTypeRef?
            let copy = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
            var described: [String] = []
            for element in (windows as? [AXUIElement]) ?? [] {
                var children: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                described.append("\((children as? [AnyObject])?.count ?? -1)")
            }
            box.lock.withLock {
                box.text = "trusted=\(AXIsProcessTrusted()) manual=\(manual.rawValue) windows=\(copy.rawValue) children=\(described)"
                box.done = true
            }
        }
        thread.start()
        _ = window.waitUntil(timeout: 12) { box.lock.withLock { box.done } }
        return box.lock.withLock { box.text }
    }
}

/// The interface, used the way a person uses it: every window is opened in a real window, its
/// controls are clicked and chosen, and what it then shows is read back. Together with the model
/// tests this checks the whole path control -> state -> view after the move to Observation.
@MainActor
final class InterfaceTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        guard HostedView.accessibilityAvailable else {
            throw XCTSkip("The SwiftUI accessibility tree is not available in this process (no accessibility client); see InterfaceDrawingTests.")
        }
    }

    // MARK: Main window

    func testTheAccessibilityTreeIsReadable() throws {
        let settings = try interfaceSettings(profile: false)
        let window = HostedView(ContentView().environment(settings).environment(PhotoSelection()))
        defer { window.close() }
        print("Interface check tree (main window, empty):\n\(window.dump(limit: 120))")
        XCTAssertTrue(window.shows(tr("Generate corrected copies")), window.dump())
    }

    func testGenerateIsDisabledWithTheReasonUntilProfileAndPhotosAreThere() throws {
        let settings = try interfaceSettings(profile: false)
        let selection = PhotoSelection()
        let empty = HostedView(ContentView().environment(settings).environment(selection))
        defer { empty.close() }
        XCTAssertEqual(empty.control(tr("Generate corrected copies"))?.enabled, false, empty.dump())
        XCTAssertTrue(empty.shows(tr("Choose the ICC profile in Settings first.")))
        XCTAssertTrue(empty.shows(tr("Open Settings…")))
        XCTAssertTrue(empty.shows(tr("Drop photos here")))

        // Choosing the profile (in Settings) updates the open window: next reason, no warning.
        try settings.chooseProfile(at: try interfaceProfileURL())
        XCTAssertTrue(empty.waitUntil { empty.shows(tr("Add photos to the list first.")) }, empty.dump())
        XCTAssertFalse(empty.shows(tr("Open Settings…")))
        XCTAssertEqual(empty.control(tr("Generate corrected copies"))?.enabled, false)

        empty.close()
        let photos = try interfacePhotos(2)
        let shared = PhotoSelection()
        let ready = HostedView(ContentView(initialPhotos: photos).environment(settings).environment(shared))
        defer { ready.close() }
        XCTAssertTrue(ready.waitUntil { ready.control(tr("Generate corrected copies"))?.enabled == true }, ready.dump())
        XCTAssertFalse(ready.shows(tr("Add photos to the list first.")))
        // The window publishes its photos for the Statistics window and the full-screen view.
        XCTAssertTrue(ready.waitUntil { shared.photos == photos }, "\(shared.photos)")
        XCTAssertEqual(shared.selected, photos[0])
    }

    func testGeneratingTheCopiesShowsThemAndThePrintActionsAndClearingRemovesThem() throws {
        let settings = try interfaceSettings(profile: true)
        let selection = PhotoSelection()
        let photos = try interfacePhotos(2)
        let window = HostedView(ContentView(initialPhotos: photos).environment(settings).environment(selection))
        defer { window.close() }
        XCTAssertTrue(window.waitUntil { window.control(tr("Generate corrected copies"))?.enabled == true }, window.dump())

        window.press(tr("Generate corrected copies"))
        let ready = trn(2, one: "1 copy ready", other: "%d copies ready")
        XCTAssertTrue(window.waitUntil(timeout: 30) { window.shows(ready) }, window.dump())
        XCTAssertEqual(window.control(tr("Print…"))?.enabled, true, window.dump())
        XCTAssertNotNil(window.control(tr("Save to a folder…")))
        XCTAssertTrue(window.shows(tr("Show in Finder")))

        window.press(tr("Clear"))
        XCTAssertTrue(window.waitUntil { !window.shows(ready) }, window.dump())
        XCTAssertTrue(window.shows(tr("Drop photos here")))
        XCTAssertEqual(window.control(tr("Generate corrected copies"))?.enabled, false)
        XCTAssertTrue(window.shows(tr("Add photos to the list first.")))
        XCTAssertTrue(window.waitUntil { selection.photos.isEmpty })
    }

    func testTheMenusOfTheMainWindowAndTheSettingsStayInStep() throws {
        let settings = try interfaceSettings(profile: true)
        let photos = try interfacePhotos(1)
        let window = HostedView(ContentView(initialPhotos: photos).environment(settings).environment(PhotoSelection()))
        defer { window.close() }
        let saturation = RenderingIntent.saturation.title
        let relative = RenderingIntent.relativeColorimetric.title

        // Menu -> setting.
        window.choose(saturation)
        XCTAssertEqual(settings.renderingIntent, .saturation)
        window.choose(OutputFormat.jpeg.title)
        XCTAssertEqual(settings.outputFormat, .jpeg)
        // Setting (changed elsewhere, e.g. in Settings or Statistics) -> menu.
        settings.renderingIntent = .relativeColorimetric
        XCTAssertTrue(window.waitUntil { window.value(of: tr("Rendering intent")) == relative }, window.dump())
        settings.outputFormat = .png
        XCTAssertTrue(window.waitUntil { window.value(of: tr("Output file format")) == OutputFormat.png.title })
    }

    func testThePreviewViewMenuSwitchesTheView() throws {
        let settings = try interfaceSettings(profile: true)
        let photos = try interfacePhotos(1)
        let window = HostedView(ContentView(initialPhotos: photos).environment(settings).environment(PhotoSelection()))
        defer { window.close() }
        let compareHint = tr("Left: predicted print without correction. Right: with correction. Drag to move the divider.")

        window.choose(tr("Compare"))
        XCTAssertTrue(window.waitUntil(timeout: 20) { window.shows(compareHint) }, window.dump())
        window.choose(tr("Original"))
        XCTAssertTrue(window.waitUntil { !window.shows(compareHint) }, window.dump())
    }

    func testTheLanguageChangesTheOpenWindowsAtOnce() throws {
        let settings = try interfaceSettings(profile: false)
        let window = HostedView(ContentView().environment(settings).environment(PhotoSelection()))
        defer { window.close() }
        let english = tr("Generate corrected copies")
        XCTAssertTrue(window.shows(english))
        settings.language = .italian
        let italian = tr("Generate corrected copies")
        XCTAssertNotEqual(english, italian)
        XCTAssertTrue(window.waitUntil { window.shows(italian) }, window.dump())
        XCTAssertFalse(window.shows(english))
    }

    // MARK: Settings window

    func testTheSettingsControlsChangeTheSettings() throws {
        let settings = try interfaceSettings(profile: true)
        settings.renderingIntent = .relativeColorimetric   // BPC is a free choice only here
        let window = HostedView(SettingsView().environment(settings), size: CGSize(width: 540, height: 900))
        defer { window.close() }
        XCTAssertTrue(window.shows(settings.profileDisplayName), window.dump())

        let bpc = settings.blackPointCompensation
        window.press(tr("Black point compensation (BPC)"))
        XCTAssertEqual(settings.blackPointCompensation, !bpc, window.dump())

        let notice = settings.hidePrintNotice
        window.press(tr("Show the notice before printing"))
        XCTAssertEqual(settings.hidePrintNotice, !notice)

        window.choose(AppTheme.neutralGrey.title)
        XCTAssertEqual(settings.theme, .neutralGrey)
        XCTAssertTrue(window.waitUntil { window.shows(AppTheme.neutralGrey.explanation) }, window.dump())
        settings.theme = .system

        window.choose(AppLanguage.italian.nativeName)
        XCTAssertEqual(settings.language, .italian)
        XCTAssertTrue(window.waitUntil { window.shows(tr("Interface theme")) }, window.dump())
        window.choose(AppLanguage.english.nativeName)
        XCTAssertEqual(settings.language, .english)

        let name = settings.profileDisplayName
        window.press(tr("Remove"))
        XCTAssertNil(settings.profileBookmark)
        XCTAssertTrue(window.waitUntil { !window.shows(name) }, window.dump())
        XCTAssertTrue(window.shows(tr("Choose profile…")))
    }

    func testBlackPointCompensationIsLockedWhereTheProfileForcesIt() throws {
        let settings = try interfaceSettings(profile: true)
        settings.renderingIntent = .relativeColorimetric
        let window = HostedView(SettingsView().environment(settings), size: CGSize(width: 540, height: 900))
        defer { window.close() }
        XCTAssertEqual(window.control(tr("Black point compensation (BPC)"))?.enabled, true, window.dump())
        window.choose(RenderingIntent.perceptual.title)
        XCTAssertEqual(settings.renderingIntent, .perceptual)
        // The Farbenwerk profile is ICC v4: BPC always applies with Perceptual.
        XCTAssertTrue(window.waitUntil { window.control(tr("Black point compensation (BPC)"))?.enabled == false }, window.dump())
    }

    // MARK: Statistics window

    func testTheStatisticsListThePhotosAndFollowTheSelection() throws {
        let settings = try interfaceSettings(profile: true)
        let photos = try interfacePhotos(3)
        let selection = PhotoSelection()
        selection.photos = photos
        selection.selected = photos[0]
        let window = HostedView(StatisticsView().environment(settings).environment(selection), size: CGSize(width: 920, height: 900))
        defer { window.close() }
        XCTAssertTrue(window.waitUntil(timeout: 30) { photos.allSatisfy { window.shows($0.lastPathComponent) } },
                      window.dump())
        XCTAssertEqual(window.value(of: tr("Photo")), photos[0].lastPathComponent, window.dump())

        // Selecting elsewhere (main window) -> the statistics follow.
        selection.selected = photos[2]
        XCTAssertTrue(window.waitUntil { window.value(of: tr("Photo")) == photos[2].lastPathComponent },
                      window.dump())
        // Choosing here -> the main window follows.
        window.choose(photos[1].lastPathComponent)
        XCTAssertEqual(selection.selected, photos[1])

        // The intent comparison suggests the best intent: "Use <intent>", disabled when it is the
        // one in use; pressing it changes the setting for every window.
        let buttons = RenderingIntent.allCases.map { (intent: $0, label: trf("Use %@", $0.title)) }
        XCTAssertTrue(window.waitUntil(timeout: 40) { buttons.contains { window.control($0.label) != nil } }, window.dump())
        let suggested = try XCTUnwrap(buttons.first { window.control($0.label) != nil })
        if suggested.intent == settings.renderingIntent {
            XCTAssertEqual(window.control(suggested.label)?.enabled, false)
        } else {
            window.press(suggested.label)
            XCTAssertEqual(settings.renderingIntent, suggested.intent)
            XCTAssertTrue(window.waitUntil { window.shows(trf("Rendering intent in use: %@", suggested.intent.title)) }, window.dump())
            XCTAssertTrue(window.waitUntil(timeout: 40) { window.control(suggested.label)?.enabled == false }, window.dump())
        }
    }

    func testTheStatisticsWithoutPhotosSayWhatToDo() throws {
        let settings = try interfaceSettings(profile: true)
        let window = HostedView(StatisticsView().environment(settings).environment(PhotoSelection()), size: CGSize(width: 920, height: 760))
        defer { window.close() }
        XCTAssertTrue(window.waitUntil { window.shows(tr("Add photos in the main window to see their statistics.")) }, window.dump())
    }

    // MARK: Full-screen view

    func testTheFullScreenIndicationsFollowTheCommandsAndTheSettings() throws {
        let settings = try interfaceSettings(profile: true)
        let photos = try interfacePhotos(2)
        let model = FullScreenModel(photos: photos, current: photos[0], settings: settings, selection: nil)
        model.autoHidesHUD = false
        model.backingScale = 1
        model.start()
        let window = HostedView(FullScreenView(model: model).environment(settings), size: CGSize(width: 1280, height: 800))
        defer { window.close() }
        XCTAssertTrue(window.waitUntil { window.shows(photos[0].lastPathComponent) && window.shows(tr("Compare")) }, window.dump())

        model.handle(.mode(.original))
        XCTAssertTrue(window.waitUntil { window.shows("\(photos[0].lastPathComponent)  ·  \(tr("Original"))") }, window.dump())
        model.handle(.next)
        XCTAssertTrue(window.waitUntil { window.shows(photos[1].lastPathComponent + "  ·  ") }, window.dump())
        // A setting changed in another window shows up here too.
        settings.renderingIntent = .saturation
        XCTAssertTrue(window.waitUntil { window.shows("  ·  \(RenderingIntent.saturation.title)") }, window.dump())
        model.handle(.toggleHUD)
        XCTAssertTrue(window.waitUntil { !window.shows(photos[1].lastPathComponent + "  ·  ") }, window.dump())
    }

    // MARK: Validation assistant

    func testTheAssistantStepsThroughWithBackAndNext() throws {
        let settings = try interfaceSettings(profile: false)
        let model = ValidationModel(settings: settings, storeURL: nil)
        let window = HostedView(ValidationAssistantView(model: model).environment(settings), size: CGSize(width: 1040, height: 760))
        defer { window.close() }
        XCTAssertTrue(window.shows(ValidationStep.intro.title), window.dump())
        XCTAssertNil(window.control(tr("Back")))
        XCTAssertTrue(window.shows(tr("Choose the printer ICC profile in Settings first.")))

        window.press(tr("Next"))
        XCTAssertTrue(window.waitUntil { window.control(tr("Back")) != nil }, window.dump())
        window.press(tr("Back"))
        XCTAssertTrue(window.waitUntil { window.control(tr("Back")) == nil }, window.dump())

        // The profile chosen in Settings reaches the open assistant.
        try settings.chooseProfile(at: try interfaceProfileURL())
        XCTAssertTrue(window.waitUntil { window.shows(trf("Printer profile: %@", settings.profileDisplayName)) }, window.dump())
    }

    func testTheAssistantModeMenuChangesTheSession() throws {
        let settings = try interfaceSettings(profile: false)
        let model = ValidationModel(settings: settings, storeURL: nil)
        let window = HostedView(ValidationAssistantView(model: model).environment(settings), size: CGSize(width: 1040, height: 760))
        defer { window.close() }
        for mode in ValidationMode.allCases where mode != model.data.mode {
            window.choose(mode.title)
            XCTAssertEqual(model.data.mode, mode, window.dump())
            let visible = ValidationStep.allCases.filter { $0.isVisible(in: mode) }
            XCTAssertTrue(window.waitUntil { visible.allSatisfy { step in window.shows(step.title) } }, window.dump())
        }
    }
}

/// The models behind the windows notify their views of every change the views read, and of
/// nothing else (the bookkeeping is ignored, so it never redraws a window).
@MainActor
final class ObservationTests: XCTestCase {
    /// Whether reading `read` registers a dependency that `change` then invalidates.
    private func invalidates(_ read: () -> Void, _ change: () -> Void) -> Bool {
        let flag = CancellationFlag()
        withObservationTracking(read, onChange: { flag.set() })
        change()
        return flag.isSet
    }

    private func makeSettings() throws -> AppSettings {
        let suite = "selphy-observation-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    func testTheLanguageIsObservedThroughTheTranslations() {
        defer { Localizer.shared.language = .english }
        Localizer.shared.language = .english
        // A view that only calls tr() depends on the language, so a change redraws it...
        XCTAssertTrue(invalidates({ _ = tr("Statistics") }, { Localizer.shared.language = .italian }))
        XCTAssertTrue(invalidates({ _ = trf("Use %@", "x") }, { Localizer.shared.language = .english }))
        // ...and setting the same language again does not.
        XCTAssertFalse(invalidates({ _ = tr("Statistics") }, { Localizer.shared.language = .english }))
        // Still usable from background threads.
        let done = expectation(description: "background translation")
        DispatchQueue.global().async {
            XCTAssertEqual(tr("Statistics"), "Statistics")
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testEverySettingIsObservedAndStillSaved() throws {
        let suite = "selphy-observation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            Localizer.shared.language = .english
        }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(invalidates({ _ = settings.renderingIntent }, { settings.renderingIntent = .saturation }))
        XCTAssertTrue(invalidates({ _ = settings.blackPointCompensation }, { settings.blackPointCompensation.toggle() }))
        XCTAssertTrue(invalidates({ _ = settings.printFit }, { settings.printFit = .fill }))
        XCTAssertTrue(invalidates({ _ = settings.hidePrintNotice }, { settings.hidePrintNotice.toggle() }))
        XCTAssertTrue(invalidates({ _ = settings.outputFormat }, { settings.outputFormat = .jpeg }))
        XCTAssertTrue(invalidates({ _ = settings.simulatePaperWhite }, { settings.simulatePaperWhite.toggle() }))
        XCTAssertTrue(invalidates({ _ = settings.previewMonitorBlack }, { settings.previewMonitorBlack.toggle() }))
        XCTAssertTrue(invalidates({ _ = settings.theme }, { settings.theme = .neutralGrey }))
        XCTAssertTrue(invalidates({ _ = settings.language }, { settings.language = .italian }))
        XCTAssertTrue(invalidates({ _ = settings.selectedPrinterName }, { settings.selectedPrinterName = "SELPHY" }))
        // A view reading one setting is not redrawn for another one.
        XCTAssertFalse(invalidates({ _ = settings.theme }, { settings.outputFormat = .png }))

        // The didSet observers still persist every change.
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.renderingIntent, .saturation)
        XCTAssertEqual(reloaded.printFit, .fill)
        XCTAssertEqual(reloaded.outputFormat, .png)
        XCTAssertEqual(reloaded.theme, .neutralGrey)
        XCTAssertEqual(reloaded.language, .italian)
        XCTAssertEqual(reloaded.selectedPrinterName, "SELPHY")
    }

    func testTheProfileAndFolderChoicesAreObserved() throws {
        let settings = try makeSettings()
        guard let path = ProcessInfo.processInfo.environment["SELPHY_TEST_PRINTER_PROFILE"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Set SELPHY_TEST_PRINTER_PROFILE")
        }
        XCTAssertTrue(invalidates({ _ = settings.profileBookmark }, { try? settings.chooseProfile(at: URL(fileURLWithPath: path)) }))
        XCTAssertTrue(invalidates({ _ = settings.profileDisplayName }, { settings.clearProfile() }))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("selphy-obs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(invalidates({ _ = settings.saveFolderDisplayName }, { try? settings.chooseSaveFolder(at: folder) }))
        XCTAssertTrue(invalidates({ _ = settings.temporaryFolderDisplayName }, { try? settings.chooseTemporaryFolder(at: folder) }))
        XCTAssertTrue(invalidates({ _ = settings.temporaryFolderBookmark }, { settings.clearTemporaryFolder() }))
    }

    func testTheSharedSelectionAndTheSmallModelsAreObserved() {
        let selection = PhotoSelection()
        let url = URL(fileURLWithPath: "/tmp/a.png")
        XCTAssertTrue(invalidates({ _ = selection.photos }, { selection.photos = [url] }))
        XCTAssertTrue(invalidates({ _ = selection.selected }, { selection.selected = url }))
        XCTAssertFalse(invalidates({ _ = selection.photos }, { selection.selected = nil }))

        let pointer = PointerReadout()
        XCTAssertTrue(invalidates({ _ = pointer.reading }, {
            pointer.reading = PixelReading(x: 1, y: 2, intended: Lab3(l: 50, a: 0, b: 0), predicted: Lab3(l: 51, a: 0, b: 0), deltaE: 1)
        }))

        let highlight = ScopeHighlight.shared
        XCTAssertTrue(invalidates({ _ = highlight.marker }, {
            highlight.marker = .init(photo: url, vertical: true, start: 0.1, span: 0.01)
        }))
        highlight.marker = nil
    }

    func testConversionProgressFromABackgroundThreadReachesTheView() {
        let progress = ConversionProgress()
        let flag = CancellationFlag()
        withObservationTracking({ _ = progress.completed }, onChange: { flag.set() })
        let done = expectation(description: "background update")
        DispatchQueue.global().async {
            progress.update(completed: 3, total: 5)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        let end = Date().addingTimeInterval(2)
        while !flag.isSet, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(flag.isSet)
        XCTAssertEqual(progress.completed, 3)
        XCTAssertEqual(progress.total, 5)
    }

    func testTheFullScreenModelIsObservedButItsBookkeepingIsNot() throws {
        let settings = try makeSettings()
        let photos = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")]
        let model = FullScreenModel(photos: photos, current: photos[0], settings: settings, selection: nil)
        XCTAssertTrue(invalidates({ _ = model.mode }, { model.handle(.mode(.original)) }))
        XCTAssertTrue(invalidates({ _ = model.sideBySide }, { model.handle(.toggleSideBySide) }))
        XCTAssertTrue(invalidates({ _ = model.divider }, { model.divider = 0.3 }))
        XCTAssertTrue(invalidates({ _ = model.area }, { model.area = CGSize(width: 800, height: 600) }))
        // The status line depends on a setting held by another object.
        XCTAssertTrue(invalidates({ _ = model.statusLine }, { settings.renderingIntent = .saturation }))
        // Bookkeeping (not shown) never redraws the window.
        XCTAssertFalse(invalidates({ _ = model.backingScale; _ = model.pointerOnHUD }, {
            model.backingScale = 2
            model.pointerOnHUD = true
        }))
    }

    func testTheValidationSessionIsObservedAndSavedOnChange() throws {
        let settings = try makeSettings()
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("selphy-obs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: store) }
        let model = ValidationModel(settings: settings, storeURL: store)
        let other = ValidationMode.allCases.first { $0 != model.data.mode }!
        XCTAssertTrue(invalidates({ _ = model.data.mode }, { model.data.mode = other }))
        XCTAssertTrue(invalidates({ _ = model.message }, { model.message = "x" }))
        XCTAssertEqual(ValidationModel(settings: settings, storeURL: store).data.mode, other, "saved by didSet")
    }
}

/// Settings, profile and photos for the interface tests (each test gets its own defaults).
@MainActor
extension XCTestCase {
    func interfaceSettings(profile: Bool) throws -> AppSettings {
        let suite = "selphy-interface-\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suite)
            Localizer.shared.language = .english
        }
        let settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        if profile { try settings.chooseProfile(at: try interfaceProfileURL()) }
        return settings
    }

    func interfaceProfileURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["SELPHY_TEST_PRINTER_PROFILE"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Set SELPHY_TEST_PRINTER_PROFILE to run the interface tests with the printer profile.")
        }
        return URL(fileURLWithPath: path)
    }

    func interfacePhotos(_ count: Int) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("selphy-interface-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        return try (0..<count).map { index in
            let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor(hue: 0.2 * CGFloat(index), saturation: 0.6, brightness: 0.8, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            context.setFillColor(NSColor(white: 0.2, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 150, height: 100))
            let url = folder.appendingPathComponent("Photo-\(index + 1).png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return url
        }
    }
}
