import SwiftUI

@main
struct SELPHYCP1500PrintApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .frame(minWidth: 820, minHeight: 900)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
