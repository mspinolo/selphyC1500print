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

    /// How the image is placed on the sheet when printing.
    @Published var printFit: PrintFit {
        didSet { defaults.set(printFit.rawValue, forKey: Keys.printFit) }
    }

    /// The notice shown before printing (Image Optimize...) can be silenced by the user.
    @Published var hidePrintNotice: Bool {
        didSet { defaults.set(hidePrintNotice, forKey: Keys.hidePrintNotice) }
    }

    @Published var outputFormat: OutputFormat {
        didSet { defaults.set(outputFormat.rawValue, forKey: Keys.outputFormat) }
    }

    /// Preview option: simulate the paper tint and brightness (shared by the preview and the
    /// full-screen view).
    @Published var simulatePaperWhite: Bool {
        didSet { defaults.set(simulatePaperWhite, forKey: Keys.simulatePaperWhite) }
    }

    /// Preview option: stretch the printed black to the monitor's black.
    @Published var previewMonitorBlack: Bool {
        didSet { defaults.set(previewMonitorBlack, forKey: Keys.previewMonitorBlack) }
    }

    /// Interface theme: follows the system by default; neutral grey for judging colours.
    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
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

    /// Folder for the temporary corrected copies (nil = the system temporary folder).
    @Published private(set) var temporaryFolderBookmark: Data? {
        didSet { defaults.set(temporaryFolderBookmark, forKey: Keys.temporaryFolderBookmark) }
    }

    @Published private(set) var temporaryFolderDisplayName: String {
        didSet { defaults.set(temporaryFolderDisplayName, forKey: Keys.temporaryFolderDisplayName) }
    }

    /// The chosen temporary folder with its security-scoped access kept open for the whole run:
    /// the copies written there must stay readable for printing, saving and the Finder.
    private var openTemporaryFolder: URL?

    private let defaults: UserDefaults

    private enum Keys {
        static let language = "language"
        static let theme = "interfaceTheme"
        static let simulatePaperWhite = "previewSimulatePaperWhite"
        static let previewMonitorBlack = "previewMonitorBlack"
        static let printerName = "selectedPrinterName"
        static let renderingIntent = "renderingIntent"
        static let blackPointCompensation = "blackPointCompensation"
        static let outputFormat = "outputFormat"
        static let printFit = "printFit"
        static let hidePrintNotice = "hidePrintNotice"
        static let profileBookmark = "profileBookmark"
        static let profileDisplayName = "profileDisplayName"
        static let saveFolderBookmark = "saveFolderBookmark"
        static let saveFolderDisplayName = "saveFolderDisplayName"
        static let temporaryFolderBookmark = "temporaryFolderBookmark"
        static let temporaryFolderDisplayName = "temporaryFolderDisplayName"
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
        self.printFit = PrintFit(rawValue: defaults.string(forKey: Keys.printFit) ?? "") ?? .fit
        self.hidePrintNotice = defaults.bool(forKey: Keys.hidePrintNotice)
        self.theme = AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        self.simulatePaperWhite = defaults.bool(forKey: Keys.simulatePaperWhite)
        self.previewMonitorBlack = defaults.bool(forKey: Keys.previewMonitorBlack)
        self.profileBookmark = defaults.data(forKey: Keys.profileBookmark)
        self.profileDisplayName = defaults.string(forKey: Keys.profileDisplayName) ?? ""
        self.saveFolderBookmark = defaults.data(forKey: Keys.saveFolderBookmark)
        self.saveFolderDisplayName = defaults.string(forKey: Keys.saveFolderDisplayName) ?? ""
        self.temporaryFolderBookmark = defaults.data(forKey: Keys.temporaryFolderBookmark)
        self.temporaryFolderDisplayName = defaults.string(forKey: Keys.temporaryFolderDisplayName) ?? ""
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

    func chooseTemporaryFolder(at url: URL) throws {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        closeTemporaryFolder()
        temporaryFolderBookmark = bookmark
        temporaryFolderDisplayName = url.path
    }

    /// Back to the system temporary folder.
    func clearTemporaryFolder() {
        closeTemporaryFolder()
        temporaryFolderBookmark = nil
        temporaryFolderDisplayName = ""
    }

    /// The chosen temporary folder, opened for access, or nil when none is chosen. Throws when a
    /// folder is chosen but cannot be reached (deleted, disconnected drive).
    func temporaryFolder() throws -> URL? {
        guard let temporaryFolderBookmark else { return nil }
        if let openTemporaryFolder { return openTemporaryFolder }
        var isStale = false
        let url = try URL(resolvingBookmarkData: temporaryFolderBookmark, options: [.withSecurityScope],
                          relativeTo: nil, bookmarkDataIsStale: &isStale)
        var isDirectory: ObjCBool = false
        let opened = url.startAccessingSecurityScopedResource()
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            if opened { url.stopAccessingSecurityScopedResource() }
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        if isStale, let renewed = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            self.temporaryFolderBookmark = renewed
        }
        if opened { openTemporaryFolder = url }
        return url
    }

    private func closeTemporaryFolder() {
        openTemporaryFolder?.stopAccessingSecurityScopedResource()
        openTemporaryFolder = nil
    }

    func clearProfile() {
        profileBookmark = nil
        profileDisplayName = ""
    }
}
