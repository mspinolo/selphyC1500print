import Foundation
import CoreGraphics
import CryptoKit

/// A content digest for cache keys. `Data.hashValue` is not enough: it only looks at the length
/// and the first 80 bytes, which two different ICC profiles (same header) can share.
enum ContentDigest {
    static func of(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
}

/// Keeps the expensive stages of the preview in memory, so that changing a display option
/// (paper white, black stretch) or switching back to a photo does not repeat the decoding, the
/// correction and the checks.
///
/// Three levels, from the most to the least expensive:
/// - correction stage, per (photo, rendering intent, BPC, printer profile): decoded and corrected
///   buffers, the checks and the dE map;
/// - preview transform, per (printer profile, display profile, paper-white and black options);
/// - render stage: the two expected-print images, per correction stage and transform.
///
/// Thread-safe: the caches are guarded by a lock, the heavy work runs outside it (two callers
/// asking for the same missing stage at once may both compute it; the result is the same).
final class PreviewSession: @unchecked Sendable {
    /// Counters for tests and diagnostics.
    struct Counters: Equatable {
        var corrections = 0
        var transforms = 0
        var renders = 0
    }

    private struct CorrectionKey: Hashable {
        let path: String
        let modified: Date?
        let intent: RenderingIntent
        let blackPointCompensation: Bool
        let maxDimension: Int
        let printerProfile: Data
    }

    private struct TransformKey: Hashable {
        let printerProfile: Data
        let displayProfile: Data?
        let simulatePaperWhite: Bool
        let blackPointCompensation: Bool
    }

    private struct RenderKey: Hashable {
        let correction: CorrectionKey
        let transform: TransformKey
    }

    private final class CorrectionStage {
        let width: Int
        let height: Int
        let correctedDevice: Data
        let sRGBDevice: Data
        let original: CGImage
        let analysis: PreviewService.Analysis
        let heatMap: CGImage
        let sourceDescription: String
        let effectiveBlackPointCompensation: Bool

        init(width: Int, height: Int, correctedDevice: Data, sRGBDevice: Data, original: CGImage,
             analysis: PreviewService.Analysis, heatMap: CGImage, sourceDescription: String,
             effectiveBlackPointCompensation: Bool) {
            self.width = width
            self.height = height
            self.correctedDevice = correctedDevice
            self.sRGBDevice = sRGBDevice
            self.original = original
            self.analysis = analysis
            self.heatMap = heatMap
            self.sourceDescription = sourceDescription
            self.effectiveBlackPointCompensation = effectiveBlackPointCompensation
        }
    }

    private struct TransformStage {
        let transform: PreviewService.PreviewTransform
        let usedSRGBFallback: Bool
        let imageSpace: CGColorSpace
        let displayName: String
    }

    private struct RenderStage {
        let uncorrected: CGImage
        let corrected: CGImage
        /// Share of corrected pixels outside the display gamut, from a reduced sample.
        let outOfGamutFraction: Double
    }

    /// Small least-recently-used cache.
    private struct LRU<Key: Hashable, Value> {
        let capacity: Int
        private var entries: [(key: Key, value: Value)] = []

        init(capacity: Int) { self.capacity = capacity }

        mutating func value(for key: Key) -> Value? {
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
            let entry = entries.remove(at: index)
            entries.insert(entry, at: 0)
            return entry.value
        }

        mutating func insert(_ value: Value, for key: Key) {
            entries.removeAll { $0.key == key }
            entries.insert((key, value), at: 0)
            if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        }

        mutating func removeAll() { entries.removeAll() }
    }

    private let lock = NSLock()
    private var corrections: LRU<CorrectionKey, CorrectionStage>
    private var transforms: LRU<TransformKey, TransformStage>
    private var renders: LRU<RenderKey, RenderStage>
    private var _counters = Counters()
    private var _timings: [String: Double] = [:]

    var counters: Counters { locked { _counters } }
    /// Seconds spent in each stage the last time it was computed.
    var timings: [String: Double] { locked { _timings } }

    /// The session of the interactive preview (reduced size), shared by the preview panel and
    /// the full-screen view.
    static let shared = PreviewSession()

    /// Capacities in entries; a full-resolution session keeps fewer (each entry can be hundreds of MB).
    init(corrections: Int = 3, transforms: Int = 6, renders: Int = 8) {
        self.corrections = LRU(capacity: corrections)
        self.transforms = LRU(capacity: transforms)
        self.renders = LRU(capacity: renders)
    }

    /// Drops everything (e.g. when the printer profile is replaced and memory should be freed).
    func removeAll() {
        locked {
            corrections.removeAll()
            transforms.removeAll()
            renders.removeAll()
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = Date()
        let result = try body()
        let elapsed = Date().timeIntervalSince(start)
        locked { _timings[name] = elapsed }
        return result
    }

    func makePreview(
        sourceURL: URL,
        printerICC: Data,
        display: PreviewService.Display?,
        options: PreviewService.Options
    ) throws -> PreviewService.Preview {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        // Read the date from the file system: a URL object caches resource values, which would
        // hide a file that was edited elsewhere after the first read.
        let modified = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path))?[.modificationDate] as? Date
        let printerHash = ContentDigest.of(printerICC)
        let correctionKey = CorrectionKey(
            path: sourceURL.path, modified: modified, intent: options.intent,
            blackPointCompensation: options.blackPointCompensation,
            maxDimension: options.maxDimension, printerProfile: printerHash
        )
        let transformKey = TransformKey(
            printerProfile: printerHash, displayProfile: display.map { ContentDigest.of($0.iccData) },
            simulatePaperWhite: options.simulatePaperWhite,
            blackPointCompensation: options.previewBlackPointCompensation
        )

        let correction: CorrectionStage
        if let cached = locked({ corrections.value(for: correctionKey) }) {
            correction = cached
        } else {
            correction = try timed("correction") {
                try computeCorrection(sourceURL: sourceURL, printerICC: printerICC, options: options)
            }
            locked {
                _counters.corrections += 1
                corrections.insert(correction, for: correctionKey)
            }
        }

        let transform: TransformStage
        if let cached = locked({ transforms.value(for: transformKey) }) {
            transform = cached
        } else {
            transform = try timed("transform") {
                try computeTransform(printerICC: printerICC, display: display, options: options)
            }
            locked {
                _counters.transforms += 1
                transforms.insert(transform, for: transformKey)
            }
        }

        let renderKey = RenderKey(correction: correctionKey, transform: transformKey)
        let render: RenderStage
        if let cached = locked({ renders.value(for: renderKey) }) {
            render = cached
        } else {
            render = try timed("render") {
                try computeRender(correction: correction, transform: transform)
            }
            locked {
                _counters.renders += 1
                renders.insert(render, for: renderKey)
            }
        }

        return PreviewService.Preview(
            original: correction.original,
            uncorrected: render.uncorrected,
            corrected: render.corrected,
            outOfGamutFraction: render.outOfGamutFraction,
            usedSRGBFallback: transform.usedSRGBFallback,
            effectiveBlackPointCompensation: correction.effectiveBlackPointCompensation,
            stats: correction.analysis.stats,
            heatMap: correction.heatMap,
            sourceDescription: correction.sourceDescription,
            displayName: transform.displayName,
            maps: correction.analysis.maps
        )
    }

    /// Result of a quick analysis: the checks and the per-pixel maps of a reduced copy.
    struct QuickAnalysis {
        let stats: PreviewService.PhotoStats
        let maps: PixelMaps
        let effectiveBlackPointCompensation: Bool
    }

    /// Analyses a photo on a reduced copy (analysis resolution) without touching the caches, for
    /// the statistics table and the rendering-intent comparison.
    func quickAnalysis(
        sourceURL: URL, printerICC: Data, intent: RenderingIntent, blackPointCompensation: Bool
    ) throws -> QuickAnalysis {
        try quickAnalyses(sourceURL: sourceURL, printerICC: printerICC, intents: [intent],
                          blackPointCompensation: blackPointCompensation)[0]
    }

    /// The same for several rendering intents, decoding the photo only once. Results are in the
    /// order of `intents`.
    func quickAnalyses(
        sourceURL: URL, printerICC: Data, intents: [RenderingIntent], blackPointCompensation: Bool
    ) throws -> [QuickAnalysis] {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let decoded = try decode(sourceURL: sourceURL, maxDimension: PreviewService.analysisDimension)
        return try intents.map { intent in
            let corrected = try correct(decoded, printerICC: printerICC, intent: intent,
                                        blackPointCompensation: blackPointCompensation)
            return QuickAnalysis(
                stats: corrected.analysis.stats, maps: corrected.analysis.maps,
                effectiveBlackPointCompensation: corrected.effectiveBlackPointCompensation
            )
        }
    }

    // MARK: - Stages

    /// A decoded, reduced photo and its uncorrected device values.
    private struct DecodedSource {
        let loaded: ColorCorrectionService.LoadedSource
        /// Oriented size.
        let width: Int
        let height: Int
        /// The photo as sRGB numbers (oriented 8-bit RGBX), as any application would hand it to the printer.
        let sRGBDevice: Data
    }

    private struct CorrectedSource {
        let correctedDevice: Data
        let analysis: PreviewService.Analysis
        let effectiveBlackPointCompensation: Bool
    }

    private func decode(sourceURL: URL, maxDimension: Int) throws -> DecodedSource {
        let loaded = try ColorCorrectionService.loadSource(from: sourceURL, maxDimension: maxDimension)
        let (width, height) = ColorCorrectionService.orientedSize(
            width: loaded.width, height: loaded.height, orientation: loaded.orientation
        )
        // Uncorrected device values. A source with its own profile is converted to sRGB first,
        // like at export; for a source that is already sRGB the decoded pixels are reused.
        let sRGBDevice: Data
        if loaded.embeddedICC == nil {
            sRGBDevice = try ColorCorrectionService.convertRGBX16Pixels(
                loaded.pixels, width: loaded.width, height: loaded.height,
                transform: nil, orientation: loaded.orientation
            )
        } else {
            let converted = try ColorCorrectionService.loadSource(
                from: sourceURL, maxDimension: maxDimension, forceSRGB: true
            )
            sRGBDevice = try ColorCorrectionService.convertRGBX16Pixels(
                converted.pixels, width: converted.width, height: converted.height,
                transform: nil, orientation: converted.orientation
            )
        }
        return DecodedSource(loaded: loaded, width: width, height: height, sRGBDevice: sRGBDevice)
    }

    private func correct(
        _ decoded: DecodedSource, printerICC: Data, intent: RenderingIntent, blackPointCompensation: Bool
    ) throws -> CorrectedSource {
        // Corrected device values: the same code path as the export, on a reduced copy.
        let loaded = decoded.loaded
        let correctionTransform = try ColorCorrectionService.ColorTransform(
            sourceICC: loaded.embeddedICC,
            printerICC: printerICC,
            intent: intent,
            blackPointCompensation: blackPointCompensation
        )
        let correctedDevice = try ColorCorrectionService.convertRGBX16Pixels(
            loaded.pixels, width: loaded.width, height: loaded.height,
            transform: correctionTransform, orientation: loaded.orientation
        )
        let analysis = try timed("analysis") {
            try PreviewService.analyse(
                printerICC: printerICC, srgbRGBX: decoded.sRGBDevice, deviceRGBX: correctedDevice,
                width: decoded.width, height: decoded.height,
                correctedBlack: PreviewService.correctedBlack(transform: correctionTransform)
            )
        }
        return CorrectedSource(
            correctedDevice: correctedDevice, analysis: analysis,
            effectiveBlackPointCompensation: correctionTransform.effectiveBlackPointCompensation
        )
    }

    private func computeCorrection(sourceURL: URL, printerICC: Data, options: PreviewService.Options) throws -> CorrectionStage {
        let decoded = try decode(sourceURL: sourceURL, maxDimension: options.maxDimension)
        let corrected = try correct(decoded, printerICC: printerICC, intent: options.intent,
                                    blackPointCompensation: options.blackPointCompensation)
        let analysis = corrected.analysis
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        return CorrectionStage(
            width: decoded.width, height: decoded.height,
            correctedDevice: corrected.correctedDevice, sRGBDevice: decoded.sRGBDevice,
            original: try ColorCorrectionService.makeImage(rgbx: decoded.sRGBDevice, width: decoded.width, height: decoded.height, colorSpace: sRGB),
            analysis: analysis,
            heatMap: try PreviewService.makeHeatMap(deltaE: analysis.deltaEMap, width: analysis.width, height: analysis.height),
            sourceDescription: PreviewService.describe(decoded.loaded),
            effectiveBlackPointCompensation: corrected.effectiveBlackPointCompensation
        )
    }

    private func computeTransform(printerICC: Data, display: PreviewService.Display?, options: PreviewService.Options) throws -> TransformStage {
        do {
            return TransformStage(
                transform: try PreviewService.PreviewTransform(
                    printerICC: printerICC, displayICC: display?.iccData,
                    simulatePaperWhite: options.simulatePaperWhite,
                    blackPointCompensation: options.previewBlackPointCompensation
                ),
                usedSRGBFallback: false,
                imageSpace: display?.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                displayName: display?.name ?? "sRGB"
            )
        } catch where display != nil {
            // The display profile parses but cannot be used (wrong class, no output tables...).
            return TransformStage(
                transform: try PreviewService.PreviewTransform(
                    printerICC: printerICC, displayICC: nil,
                    simulatePaperWhite: options.simulatePaperWhite,
                    blackPointCompensation: options.previewBlackPointCompensation
                ),
                usedSRGBFallback: true,
                imageSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                displayName: "sRGB"
            )
        }
    }

    private func computeRender(correction: CorrectionStage, transform: TransformStage) throws -> RenderStage {
        let corrected = transform.transform.render(
            rgbx: correction.correctedDevice, width: correction.width, height: correction.height, countOutOfGamut: false
        )
        let uncorrected = transform.transform.render(
            rgbx: correction.sRGBDevice, width: correction.width, height: correction.height, countOutOfGamut: false
        )
        let factor = max(1, (max(correction.width, correction.height) + PreviewService.analysisDimension - 1) / PreviewService.analysisDimension)
        let sample = PreviewService.sampledRGB(correction.correctedDevice, width: correction.width, height: correction.height, factor: factor)
        return RenderStage(
            uncorrected: try ColorCorrectionService.makeImage(
                rgbx: uncorrected.pixels, width: correction.width, height: correction.height, colorSpace: transform.imageSpace),
            corrected: try ColorCorrectionService.makeImage(
                rgbx: corrected.pixels, width: correction.width, height: correction.height, colorSpace: transform.imageSpace),
            outOfGamutFraction: transform.transform.outOfGamutFraction(packedRGB: sample.rgb)
        )
    }
}
