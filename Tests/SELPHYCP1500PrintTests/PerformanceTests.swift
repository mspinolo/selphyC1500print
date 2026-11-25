import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SELPHYColorCore
import XCTest
@testable import SELPHYCP1500Print

/// The 0.0.4 performance work: one Lab pass, analyses decoded once and kept, thumbnail cache,
/// content digests for cache keys, credits and licence in the bundle.
final class PerformanceTests: XCTestCase {
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func printerProfile() throws -> Data {
        guard let path = ProcessInfo.processInfo.environment["SELPHY_TEST_PRINTER_PROFILE"] else {
            throw XCTSkip("Set SELPHY_TEST_PRINTER_PROFILE to run real-profile tests.")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func makePhoto(width: Int = 640, height: Int = 420, hue: CGFloat = 0.6) throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: sRGB, colors: [
            NSColor(hue: hue, saturation: 0.9, brightness: 0.95, alpha: 1).cgColor,
            NSColor(hue: hue + 0.3, saturation: 0.4, brightness: 0.1, alpha: 1).cgColor] as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let image = try XCTUnwrap(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selphy-perf-\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    // MARK: Cache keys

    func testContentDigestSeesDifferencesBeyondTheHeader() {
        var a = Data(repeating: 7, count: 4096)
        var b = a
        b[4000] = 8
        XCTAssertNotEqual(ContentDigest.of(a), ContentDigest.of(b))
        a[4000] = 8
        XCTAssertEqual(ContentDigest.of(a), ContentDigest.of(b))
        XCTAssertEqual(ContentDigest.of(a).count, 32)
    }

    // MARK: Analysis

    func testOneDecodeForSeveralIntentsGivesTheSameResultsAsOneAtATime() throws {
        let profile = try printerProfile()
        let url = try makePhoto()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = PreviewSession()
        let together = try session.quickAnalyses(sourceURL: url, printerICC: profile, intents: RenderingIntent.allCases,
                                                 blackPointCompensation: false)
        XCTAssertEqual(together.count, RenderingIntent.allCases.count)
        for (intent, analysis) in zip(RenderingIntent.allCases, together) {
            let alone = try session.quickAnalysis(sourceURL: url, printerICC: profile, intent: intent, blackPointCompensation: false)
            XCTAssertEqual(analysis.stats, alone.stats, "\(intent)")
            XCTAssertEqual(analysis.maps.deltaE, alone.maps.deltaE, "\(intent)")
            XCTAssertEqual(analysis.maps.intendedLab, alone.maps.intendedLab, "\(intent)")
            XCTAssertEqual(analysis.maps.predictedLab, alone.maps.predictedLab, "\(intent)")
        }
    }

    func testLabMapsAgreeWithTheDeltaEMap() throws {
        let profile = try printerProfile()
        let url = try makePhoto()
        defer { try? FileManager.default.removeItem(at: url) }
        let analysis = try PreviewSession().quickAnalysis(sourceURL: url, printerICC: profile, intent: .perceptual,
                                                          blackPointCompensation: false)
        let maps = analysis.maps
        XCTAssertEqual(maps.intendedLab.count, maps.count * 3)
        XCTAssertEqual(maps.predictedLab.count, maps.count * 3)
        for index in stride(from: 0, to: maps.count, by: max(1, maps.count / 200)) {
            let i = maps.intended(at: index), p = maps.predicted(at: index)
            let de = selphy_delta_e2000([Double(i.l), Double(i.a), Double(i.b)], [Double(p.l), Double(p.a), Double(p.b)])
            XCTAssertEqual(de, Double(maps.deltaE[index]), accuracy: 1e-3, "pixel \(index)")
        }
    }

    func testAnalysisStoreKeepsResultsAndRecomputesOnlyWhatIsMissing() throws {
        let profile = try printerProfile()
        let digest = ContentDigest.of(profile)
        let url = try makePhoto()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AnalysisStore()

        let first = store.entries(url: url, printerICC: profile, profileDigest: digest, intents: [.perceptual],
                                  blackPointCompensation: false)
        XCTAssertNil(first[0].row.error)
        XCTAssertNotNil(first[0].result)
        XCTAssertEqual(store.analysedPhotos, 1)

        let again = store.entries(url: url, printerICC: profile, profileDigest: digest, intents: [.perceptual],
                                  blackPointCompensation: false)
        XCTAssertEqual(again, first)
        XCTAssertEqual(store.analysedPhotos, 1, "a kept result must not be computed again")

        // The other two intents are computed together (one more decode), the first one is reused.
        let all = store.entries(url: url, printerICC: profile, profileDigest: digest, intents: RenderingIntent.allCases,
                                blackPointCompensation: false)
        XCTAssertEqual(all.map { $0.result?.intent }, RenderingIntent.allCases.map { Optional($0) })
        XCTAssertEqual(all[0], first[0])
        XCTAssertEqual(store.analysedPhotos, 2)

        // Another BPC choice or another profile is another result.
        _ = store.entries(url: url, printerICC: profile, profileDigest: digest, intents: [.relativeColorimetric],
                          blackPointCompensation: true)
        XCTAssertEqual(store.analysedPhotos, 3)

        // An edited file is analysed again.
        let later = Date().addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
        _ = store.entries(url: url, printerICC: profile, profileDigest: digest, intents: [.perceptual],
                          blackPointCompensation: false)
        XCTAssertEqual(store.analysedPhotos, 4)
    }

    func testAnalysisStoreDoesNotKeepFailures() throws {
        let profile = try printerProfile()
        let digest = ContentDigest.of(profile)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("selphy-missing-\(UUID().uuidString).png")
        let store = AnalysisStore()
        let entries = store.entries(url: missing, printerICC: profile, profileDigest: digest, intents: [.perceptual, .saturation],
                                    blackPointCompensation: false)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.row.error != nil && $0.result == nil })
        XCTAssertEqual(store.analysedPhotos, 0)
    }

    @MainActor
    func testStatisticsModelLoadsEveryPhotoInOrder() async throws {
        let profile = try printerProfile()
        let photos = try (0..<5).map { try makePhoto(width: 300, height: 200, hue: CGFloat($0) / 5) }
        defer { photos.forEach { try? FileManager.default.removeItem(at: $0) } }
        let store = AnalysisStore()
        let model = StatisticsModel(store: store)
        await model.loadRows(photos: photos, printerICC: profile, profileDigest: ContentDigest.of(profile),
                             intent: .perceptual, blackPointCompensation: false)
        XCTAssertEqual(model.rows.map(\.url), photos)
        XCTAssertEqual(model.done, photos.count)
        XCTAssertTrue(model.rows.allSatisfy { $0.statistics != nil })
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(store.analysedPhotos, photos.count)

        // Opening the statistics again reuses everything.
        await model.loadRows(photos: photos, printerICC: profile, profileDigest: ContentDigest.of(profile),
                             intent: .perceptual, blackPointCompensation: false)
        XCTAssertEqual(store.analysedPhotos, photos.count)
        XCTAssertEqual(model.rows.count, photos.count)

        await model.loadIntents(photo: photos[2], printerICC: profile, profileDigest: ContentDigest.of(profile),
                                blackPointCompensation: false)
        XCTAssertEqual(model.intentResults.map(\.intent), RenderingIntent.allCases)
    }

    // MARK: Table, histogram bands

    func testSortKeysPutRowsWithoutStatisticsLast() {
        var good = PhotoAnalysisRow(url: URL(fileURLWithPath: "/tmp/b.png"), statistics: DeviationStatistics(
            pixelCount: 1, mean: 2, median: 2, p95: 3, p99: 3, max: 4, thresholds: [], shareAbove: [], histogram: [], zones: []))
        good.shareNotReproducible = 0.2
        let failed = PhotoAnalysisRow(url: URL(fileURLWithPath: "/tmp/a.png"), error: "x")
        let rows = [failed, good].sorted(using: KeyPathComparator(\PhotoAnalysisRow.sortMean, order: .reverse))
        XCTAssertEqual(rows.map(\.name), ["b.png", "a.png"])
        XCTAssertEqual(good.sortNotReproducible, 0.2)
        XCTAssertEqual(failed.sortNotReproducible, -1)
        XCTAssertEqual([good, failed].sorted(using: KeyPathComparator(\PhotoAnalysisRow.name)).map(\.name), ["a.png", "b.png"])
    }

    func testHistogramBandsFollowTheDeviationMapScale() {
        XCTAssertEqual(DeviationBand.band(forLower: 0), .belowOne)
        XCTAssertEqual(DeviationBand.band(forLower: 0.5), .belowOne)
        XCTAssertEqual(DeviationBand.band(forLower: 1), .oneToThree)
        XCTAssertEqual(DeviationBand.band(forLower: 2.5), .oneToThree)
        XCTAssertEqual(DeviationBand.band(forLower: 3), .threeToSix)
        XCTAssertEqual(DeviationBand.band(forLower: 5.5), .threeToSix)
        XCTAssertEqual(DeviationBand.band(forLower: 6), .sixAndAbove)
        XCTAssertEqual(DeviationBand.band(forLower: 11.5), .sixAndAbove)
        XCTAssertEqual(Set(DeviationBand.allCases.map(\.title)).count, DeviationBand.allCases.count)
    }

    // MARK: Thumbnails

    func testThumbnailCacheReturnsTheSameImageUntilTheFileChanges() throws {
        let url = try makePhoto()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = ThumbnailCache()
        let first = try XCTUnwrap(cache.thumbnail(url: url, maxPixel: 120))
        let second = try XCTUnwrap(cache.thumbnail(url: url, maxPixel: 120))
        XCTAssertTrue(first === second, "the second request must come from the cache")
        let bigger = try XCTUnwrap(cache.thumbnail(url: url, maxPixel: 240))
        XCTAssertFalse(bigger === first)

        let keyBefore = ThumbnailCache.key(url: url, maxPixel: 120)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        XCTAssertNotEqual(ThumbnailCache.key(url: url, maxPixel: 120), keyBefore)
        let edited = try XCTUnwrap(cache.thumbnail(url: url, maxPixel: 120))
        XCTAssertFalse(edited === first)
    }

    // MARK: Credits and licence

    func testCreditsCarryTheFullLittleCMSLicence() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let credits = try NSAttributedString(
            url: root.appendingPathComponent("Packaging/Credits.rtf"), options: [:], documentAttributes: nil).string
        let licence = try String(contentsOf: root.appendingPathComponent("Sources/CLittleCMS/LICENSE"), encoding: .utf8)
        func normalised(_ text: String) -> String {
            text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let creditsText = normalised(credits)
        for paragraph in licence.components(separatedBy: "\n\n").dropFirst() where !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            XCTAssertTrue(creditsText.contains(normalised(paragraph)), "missing in the credits: \(paragraph.prefix(60))…")
        }
        let script = try String(contentsOf: root.appendingPathComponent("scripts/make-app.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("Credits.rtf"))
        XCTAssertTrue(script.contains("LittleCMS-LICENSE.txt"))
    }
}
