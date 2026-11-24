import XCTest
@testable import SELPHYCP1500Print

@MainActor
final class StatisticsTests: XCTestCase {
    /// 10 pixels: dE 0...9, intended L* 5 (x3), 50 (x4), 90 (x3).
    private func makeMaps() -> PixelMaps {
        let l: [Float] = [5, 5, 5, 50, 50, 50, 50, 90, 90, 90]
        var intended: [Float] = []
        for value in l { intended += [value, 0, 0] }
        return PixelMaps(width: 5, height: 2, deltaE: (0..<10).map { Float($0) },
                         intendedLab: intended, predictedLab: intended)
    }

    func testPercentilesUseTheNearestRank() {
        let sorted: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        XCTAssertEqual(DeviationStatistics.percentile(sorted: sorted, 0.5), 5)
        XCTAssertEqual(DeviationStatistics.percentile(sorted: sorted, 0.95), 10)
        XCTAssertEqual(DeviationStatistics.percentile(sorted: sorted, 0.1), 1)
        XCTAssertEqual(DeviationStatistics.percentile(sorted: [], 0.5), 0)
    }

    func testOverallFigures() {
        let s = DeviationStatistics.compute(makeMaps())
        XCTAssertEqual(s.pixelCount, 10)
        XCTAssertEqual(s.mean, 4.5, accuracy: 1e-9)
        XCTAssertEqual(s.median, 4)
        XCTAssertEqual(s.max, 9)
        XCTAssertEqual(s.p95, 9)
        // thresholds 1, 2, 3, 6: pixels above are 8, 7, 6, 3 of 10
        XCTAssertEqual(s.shareAbove, [0.8, 0.7, 0.6, 0.3])
    }

    func testHistogramSharesSumToOneAndTheLastBinCollectsTheTail() {
        let maps = PixelMaps(width: 3, height: 1, deltaE: [0.1, 5, 40], intendedLab: [50, 0, 0, 50, 0, 0, 50, 0, 0],
                             predictedLab: [50, 0, 0, 50, 0, 0, 50, 0, 0])
        let s = DeviationStatistics.compute(maps, histogramMax: 12, bins: 24)
        XCTAssertEqual(s.histogram.count, 24)
        XCTAssertEqual(s.histogram.reduce(0) { $0 + $1.share }, 1, accuracy: 1e-9)
        XCTAssertEqual(s.histogram[0].share, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(s.histogram[23].share, 1.0 / 3, accuracy: 1e-9, "everything above the range lands in the last bin")
        XCTAssertEqual(s.histogram[0].upper, 0.5, accuracy: 1e-6)
    }

    func testZonesSplitByIntendedLightness() throws {
        let s = DeviationStatistics.compute(makeMaps())
        XCTAssertEqual(s.zones.map(\.zone), [.shadows, .midtones, .highlights])
        XCTAssertEqual(s.zones[0].share, 0.3, accuracy: 1e-9)
        XCTAssertEqual(s.zones[1].share, 0.4, accuracy: 1e-9)
        XCTAssertEqual(s.zones[2].share, 0.3, accuracy: 1e-9)
        XCTAssertEqual(s.zones[0].mean, 1, accuracy: 1e-9)       // dE 0, 1, 2
        XCTAssertEqual(s.zones[1].mean, 4.5, accuracy: 1e-9)     // dE 3, 4, 5, 6
        XCTAssertEqual(s.zones[2].mean, 8, accuracy: 1e-9)       // dE 7, 8, 9
        XCTAssertEqual(s.zones[1].shareAbove, 0.75, accuracy: 1e-9, "4, 5, 6 are above 3")
        XCTAssertEqual(LightnessZone.zone(forL: 29.9), .shadows)
        XCTAssertEqual(LightnessZone.zone(forL: 30), .midtones)
        XCTAssertEqual(LightnessZone.zone(forL: 70), .highlights)
    }

    func testNonFiniteAndEmptyInputsDoNotBreakTheStatistics() {
        let maps = PixelMaps(width: 2, height: 1, deltaE: [.nan, 2], intendedLab: [50, 0, 0, 50, 0, 0], predictedLab: [50, 0, 0, 50, 0, 0])
        XCTAssertEqual(DeviationStatistics.compute(maps).pixelCount, 1)
        let empty = PixelMaps(width: 0, height: 0, deltaE: [], intendedLab: [], predictedLab: [])
        let s = DeviationStatistics.compute(empty)
        XCTAssertEqual(s.pixelCount, 0)
        XCTAssertEqual(s.mean, 0)
    }

    // MARK: Intents

    private func result(_ intent: RenderingIntent, mean: Double, p95: Double = 5, shadows: Double = 0.1) -> IntentResult {
        IntentResult(intent: intent, meanDeltaE: mean, p95DeltaE: p95, shareNotReproducible: 0.2, shareBelowDarkest: shadows, gamutLossShare: 0.1)
    }

    func testTheLowestMeanDeviationIsSuggested() throws {
        let results = [result(.perceptual, mean: 4.9), result(.relativeColorimetric, mean: 3.0), result(.saturation, mean: 6)]
        XCTAssertEqual(IntentAdvisor.best(results)?.intent, .relativeColorimetric)
        XCTAssertNil(IntentAdvisor.best([]))
        let tie = [result(.perceptual, mean: 3), result(.saturation, mean: 3)]
        XCTAssertEqual(IntentAdvisor.best(tie)?.intent, .perceptual, "a tie keeps the first")
    }

    func testExplanationMentionsCloseResultsAndLostShadows() throws {
        Localizer.shared.language = .english
        let close = [result(.perceptual, mean: 3.1), result(.relativeColorimetric, mean: 3.0)]
        let best = try XCTUnwrap(IntentAdvisor.best(close))
        let text = IntentAdvisor.explanation(for: best, among: close)
        XCTAssertTrue(text.contains("Relative colorimetric"))
        XCTAssertTrue(text.contains("close"))
        let shadowy = [result(.perceptual, mean: 5, shadows: 0.02), result(.relativeColorimetric, mean: 3, shadows: 0.3)]
        let text2 = IntentAdvisor.explanation(for: try XCTUnwrap(IntentAdvisor.best(shadowy)), among: shadowy)
        XCTAssertTrue(text2.contains("merges more shadows"))
    }

    // MARK: Export

    func testCSVEscapingAndFormat() {
        XCTAssertEqual(AnalysisExport.escapeCSV("plain.jpg"), "plain.jpg")
        XCTAssertEqual(AnalysisExport.escapeCSV("a,b.jpg"), "\"a,b.jpg\"")
        XCTAssertEqual(AnalysisExport.escapeCSV("say \"hi\".jpg"), "\"say \"\"hi\"\".jpg\"")
        var row = PhotoAnalysisRow(url: URL(fileURLWithPath: "/tmp/a,b.jpg"), statistics: DeviationStatistics.compute(makeMaps()))
        row.shareNotReproducible = 0.25
        row.shareBelowDarkest = 0.1
        row.gamutLossShare = 0.05
        row.darkestToneL = 12.34
        let failed = PhotoAnalysisRow(url: URL(fileURLWithPath: "/tmp/bad.jpg"), error: "x")
        let text = AnalysisExport.csv(rows: [row, failed], intent: .perceptual, blackPointCompensation: true)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].split(separator: ",").count, AnalysisExport.csvHeader.count)
        XCTAssertEqual(lines[1], "\"a,b.jpg\",perceptual,yes,4.50,4.00,9.00,9.00,25.0,10.0,5.0,12.3")
        XCTAssertEqual(lines[2].components(separatedBy: ",").count, AnalysisExport.csvHeader.count, "a failed photo keeps the column count")
    }

    func testPDFReportIsAValidPDF() throws {
        Localizer.shared.language = .english
        let row = PhotoAnalysisRow(url: URL(fileURLWithPath: "/tmp/a.jpg"), statistics: DeviationStatistics.compute(makeMaps()))
        let data = try XCTUnwrap(AnalysisExport.pdf(
            rows: [row, PhotoAnalysisRow(url: URL(fileURLWithPath: "/tmp/b.jpg"), error: "no")],
            intent: .perceptual, intentPhoto: "a.jpg",
            intentResults: [result(.perceptual, mean: 4), result(.relativeColorimetric, mean: 3), result(.saturation, mean: 6)]))
        XCTAssertEqual(String(decoding: data.prefix(5), as: UTF8.self), "%PDF-")
        XCTAssertGreaterThan(data.count, 1000)
        let many = (0..<120).map { PhotoAnalysisRow(url: URL(fileURLWithPath: "/tmp/p\($0).jpg"), statistics: DeviationStatistics.compute(makeMaps())) }
        XCTAssertNotNil(AnalysisExport.pdf(rows: many, intent: .perceptual, intentPhoto: nil, intentResults: []), "many rows paginate")
    }
}
