import SwiftUI

@main
struct SELPHYCP1500PrintApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .frame(minWidth: 720, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
