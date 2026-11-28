import AppKit
import SwiftUI

/// A single-window utility: closing the last window quits the app. Without this the process stayed
/// alive with no window (the "New Window" command is removed), and could not be reopened.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct SELPHYCP1500PrintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var selection = PhotoSelection()
    @State private var validation: ValidationModel

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _validation = State(initialValue: ValidationModel(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(selection)
                .onAppear { AppTheme.apply(settings.theme) }
                .onChange(of: settings.theme) { AppTheme.apply(settings.theme) }
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button(tr("Full-screen view")) {
                    FullScreenController.shared.toggle(settings: settings, selection: selection)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(selection.photos.isEmpty || settings.profileBookmark == nil)
            }
        }
        // A window of its own (not a sheet), so that it can stay open next to the preview.
        Window(tr("Colour deviation statistics"), id: StatisticsView.windowID) {
            StatisticsView()
                .environment(settings)
                .environment(selection)
        }
        .defaultSize(width: 920, height: 760)
        .windowResizability(.contentMinSize)
        // Advanced > Print validation assistant: the physical test, step by step (M3.3).
        Window(tr("Print validation assistant"), id: ValidationAssistantView.windowID) {
            ValidationAssistantView(model: validation)
                .environment(settings)
        }
        .defaultSize(width: 1040, height: 760)
        .windowResizability(.contentMinSize)
        .commands { AdvancedCommands() }
        Settings {
            SettingsView()
                .environment(settings)
        }
    }
}

/// The Advanced menu.
struct AdvancedCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu(tr("Advanced")) {
            Button(tr("Print validation assistant…")) { openWindow(id: ValidationAssistantView.windowID) }
        }
    }
}
