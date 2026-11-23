import Foundation
import AppKit

enum RenderingIntent: String, CaseIterable, Identifiable, Sendable, Hashable {
    case perceptual
    case relativeColorimetric
    case saturation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .perceptual: "Percettivo"
        case .relativeColorimetric: "Colorimetrico relativo"
        case .saturation: "Saturazione"
        }
    }

    var explanation: String {
        switch self {
        case .perceptual: "Usa la mappatura percettiva del profilo."
        case .relativeColorimetric: "Mantiene i colori in gamut e adatta il bianco del supporto."
        case .saturation: "Privilegia la vivacità; utile soprattutto per grafica."
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var selectedPrinterName: String {
        didSet { defaults.set(selectedPrinterName, forKey: Keys.printerName) }
    }

    @Published var renderingIntent: RenderingIntent {
        didSet { defaults.set(renderingIntent.rawValue, forKey: Keys.renderingIntent) }
    }

    @Published var blackPointCompensation: Bool {
        didSet { defaults.set(blackPointCompensation, forKey: Keys.blackPointCompensation) }
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
        static let renderingIntent = "renderingIntent"
        static let blackPointCompensation = "blackPointCompensation"
        static let profileBookmark = "profileBookmark"
        static let profileDisplayName = "profileDisplayName"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedPrinterName = defaults.string(forKey: Keys.printerName) ?? ""
        self.renderingIntent = RenderingIntent(rawValue: defaults.string(forKey: Keys.renderingIntent) ?? "") ?? .perceptual
        self.blackPointCompensation = defaults.object(forKey: Keys.blackPointCompensation) as? Bool ?? false
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
