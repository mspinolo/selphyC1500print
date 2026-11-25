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
    @StateObject private var settings = AppSettings()
    @StateObject private var selection = PhotoSelection()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(selection)
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
                .environmentObject(settings)
                .environmentObject(selection)
        }
        .defaultSize(width: 920, height: 760)
        .windowResizability(.contentMinSize)
        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
