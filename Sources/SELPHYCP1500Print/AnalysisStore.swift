import Foundation
import Observation
import Synchronization

/// The photos of the main window and the one shown in its preview, shared with the Statistics
/// window: the main window publishes them, and choosing a photo in the statistics selects it in the
/// main window too.
@MainActor
@Observable
final class PhotoSelection {
    var photos: [URL] = []
    var selected: URL?
}

/// Results of the quick analysis (statistics row and intent result), kept for the whole session so
/// that reopening the Statistics window, or going back to a photo, does not compute them again.
/// One entry per photo file (path and modification date), rendering intent, BPC and printer
/// profile (content digest). Only the small results are kept, not the per-pixel maps.
///
/// Thread-safe: the dictionary is guarded by a mutex, the analysis runs outside it.
final class AnalysisStore: Sendable {
    static let shared = AnalysisStore()

    struct Entry: Equatable, Sendable {
        let row: PhotoAnalysisRow
        /// nil when the photo could not be analysed (the row then carries the error).
        let result: IntentResult?
    }

    private struct Key: Hashable {
        let path: String
        let modified: Date?
        let intent: RenderingIntent
        let blackPointCompensation: Bool
        let profile: Data
    }

    /// Beyond this many entries the store starts again from empty (each entry is a few hundred bytes).
    static let capacity = 3000

    private struct State {
        var storage: [Key: Entry] = [:]
        var analysedPhotos = 0
    }

    private let state = Mutex(State())

    /// How many times a photo was decoded and analysed (tests and diagnostics).
    var analysedPhotos: Int { locked { $0.analysedPhotos } }

    init() {}

    func removeAll() { locked { $0.storage.removeAll() } }

    private func locked<T: Sendable>(_ body: (inout State) -> T) -> T {
        state.withLock { body(&$0) }
    }

    /// The results of `url` for each of `intents`, in that order. Missing results are computed
    /// together, decoding the photo once. Failures are returned (as rows with an error) but not
    /// kept, so that a later call tries again.
    func entries(
        url: URL, printerICC: Data, profileDigest: Data, intents: [RenderingIntent], blackPointCompensation: Bool
    ) -> [Entry] {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        // From the file system: a URL object caches resource values.
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let keys = intents.map {
            Key(path: url.path, modified: modified, intent: $0, blackPointCompensation: blackPointCompensation, profile: profileDigest)
        }
        var found = locked { state in keys.map { state.storage[$0] } }
        let missing = intents.indices.filter { found[$0] == nil }
        guard !missing.isEmpty else { return found.map { $0! } }

        let missingIntents = missing.map { intents[$0] }
        do {
            let analyses = try PreviewSession().quickAnalyses(
                sourceURL: url, printerICC: printerICC, intents: missingIntents,
                blackPointCompensation: blackPointCompensation
            )
            var computed: [(Key, Entry)] = []
            for (index, analysis) in zip(missing, analyses) {
                let entry = Entry(row: PhotoAnalysisRow.make(url: url, analysis: analysis),
                                  result: PhotoAnalysisRow.result(for: analysis, intent: intents[index]))
                found[index] = entry
                computed.append((keys[index], entry))
            }
            locked { state in
                state.analysedPhotos += 1
                if state.storage.count + computed.count > Self.capacity { state.storage.removeAll() }
                for (key, entry) in computed { state.storage[key] = entry }
            }
        } catch {
            let failed = Entry(row: PhotoAnalysisRow(url: url, error: error.localizedDescription), result: nil)
            for index in missing { found[index] = failed }
        }
        return found.map { $0! }
    }
}
