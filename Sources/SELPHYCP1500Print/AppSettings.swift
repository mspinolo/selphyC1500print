import Foundation
import AppKit

enum RenderingIntent: String, CaseIterable, Identifiable, Sendable, Hashable {
    case perceptual
    case relativeColorimetric
    case saturation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .perceptual: tr("Perceptual")
        case .relativeColorimetric: tr("Relative colorimetric")
        case .saturation: tr("Saturation")
        }
    }

    var explanation: String {
        switch self {
        case .perceptual: tr("Uses the profile's perceptual mapping.")
        case .relativeColorimetric: tr("Keeps in-gamut colours and adapts the media white.")
        case .saturation: tr("Favours vividness; mostly useful for graphics.")
        }
    }
}

enum OutputFormat: String, CaseIterable, Identifiable, Sendable, Hashable {
    case png
    case jpeg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: tr("PNG (lossless)")
        case .jpeg: tr("JPEG (lossy)")
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }

    var explanation: String {
        switch self {
        case .png: tr("Recommended: no loss after colour correction. Larger files.")
        case .jpeg: tr("Smaller files, but lossy compression is applied after colour correction.")
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

    @Published var outputFormat: OutputFormat {
        didSet { defaults.set(outputFormat.rawValue, forKey: Keys.outputFormat) }
    }

    /// Interface language: English by default, Italian on request.
    @Published var language: AppLanguage {
        didSet {
            Localizer.shared.language = language
            defaults.set(language.rawValue, forKey: Keys.language)
        }
    }

    @Published private(set) var profileBookmark: Data? {
        didSet { defaults.set(profileBookmark, forKey: Keys.profileBookmark) }
    }

    @Published private(set) var profileDisplayName: String {
        didSet { defaults.set(profileDisplayName, forKey: Keys.profileDisplayName) }
    }

    /// Folder the corrected copies are saved to, remembered as a security-scoped bookmark.
    @Published private(set) var saveFolderBookmark: Data? {
        didSet { defaults.set(saveFolderBookmark, forKey: Keys.saveFolderBookmark) }
    }

    @Published private(set) var saveFolderDisplayName: String {
        didSet { defaults.set(saveFolderDisplayName, forKey: Keys.saveFolderDisplayName) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let language = "language"
        static let printerName = "selectedPrinterName"
        static let renderingIntent = "renderingIntent"
        static let blackPointCompensation = "blackPointCompensation"
        static let outputFormat = "outputFormat"
        static let profileBookmark = "profileBookmark"
        static let profileDisplayName = "profileDisplayName"
        static let saveFolderBookmark = "saveFolderBookmark"
        static let saveFolderDisplayName = "saveFolderDisplayName"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let language = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .english
        self.language = language
        Localizer.shared.language = language
        self.selectedPrinterName = defaults.string(forKey: Keys.printerName) ?? ""
        self.renderingIntent = RenderingIntent(rawValue: defaults.string(forKey: Keys.renderingIntent) ?? "") ?? .perceptual
        self.blackPointCompensation = defaults.object(forKey: Keys.blackPointCompensation) as? Bool ?? false
        self.outputFormat = OutputFormat(rawValue: defaults.string(forKey: Keys.outputFormat) ?? "") ?? .png
        self.profileBookmark = defaults.data(forKey: Keys.profileBookmark)
        self.profileDisplayName = defaults.string(forKey: Keys.profileDisplayName) ?? ""
        self.saveFolderBookmark = defaults.data(forKey: Keys.saveFolderBookmark)
        self.saveFolderDisplayName = defaults.string(forKey: Keys.saveFolderDisplayName) ?? ""
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

    func chooseSaveFolder(at url: URL) throws {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        saveFolderBookmark = bookmark
        saveFolderDisplayName = url.lastPathComponent
    }

    /// The remembered save folder, or nil if none is set. A stale bookmark is renewed.
    func resolveSaveFolderURL() throws -> URL? {
        guard let saveFolderBookmark else { return nil }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: saveFolderBookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            try chooseSaveFolder(at: url)
        }
        return url
    }

    func clearSaveFolder() {
        saveFolderBookmark = nil
        saveFolderDisplayName = ""
    }

    func clearProfile() {
        profileBookmark = nil
        profileDisplayName = ""
    }
}
