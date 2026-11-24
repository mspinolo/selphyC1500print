import Foundation

/// Predicted result of one rendering intent for one photo.
struct IntentResult: Equatable, Identifiable {
    var intent: RenderingIntent
    var meanDeltaE: Double
    var p95DeltaE: Double
    var shareNotReproducible: Double
    var shareBelowDarkest: Double
    var gamutLossShare: Double

    var id: String { intent.rawValue }
}

enum IntentAdvisor {
    /// The intent with the lowest mean dE00; on a tie the first one in the list.
    static func best(_ results: [IntentResult]) -> IntentResult? {
        var best: IntentResult?
        for result in results where best == nil || result.meanDeltaE < best!.meanDeltaE {
            best = result
        }
        return best
    }

    /// One or two sentences saying why `best` is suggested, with the caveats the numbers show.
    static func explanation(for best: IntentResult, among results: [IntentResult]) -> String {
        let others = results.filter { $0.intent != best.intent }
        var text = trf("Lowest predicted deviation: %@ (mean ΔE00 %.1f, 95th percentile %.1f).",
                       best.intent.title, best.meanDeltaE, best.p95DeltaE)
        if let nextBest = others.map(\.meanDeltaE).min(), nextBest - best.meanDeltaE < 0.3 {
            text += " " + tr("The intents are close for this photo: the choice matters little.")
        }
        if let fewestLost = others.map(\.shareBelowDarkest).min(), best.shareBelowDarkest > fewestLost + 0.05 {
            text += " " + tr("It merges more shadows than the alternatives: check the Dark zones view.")
        }
        return text
    }
}

/// One photo's row of the analysis table.
struct PhotoAnalysisRow: Identifiable, Equatable {
    /// Gamut-loss threshold (C*) behind the "dull colours" share.
    static let gamutLossThreshold: Float = 8

    let url: URL
    var statistics: DeviationStatistics?
    var darkestToneL = 0.0
    var shareNotReproducible = 0.0
    var shareBelowDarkest = 0.0
    var gamutLossShare = 0.0
    var error: String?

    var id: URL { url }
    var name: String { url.lastPathComponent }

    init(url: URL, statistics: DeviationStatistics? = nil, error: String? = nil) {
        self.url = url
        self.statistics = statistics
        self.error = error
    }

    static func make(url: URL, analysis: PreviewSession.QuickAnalysis) -> PhotoAnalysisRow {
        var row = PhotoAnalysisRow(url: url, statistics: DeviationStatistics.compute(analysis.maps))
        row.darkestToneL = analysis.stats.darkestToneL
        row.shareNotReproducible = analysis.stats.shareNotReproducible
        row.shareBelowDarkest = analysis.stats.shareBelowDarkestTone
        row.gamutLossShare = Overlays.gamutShare(analysis.maps, minimumLoss: gamutLossThreshold)
        return row
    }

    static func result(for analysis: PreviewSession.QuickAnalysis, intent: RenderingIntent) -> IntentResult {
        IntentResult(
            intent: intent, meanDeltaE: analysis.stats.meanDeltaE, p95DeltaE: analysis.stats.p95DeltaE,
            shareNotReproducible: analysis.stats.shareNotReproducible,
            shareBelowDarkest: analysis.stats.shareBelowDarkestTone,
            gamutLossShare: Overlays.gamutShare(analysis.maps, minimumLoss: gamutLossThreshold)
        )
    }
}
