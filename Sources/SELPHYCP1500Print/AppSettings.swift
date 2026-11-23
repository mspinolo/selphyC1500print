import Foundation
import AppKit

@MainActor
final class AppSettings: ObservableObject {
    @Published var selectedPrinterName: String {
        didSet { defaults.set(selectedPrinterName, forKey: Keys.printerName) }
    }

    @Published private(set) var profileBookmark: Data? {
        didSet { defaults.set(profileBookmark, forKey: Keys.profileBookmark) }
    }

    @Published private(set) var profileDisplayName: String {
        didSet { defaults.set(profileDisplayName, forKey: Keys.profileDisplayName) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let printerName = "selectedPrinterName"
        static let profileBookmark = "profileBookmark"
        static let profileDisplayName = "profileDisplayName"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedPrinterName = defaults.string(forKey: Keys.printerName) ?? ""
        self.profileBookmark = defaults.data(forKey: Keys.profileBookmark)
        self.profileDisplayName = defaults.string(forKey: Keys.profileDisplayName) ?? ""
    }

    func chooseProfile(at url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        profileBookmark = bookmark
        profileDisplayName = url.lastPathComponent
    }

    func resolveProfileURL() throws -> URL? {
        guard let profileBookmark else { return nil }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: profileBookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            try chooseProfile(at: url)
        }
        return url
    }

    func clearProfile() {
        profileBookmark = nil
        profileDisplayName = ""
    }
}
