import Foundation
import CoreGraphics

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
        let printerProfile: Int
    }

    private struct TransformKey: Hashable {
        let printerProfile: Int
        let displayProfile: Int
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
    private var corrections = LRU<CorrectionKey, CorrectionStage>(capacity: 3)
    private var transforms = LRU<TransformKey, TransformStage>(capacity: 6)
    private var renders = LRU<RenderKey, RenderStage>(capacity: 8)
    private var _counters = Counters()
    private var _timings: [String: Double] = [:]

    var counters: Counters { locked { _counters } }
    /// Seconds spent in each stage the last time it was computed.
    var timings: [String: Double] { locked { _timings } }

    init() {}

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
        let printerHash = printerICC.hashValue
        let correctionKey = CorrectionKey(
            path: sourceURL.path, modified: modified, intent: options.intent,
            blackPointCompensation: options.blackPointCompensation,
            maxDimension: options.maxDimension, printerProfile: printerHash
        )
        let transformKey = TransformKey(
            printerProfile: printerHash, displayProfile: display?.iccData.hashValue ?? 0,
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

    // MARK: - Stages

    private func computeCorrection(sourceURL: URL, printerICC: Data, options: PreviewService.Options) throws -> CorrectionStage {
        // Corrected device values: the same code path as the export, on a reduced copy.
        let loaded = try ColorCorrectionService.loadSource(from: sourceURL, maxDimension: options.maxDimension)
        let correctionTransform = try ColorCorrectionService.ColorTransform(
            sourceICC: loaded.embeddedICC,
            printerICC: printerICC,
            intent: options.intent,
            blackPointCompensation: options.blackPointCompensation
        )
        let (width, height) = ColorCorrectionService.orientedSize(
            width: loaded.width, height: loaded.height, orientation: loaded.orientation
        )
        let correctedDevice = try ColorCorrectionService.convertRGBX16Pixels(
            loaded.pixels, width: loaded.width, height: loaded.height,
            transform: correctionTransform, orientation: loaded.orientation
        )

        // Uncorrected device values: the photo as sRGB numbers, as any application would hand
        // it to the printer. A source with its own profile is converted to sRGB first, like at
        // export; for a source that is already sRGB the decoded pixels are reused.
        let sRGBDevice: Data
        if loaded.embeddedICC == nil {
            sRGBDevice = try ColorCorrectionService.convertRGBX16Pixels(
                loaded.pixels, width: loaded.width, height: loaded.height,
                transform: nil, orientation: loaded.orientation
            )
        } else {
            let converted = try ColorCorrectionService.loadSource(
                from: sourceURL, maxDimension: options.maxDimension, forceSRGB: true
            )
            sRGBDevice = try ColorCorrectionService.convertRGBX16Pixels(
                converted.pixels, width: converted.width, height: converted.height,
                transform: nil, orientation: converted.orientation
            )
        }

        let analysis = try timed("analysis") {
            try PreviewService.analyse(
                printerICC: printerICC, srgbRGBX: sRGBDevice, deviceRGBX: correctedDevice,
                width: width, height: height,
                correctedBlack: PreviewService.correctedBlack(transform: correctionTransform)
            )
        }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        return CorrectionStage(
            width: width, height: height,
            correctedDevice: correctedDevice, sRGBDevice: sRGBDevice,
            original: try ColorCorrectionService.makeImage(rgbx: sRGBDevice, width: width, height: height, colorSpace: sRGB),
            analysis: analysis,
            heatMap: try PreviewService.makeHeatMap(deltaE: analysis.deltaEMap, width: analysis.width, height: analysis.height),
            sourceDescription: PreviewService.describe(loaded),
            effectiveBlackPointCompensation: correctionTransform.effectiveBlackPointCompensation
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
