import AppKit
import Foundation
import Observation

/// Security-scoped bookmarks of files and folders the user chose (the app is sandboxed).
enum Bookmarks {
    static func make(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ data: Data?) -> URL? {
        guard let data else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// A fresh bookmark when `data` is stale (the item was moved or renamed since it was chosen:
    /// the system still finds it, but may stop doing so), nil when it is current or unresolvable.
    static func renewed(_ data: Data) -> Data? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                                 bookmarkDataIsStale: &stale), stale else { return nil }
        return url.withSecurityScope { try? make($0) }
    }

    /// Runs `body` with access to the bookmarked file.
    static func withAccess<T>(_ data: Data?, _ body: (URL) throws -> T) throws -> T? {
        guard let url = resolve(data) else { return nil }
        return try url.withSecurityScope(body)
    }
}

/// The four photographs of the physical test.
enum PhotoRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case portrait, foliageSky = "foliage-sky", lowKey = "low-key", blackAndWhite = "black-and-white"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portrait: tr("Portrait (skin tones)")
        case .foliageSky: tr("Foliage and sky")
        case .lowKey: tr("Low-key (dark tones)")
        case .blackAndWhite: tr("Black and white")
        }
    }
}

/// One sheet of the print session, known to the printer operator only by its code.
struct PlanItem: Codable, Equatable, Identifiable, Sendable {
    enum Content: Codable, Equatable, Sendable {
        case chart(ChartVariant)
        case photo(PhotoRole, corrected: Bool)
    }

    var code: String
    var content: Content
    var id: String { code }

    var imageOptimizeOn: Bool {
        if case .chart(let variant) = content { return variant.imageOptimizeOn }
        return false
    }

    /// The variant label of the key (run-plan.csv of make_run_plan.py).
    var variantLabel: String {
        switch content {
        case .chart(let variant): variant.rawValue
        case .photo(let role, let corrected): "\(role.rawValue)/\(corrected ? "V1" : "V0")"
        }
    }

    var keyDescription: String {
        switch content {
        case .chart(let variant):
            switch variant {
            case .v0: "chart, original file"
            case .v1: "chart, corrected Perceptual (BPC off in the app; it is forced on for v4 profiles anyway)"
            case .v2: "chart, corrected Relative colorimetric, BPC off"
            case .v3: "chart, corrected Perceptual"
            case .v4: "chart, original file"
            }
        case .photo(let role, let corrected): "photo \(role.rawValue), \(corrected ? "corrected Perceptual" : "original file")"
        }
    }

    var chartVariant: ChartVariant? {
        if case .chart(let variant) = content { return variant }
        return nil
    }
}

/// A new folder name in `folder`: "name", else "name 2", "name 3", ...
func uniqueFolder(in folder: URL, name: String) -> URL {
    var candidate = folder.appendingPathComponent(name, isDirectory: true)
    var counter = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        candidate = folder.appendingPathComponent("\(name) \(counter)", isDirectory: true)
        counter += 1
    }
    return candidate
}

enum ValidationPlan {
    /// The sheets of the session in random order with blind codes P01, P02, ...
    static func make(mode: ValidationMode, photos: [PhotoRole], seed: UInt64? = nil) -> [PlanItem] {
        let variants: [ChartVariant] = mode == .scanner ? ChartVariant.allCases : [.v0, .v1]
        var contents: [PlanItem.Content] = variants.map { .chart($0) }
        for role in photos {
            contents.append(.photo(role, corrected: false))
            contents.append(.photo(role, corrected: true))
        }
        if let seed {
            var generator = SeededGenerator(seed: seed)
            contents.shuffle(using: &generator)
        } else {
            contents.shuffle()
        }
        return contents.enumerated().map { PlanItem(code: String(format: "P%02d", $0.offset + 1), content: $0.element) }
    }

    /// run-plan.csv with the key (make_run_plan.py format): keep it apart until the scans are done.
    static func keyCSV(_ plan: [PlanItem]) -> String {
        (["print_order_code,variant,content,printer_image_optimize"] + plan.map {
            "\($0.code),\($0.variantLabel),\"\($0.keyDescription)\",\($0.imageOptimizeOn ? "ON" : "OFF")"
        }).joined(separator: "\n") + "\n"
    }

    /// The sheet list for the print session: codes and the printer setting only, no content.
    static func printOrderCSV(_ plan: [PlanItem]) -> String {
        (["print_order_code,printer_image_optimize"] + plan.map { "\($0.code),\($0.imageOptimizeOn ? "ON" : "OFF")" })
            .joined(separator: "\n") + "\n"
    }
}

/// SplitMix64: a reproducible plan for the tests.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum ValidationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case scanner, visual
    var id: String { rawValue }

    var title: String {
        switch self {
        case .scanner: tr("With a scanner (measured)")
        case .visual: tr("Without a scanner (visual comparison)")
        }
    }
}

struct PhotoSlot: Codable, Equatable, Sendable {
    var role: PhotoRole
    var name: String
    var bookmark: Data
}

struct ScanEntry: Codable, Equatable, Sendable {
    var name: String
    var bookmark: Data
    var result: ChartScanResult?
    var error: String?
}

/// Everything the assistant remembers between the steps (and between days: print, wait 24 h, scan).
struct ValidationSessionData: Codable, Equatable {
    var mode: ValidationMode = .scanner
    var referenceID: String = ReferenceSet.defaultID
    var importedReference: ReferenceSet?
    var photos: [PhotoSlot] = []
    var plan: [PlanItem] = []
    var exportFolderName: String?
    var exportFolderBookmark: Data?
    var exportedAt: Date?
    var checklist: [String: Bool] = [:]
    var record: String = ""
    var scannerProfileName: String?
    var scannerProfileBookmark: Data?
    var colorCheckerScanName: String?
    var colorCheckerScanBookmark: Data?
    var corners: [[Double]] = []
    var scannerCheck: ScannerCheckResult?
    var scans: [String: ScanEntry] = [:]
    var visual: [VisualVerdict] = []
    var printerProfileDigest: Data?

    /// Reads a session written by this or an older version: a field the file does not have (an
    /// older version did not know it) keeps its default instead of making the whole file unreadable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ValidationSessionData()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        mode = try value(.mode, defaults.mode)
        referenceID = try value(.referenceID, defaults.referenceID)
        importedReference = try container.decodeIfPresent(ReferenceSet.self, forKey: .importedReference)
        photos = try value(.photos, defaults.photos)
        plan = try value(.plan, defaults.plan)
        exportFolderName = try container.decodeIfPresent(String.self, forKey: .exportFolderName)
        exportFolderBookmark = try container.decodeIfPresent(Data.self, forKey: .exportFolderBookmark)
        exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt)
        checklist = try value(.checklist, defaults.checklist)
        record = try value(.record, defaults.record)
        scannerProfileName = try container.decodeIfPresent(String.self, forKey: .scannerProfileName)
        scannerProfileBookmark = try container.decodeIfPresent(Data.self, forKey: .scannerProfileBookmark)
        colorCheckerScanName = try container.decodeIfPresent(String.self, forKey: .colorCheckerScanName)
        colorCheckerScanBookmark = try container.decodeIfPresent(Data.self, forKey: .colorCheckerScanBookmark)
        corners = try value(.corners, defaults.corners)
        scannerCheck = try container.decodeIfPresent(ScannerCheckResult.self, forKey: .scannerCheck)
        scans = try value(.scans, defaults.scans)
        visual = try value(.visual, defaults.visual)
        printerProfileDigest = try container.decodeIfPresent(Data.self, forKey: .printerProfileDigest)
    }

    init() {}

    /// Renews every stale bookmark (photos, scans, folders, profiles); returns whether any changed.
    mutating func renewStaleBookmarks() -> Bool {
        var changed = false
        func renew(_ bookmark: inout Data) {
            if let fresh = Bookmarks.renewed(bookmark) { bookmark = fresh; changed = true }
        }
        func renewOptional(_ bookmark: inout Data?) {
            if let current = bookmark, let fresh = Bookmarks.renewed(current) { bookmark = fresh; changed = true }
        }
        for index in photos.indices { renew(&photos[index].bookmark) }
        for code in Array(scans.keys) { if var entry = scans[code] { renew(&entry.bookmark); scans[code] = entry } }
        renewOptional(&exportFolderBookmark)
        renewOptional(&scannerProfileBookmark)
        renewOptional(&colorCheckerScanBookmark)
        return changed
    }

    var reference: ReferenceSet {
        if let importedReference, importedReference.id == referenceID { return importedReference }
        return ReferenceSet.builtIn(id: referenceID) ?? .default
    }

    var chartResults: [ChartVariant: ChartScanResult] {
        var out: [ChartVariant: ChartScanResult] = [:]
        for item in plan {
            if let variant = item.chartVariant, let result = scans[item.code]?.result { out[variant] = result }
        }
        return out
    }
}

/// Reads, changes and saves the assistant's session; does the work of each step.
@MainActor
@Observable
final class ValidationModel {
    var data: ValidationSessionData {
        didSet { if data != oldValue { save() } }
    }
    var busy: String?
    var message: String?
    var errorMessage: String?
    /// A problem with the session file (unreadable, or not saved). Unlike `errorMessage` it is
    /// not cleared by the next action: it stays until the problem is solved.
    var storageWarning: String?
    var report: String = ""
    var models: [ChartVariant: ScanSummary] = [:]

    let settings: AppSettings
    private let storeURL: URL?
    @ObservationIgnored private var saveFailed = false
    /// Set when an unreadable session file could not be set aside: it is never overwritten.
    @ObservationIgnored private var saveBlocked = false

    init(settings: AppSettings, storeURL: URL? = ValidationModel.defaultStoreURL) {
        self.settings = settings
        self.storeURL = storeURL
        var loaded = ValidationSessionData()
        var warning: String?
        if let storeURL, FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                loaded = try JSONDecoder().decode(ValidationSessionData.self, from: Data(contentsOf: storeURL))
            } catch {
                // Never overwrite a session that cannot be read: keep it aside and say so.
                if let kept = Self.keepUnreadable(storeURL) {
                    warning = trf("The saved validation session could not be read, so a new one was started. The old file was kept as “%@”.", kept)
                } else {
                    saveBlocked = true
                    warning = trf("The saved validation session could not be read and could not be set aside, so nothing will be saved until “%@” is moved away.", storeURL.path)
                }
            }
        }
        let renewed = loaded.renewStaleBookmarks()
        if loaded.visual.isEmpty { loaded.visual = PhotoRole.allCases.map { VisualVerdict(photoRole: $0.rawValue) } }
        data = loaded
        storageWarning = warning
        if renewed { save() }
    }

    /// Moves an unreadable session file next to itself under a dated name; returns that name.
    nonisolated static func keepUnreadable(_ url: URL, now: Date = Date()) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = url.deletingPathExtension().lastPathComponent + "-unreadable-" + formatter.string(from: now)
        var target = url.deletingLastPathComponent().appendingPathComponent(base + ".json")
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent().appendingPathComponent("\(base)-\(counter).json")
            counter += 1
        }
        if (try? FileManager.default.moveItem(at: url, to: target)) != nil { return target.lastPathComponent }
        // Cannot move it (permissions): a copy is enough, the original is then replaced safely.
        if (try? FileManager.default.copyItem(at: url, to: target)) != nil { return target.lastPathComponent }
        return nil
    }

    nonisolated static var defaultStoreURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("SELPHY CP1500 Print", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("validation-session.json")
    }

    private func save() {
        guard let storeURL, !saveBlocked else { return }
        do {
            try JSONEncoder().encode(data).write(to: storeURL, options: .atomic)
            if saveFailed {
                saveFailed = false
                storageWarning = nil
            }
        } catch {
            saveFailed = true
            storageWarning = trf("The validation session could not be saved: %@", error.localizedDescription)
        }
    }

    func reset() {
        data = ValidationSessionData()
        data.visual = PhotoRole.allCases.map { VisualVerdict(photoRole: $0.rawValue) }
        report = ""
        models = [:]
        message = nil
        errorMessage = nil
        if !saveFailed { storageWarning = nil }
    }

    private func printerProfile() throws -> Data {
        guard let data = try settings.readProfile() else {
            throw ColorCorrectionService.CorrectionError.profileLoad(tr("Choose the printer ICC profile in Settings first."))
        }
        return data
    }

    // MARK: Reference

    func importReference(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let set = try ReferenceImport.parse(text, name: url.lastPathComponent)
            data.importedReference = set
            data.referenceID = set.id
            data.scannerCheck = nil
            errorMessage = nil
            message = trf("Imported %d patches from %@.", set.patches.count, url.lastPathComponent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Photos and plan

    func setPhoto(_ url: URL?, for role: PhotoRole) {
        data.photos.removeAll { $0.role == role }
        if let url, let bookmark = try? Bookmarks.make(url) {
            data.photos.append(PhotoSlot(role: role, name: url.lastPathComponent, bookmark: bookmark))
        }
        data.plan = []
        data.exportedAt = nil
    }

    func makePlan() {
        let roles = PhotoRole.allCases.filter { role in data.photos.contains { $0.role == role } }
        data.plan = ValidationPlan.make(mode: data.mode, photos: roles)
        data.exportedAt = nil
        data.scans = [:]
    }

    /// Writes the files to print, named by code, plus the print order and the key.
    func exportPrintSet(to folder: URL) async {
        if data.plan.isEmpty { makePlan() }
        busy = tr("Preparing the files to print…")
        defer { busy = nil }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        do {
            let profileURL = try settings.resolveProfileURL()
            guard let profileURL else { throw ColorCorrectionService.CorrectionError.profileLoad(tr("Choose the printer ICC profile in Settings first.")) }
            let plan = data.plan
            let photos = data.photos
            let target = try await Task.detached(priority: .userInitiated) {
                try Self.writePrintSet(plan: plan, photos: photos, folder: folder, profileURL: profileURL)
            }.value
            data.exportFolderName = target.path
            data.exportFolderBookmark = try? Bookmarks.make(folder)
            data.exportedAt = Date()
            errorMessage = nil
            message = trf("%d files written to %@.", plan.count, target.lastPathComponent)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    nonisolated static func writePrintSet(plan: [PlanItem], photos: [PhotoSlot], folder: URL, profileURL: URL) throws -> URL {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let target = uniqueFolder(in: folder, name: "SELPHY validation \(stamp)")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let work = fm.temporaryDirectory.appendingPathComponent("selphy-validation-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let profileAccess = profileURL.startAccessingSecurityScopedResource()
        defer { if profileAccess { profileURL.stopAccessingSecurityScopedResource() } }

        // The chart: original, and corrected copies made by the same code as any photo.
        let chartURL = work.appendingPathComponent("selphy_chart_v\(ValidationChart.version).png")
        try ValidationChart.standard.writePNG(to: chartURL)
        func corrected(_ source: URL, intent: RenderingIntent) throws -> URL {
            let result = try ColorCorrectionService.prepareCopies(
                from: [source], printerProfileURL: profileURL, intent: intent, blackPointCompensation: false, outputFormat: .png)
            guard let file = result.files.first else { throw ColorCorrectionService.CorrectionError.imageEncoding(source) }
            return file
        }
        var chartFiles: [ChartVariant: URL] = [.v0: chartURL]
        let variants = Set(plan.compactMap(\.chartVariant))
        if variants.contains(.v1) || variants.contains(.v3) { chartFiles[.v1] = try corrected(chartURL, intent: .perceptual) }
        if variants.contains(.v2) { chartFiles[.v2] = try corrected(chartURL, intent: .relativeColorimetric) }

        for item in plan {
            let source: URL
            switch item.content {
            case .chart(let variant):
                source = chartFiles[variant.modelVariant]!
            case .photo(let role, let isCorrected):
                guard let slot = photos.first(where: { $0.role == role }), let url = Bookmarks.resolve(slot.bookmark) else { continue }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if isCorrected {
                    source = try corrected(url, intent: .perceptual)
                } else {
                    let copy = work.appendingPathComponent("\(item.code)-original").appendingPathExtension(url.pathExtension)
                    try fm.copyItem(at: url, to: copy)
                    source = copy
                }
            }
            try fm.copyItem(at: source, to: target.appendingPathComponent(item.code).appendingPathExtension(source.pathExtension.lowercased()))
        }
        try ValidationPlan.printOrderCSV(plan).write(to: target.appendingPathComponent("print-order.csv"), atomically: true, encoding: .utf8)
        let keyFolder = target.appendingPathComponent("KEY - open only after scanning", isDirectory: true)
        try fm.createDirectory(at: keyFolder, withIntermediateDirectories: true)
        try ValidationPlan.keyCSV(plan).write(to: keyFolder.appendingPathComponent("run-plan.csv"), atomically: true, encoding: .utf8)
        try readme(plan: plan).write(to: target.appendingPathComponent("READ ME.txt"), atomically: true, encoding: .utf8)
        return target
    }

    nonisolated static func readme(plan: [PlanItem]) -> String {
        var lines = [
            "SELPHY CP1500 print validation – files to print",
            "",
            "Print the files in code order (P01, P02, ...) from Preview: File > Print, paper size Postcard (100 x 148 mm),",
            "the same scaling and borderless choice for every sheet. Write only the code on the back of each print.",
            "Before every sheet check on the printer: Setup > Print settings > Image Optimize (it resets at power-off).",
            "",
            "Code  Image Optimize",
        ]
        lines += plan.map { "\($0.code)   \($0.imageOptimizeOn ? "ON" : "OFF")" }
        lines += ["", "Do not open the KEY folder before the scans are done.", ""]
        return lines.joined(separator: "\n")
    }

    // MARK: Scanner check

    func setScannerProfile(_ url: URL?) {
        data.scannerProfileName = url?.lastPathComponent
        data.scannerProfileBookmark = url.flatMap { try? Bookmarks.make($0) }
        data.scannerCheck = nil
        for code in data.scans.keys { data.scans[code]?.result = nil }
    }

    private func scannerICC() -> Data? {
        try? Bookmarks.withAccess(data.scannerProfileBookmark) { try Data(contentsOf: $0) }
    }

    func setColorCheckerScan(_ url: URL) {
        data.colorCheckerScanName = url.lastPathComponent
        data.colorCheckerScanBookmark = try? Bookmarks.make(url)
        data.corners = []
        data.scannerCheck = nil
    }

    func loadColorCheckerScan() async -> ScanImage? {
        guard let bookmark = data.colorCheckerScanBookmark else { return nil }
        let loaded: ScanImage? = await Task.detached(priority: .userInitiated) { () -> ScanImage? in
            guard let image = try? Bookmarks.withAccess(bookmark, { try ScanImage.load($0) }) else { return nil }
            return image
        }.value
        return loaded
    }

    func runScannerCheck(scan: ScanImage) async {
        guard data.corners.count == 4 else { return }
        busy = tr("Measuring the ColorChecker…")
        defer { busy = nil }
        let corners = data.corners.map { CGPoint(x: $0[0], y: $0[1]) }
        let reference = data.reference
        let icc = scannerICC()
        do {
            data.scannerCheck = try await Task.detached(priority: .userInitiated) {
                try ScannerCheck.check(scan, corners: corners, reference: reference, scannerICC: icc)
            }.value
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Chart scans

    func setScan(_ url: URL, code: String) {
        guard let bookmark = try? Bookmarks.make(url) else { return }
        data.scans[code] = ScanEntry(name: url.lastPathComponent, bookmark: bookmark)
    }

    /// Picks up the scans named after their code (P05.tif, P05-scan.tiff, ...) in a folder.
    func matchScans(in folder: URL) -> Int {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var matched = 0
        for item in data.plan where item.chartVariant != nil {
            if let file = files.first(where: { ["tif", "tiff"].contains($0.pathExtension.lowercased()) && Self.name($0, matches: item.code) }) {
                setScan(file, code: item.code)
                matched += 1
            }
        }
        return matched
    }

    /// "P05.tif", "P05 scan.tif", "p05-600dpi.tiff" match P05; "P050.tif" does not.
    nonisolated static func name(_ url: URL, matches code: String) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent.uppercased()
        let code = code.uppercased()
        guard stem.hasPrefix(code) else { return false }
        guard let next = stem.dropFirst(code.count).first else { return true }
        return !next.isNumber
    }

    func analyseScans() async {
        let items = data.plan.filter { $0.chartVariant != nil && data.scans[$0.code] != nil }
        guard !items.isEmpty else { return }
        let icc = scannerICC()
        for (index, item) in items.enumerated() {
            busy = trf("Analysing scan %d of %d…", index + 1, items.count)
            guard var entry = data.scans[item.code], let variant = item.chartVariant else { continue }
            let bookmark = entry.bookmark
            let name = entry.name
            do {
                let result: ChartScanResult? = try await Task.detached(priority: .userInitiated) {
                    try Bookmarks.withAccess(bookmark) { url in
                        try ChartScanAnalysis.analyse(try ScanImage.load(url), scannerICC: icc, label: variant.rawValue, scanName: name)
                    }
                }.value
                entry.result = result
                entry.error = result == nil ? tr("The scan file can no longer be opened: choose it again.") : nil
            } catch {
                entry.result = nil
                entry.error = error.localizedDescription
            }
            data.scans[item.code] = entry
        }
        busy = nil
        await updateReport()
    }

    // MARK: Report

    func updateReport() async {
        let results = data.chartResults
        if !results.isEmpty, let printer = try? printerProfile() {
            var models: [ChartVariant: ScanSummary] = [:]
            for variant in results.keys {
                models[variant] = try? ValidationReport.modelSummary(printerICC: printer, variant: variant)
            }
            self.models = models
        }
        report = ValidationReport.markdown(results: results, models: models, scannerCheck: data.scannerCheck,
                                           visual: data.visual.filter { $0.choice != .notJudged || !$0.notes.isEmpty },
                                           record: data.record)
    }

    /// REPORT.md and the per-variant results in the Python tools' format.
    func exportReport(to folder: URL) async {
        await updateReport()
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        do {
            let target = uniqueFolder(in: folder, name: "SELPHY validation results")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try report.write(to: target.appendingPathComponent("REPORT.md"), atomically: true, encoding: .utf8)
            for (variant, result) in data.chartResults {
                try ValidationReport.pythonJSON(result).write(to: target.appendingPathComponent("results_\(variant.rawValue).json"))
                try ValidationReport.csv(result).write(to: target.appendingPathComponent("results_\(variant.rawValue).csv"), atomically: true, encoding: .utf8)
            }
            if let check = data.scannerCheck {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(check).write(to: target.appendingPathComponent("scanner_check.json"))
            }
            if !data.plan.isEmpty {
                try ValidationPlan.keyCSV(data.plan).write(to: target.appendingPathComponent("run-plan.csv"), atomically: true, encoding: .utf8)
            }
            message = trf("Report written to %@.", target.lastPathComponent)
            errorMessage = nil
            NSWorkspace.shared.activateFileViewerSelecting([target.appendingPathComponent("REPORT.md")])
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
