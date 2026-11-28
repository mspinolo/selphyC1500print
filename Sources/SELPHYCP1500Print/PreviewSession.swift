import Foundation
import Synchronization
import CoreGraphics
import ImageIO
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
/// Thread-safe: the caches are guarded by a mutex, the heavy work runs outside it (two callers
/// asking for the same missing stage at once may both compute it; the result is the same).
final class PreviewSession: Sendable {
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

    private final class CorrectionStage: Sendable {
        let width: Int
        let height: Int
        let correctedDevice: Data
        let sRGBDevice: Data
        /// The photo as the system shows it (nil if ImageIO cannot make it).
        let original: CGImage?
        let analysis: PreviewService.Analysis
        let heatMap: CGImage
        let sourceDescription: String
        let effectiveBlackPointCompensation: Bool

        init(width: Int, height: Int, correctedDevice: Data, sRGBDevice: Data, original: CGImage?,
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

        /// The original, or the sRGB numbers of the file when ImageIO cannot make it.
        func originalOrFallback() throws -> CGImage {
            if let original { return original }
            return try ColorCorrectionService.makeImage(
                rgbx: sRGBDevice, width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
    }

    private struct TransformStage {
        let transform: PreviewService.PreviewTransform
        let usedSRGBFallback: Bool
        let imageSpace: CGColorSpace
        let displayName: String
    }

    /// The device values of the full-screen layers at full resolution, each made only when a
    /// layer needs it: the corrected values for "with correction", the sRGB copy for "without".
    private struct FullBuffers {
        let width: Int
        let height: Int
        var corrected: Data?
        var sRGB: Data?
    }

    private struct LayerKey: Hashable {
        let render: RenderKey
        let layer: FullLayer
    }

    /// A view of the full-screen window, computed on its own (see `fullResolutionLayers`).
    enum FullLayer: Hashable, Sendable {
        case original, uncorrected, corrected
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

    private struct State {
        var corrections: LRU<CorrectionKey, CorrectionStage>
        var transforms: LRU<TransformKey, TransformStage>
        var renders: LRU<RenderKey, RenderStage>
        /// Single full-resolution renderings of the full-screen view.
        var layers: LRU<LayerKey, CGImage>
        var fullBuffers: LRU<CorrectionKey, FullBuffers>
        var counters = Counters()
        var timings: [String: Double] = [:]
    }

    private let state: Mutex<State>

    var counters: Counters { locked { $0.counters } }
    /// Seconds spent in each stage the last time it was computed.
    var timings: [String: Double] { locked { $0.timings } }

    /// The session of the interactive preview (reduced size), shared by the preview panel and
    /// the full-screen view.
    static let shared = PreviewSession()

    /// Capacities in entries; a full-resolution session keeps fewer (each entry can be hundreds of MB).
    init(corrections: Int = 3, transforms: Int = 6, renders: Int = 8) {
        state = Mutex(State(
            corrections: LRU(capacity: corrections),
            transforms: LRU(capacity: transforms),
            renders: LRU(capacity: renders),
            layers: LRU(capacity: max(2, renders * 2)),
            fullBuffers: LRU(capacity: corrections)
        ))
    }

    /// Drops everything (e.g. when the printer profile is replaced and memory should be freed).
    func removeAll() {
        locked {
            $0.corrections.removeAll()
            $0.transforms.removeAll()
            $0.renders.removeAll()
            $0.layers.removeAll()
            $0.fullBuffers.removeAll()
        }
    }

    private func locked<T: Sendable>(_ body: (inout State) -> T) -> T {
        state.withLock { body(&$0) }
    }

    private func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = Date()
        let result = try body()
        let elapsed = Date().timeIntervalSince(start)
        locked { $0.timings[name] = elapsed }
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
        if let cached = locked({ $0.corrections.value(for: correctionKey) }) {
            correction = cached
        } else {
            correction = try timed("correction") {
                try computeCorrection(sourceURL: sourceURL, printerICC: printerICC, options: options)
            }
            locked {
                $0.counters.corrections += 1
                $0.corrections.insert(correction, for: correctionKey)
            }
        }

        let transform: TransformStage
        if let cached = locked({ $0.transforms.value(for: transformKey) }) {
            transform = cached
        } else {
            transform = try timed("transform") {
                try computeTransform(printerICC: printerICC, display: display, options: options)
            }
            locked {
                $0.counters.transforms += 1
                $0.transforms.insert(transform, for: transformKey)
            }
        }

        let renderKey = RenderKey(correction: correctionKey, transform: transformKey)
        let render: RenderStage
        if let cached = locked({ $0.renders.value(for: renderKey) }) {
            render = cached
        } else {
            render = try timed("render") {
                try computeRender(correction: correction, transform: transform)
            }
            locked {
                $0.counters.renders += 1
                $0.renders.insert(render, for: renderKey)
            }
        }

        return PreviewService.Preview(
            original: try correction.originalOrFallback(),
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

    /// The full-resolution layers of the full-screen view, in the order asked (the one on screen
    /// first), each delivered as soon as it is ready. Each layer computes only what it needs: the
    /// original comes straight from the file, "with correction" needs the printer conversion,
    /// "without" the sRGB copy; the statistics of the preview (analysis, heat map) are not made.
    /// Device values are kept per photo, so switching views does not convert again.
    func fullResolutionLayers(
        sourceURL: URL, printerICC: Data, display: PreviewService.Display?, options: PreviewService.Options,
        order: [FullLayer], isCancelled: () -> Bool = { false }, deliver: (FullLayer, CGImage) -> Void
    ) throws {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        var options = options
        options.maxDimension = Int.max
        let modified = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path))?[.modificationDate] as? Date
        let printerHash = ContentDigest.of(printerICC)
        let correctionKey = CorrectionKey(
            path: sourceURL.path, modified: modified, intent: options.intent,
            blackPointCompensation: options.blackPointCompensation, maxDimension: options.maxDimension, printerProfile: printerHash)
        let transformKey = TransformKey(
            printerProfile: printerHash, displayProfile: display.map { ContentDigest.of($0.iccData) },
            simulatePaperWhite: options.simulatePaperWhite, blackPointCompensation: options.previewBlackPointCompensation)
        let renderKey = RenderKey(correction: correctionKey, transform: transformKey)

        var transform: TransformStage?
        // Decoded at most once per call, and only if a layer needs device values not yet cached.
        var loaded: ColorCorrectionService.LoadedSource?
        func decoded() throws -> ColorCorrectionService.LoadedSource {
            if let loaded { return loaded }
            let made = try timed("decode") { try ColorCorrectionService.loadSource(from: sourceURL, maxDimension: options.maxDimension) }
            locked { $0.counters.corrections += 1 }
            loaded = made
            return made
        }
        /// The device values of `layer` (corrected, or the sRGB copy), from the cache or made now.
        func buffers(for layer: FullLayer) throws -> (data: Data, width: Int, height: Int) {
            let entry = locked { $0.fullBuffers.value(for: correctionKey) }
            if let entry, let data = layer == .corrected ? entry.corrected : entry.sRGB {
                return (data, entry.width, entry.height)
            }
            let source = try decoded()
            let (width, height) = ColorCorrectionService.orientedSize(width: source.width, height: source.height, orientation: source.orientation)
            let data: Data
            if layer == .corrected {
                let correctionTransform = try ColorCorrectionService.ColorTransform(
                    sourceICC: source.embeddedICC, printerICC: printerICC,
                    intent: options.intent, blackPointCompensation: options.blackPointCompensation)
                data = try timed("convert") {
                    try ColorCorrectionService.convertRGBX16Pixels(
                        source.pixels, width: source.width, height: source.height,
                        transform: correctionTransform, orientation: source.orientation)
                }
            } else {
                data = try timed("sRGB copy") { try sRGBCopy(of: source, sourceURL: sourceURL, maxDimension: options.maxDimension) }
            }
            var updated = entry ?? FullBuffers(width: width, height: height)
            if layer == .corrected { updated.corrected = data } else { updated.sRGB = data }
            locked { $0.fullBuffers.insert(updated, for: correctionKey) }
            return (data, width, height)
        }

        for layer in order {
            if isCancelled() { return }
            let key = LayerKey(render: renderKey, layer: layer)
            if let cached = locked({ $0.layers.value(for: key) }) {
                deliver(layer, cached)
                continue
            }
            let image: CGImage
            switch layer {
            case .original:
                if let original = Self.originalImage(url: sourceURL, maxDimension: options.maxDimension) {
                    image = original
                } else {
                    // ImageIO cannot show the file as it is: its sRGB numbers instead.
                    let sRGB = try buffers(for: .uncorrected)
                    image = try ColorCorrectionService.makeImage(
                        rgbx: sRGB.data, width: sRGB.width, height: sRGB.height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                }
            case .uncorrected, .corrected:
                if transform == nil {
                    if let cached = locked({ $0.transforms.value(for: transformKey) }) {
                        transform = cached
                    } else {
                        let made = try timed("transform") { try computeTransform(printerICC: printerICC, display: display, options: options) }
                        locked { $0.transforms.insert(made, for: transformKey) }
                        transform = made
                    }
                }
                guard let transform else { continue }
                let device = try buffers(for: layer)
                if isCancelled() { return }
                let rendered = timed("render") {
                    transform.transform.render(rgbx: device.data, width: device.width, height: device.height, countOutOfGamut: false)
                }
                image = try ColorCorrectionService.makeImage(
                    rgbx: rendered.pixels, width: device.width, height: device.height, colorSpace: transform.imageSpace)
            }
            locked { $0.layers.insert(image, for: key) }
            deliver(layer, image)
        }
    }

    /// The photo as macOS shows it (EXIF orientation applied, its own colour space), at most
    /// `maxDimension` pixels on the long side. Transparent areas are put on white, as in print.
    static func originalImage(url: URL, maxDimension: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxDimension),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            guard let space = image.colorSpace, space.model == .rgb,
                  let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return context.makeImage() ?? image
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
        let loaded = try timed("decode") { try ColorCorrectionService.loadSource(from: sourceURL, maxDimension: maxDimension) }
        let (width, height) = ColorCorrectionService.orientedSize(
            width: loaded.width, height: loaded.height, orientation: loaded.orientation
        )
        // Uncorrected device values. A source with its own profile is converted to sRGB first,
        // like at export; for a source that is already sRGB the decoded pixels are reused.
        let sRGBDevice: Data = try timed("sRGB copy") { try sRGBCopy(of: loaded, sourceURL: sourceURL, maxDimension: maxDimension) }
        return DecodedSource(loaded: loaded, width: width, height: height, sRGBDevice: sRGBDevice)
    }

    private func sRGBCopy(of loaded: ColorCorrectionService.LoadedSource, sourceURL: URL, maxDimension: Int) throws -> Data {
        // A source with its own profile is converted to sRGB by ColorSync (as any application
        // would hand it to the printer), from the pixels already decoded.
        let sRGB = try ColorCorrectionService.convertedToSRGB(loaded)
        return try ColorCorrectionService.convertRGBX16Pixels(
            sRGB.pixels, width: sRGB.width, height: sRGB.height, transform: nil, orientation: sRGB.orientation
        )
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
        let correctedDevice = try timed("convert") {
            try ColorCorrectionService.convertRGBX16Pixels(
                loaded.pixels, width: loaded.width, height: loaded.height,
                transform: correctionTransform, orientation: loaded.orientation
            )
        }
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
        return CorrectionStage(
            width: decoded.width, height: decoded.height,
            correctedDevice: corrected.correctedDevice, sRGBDevice: decoded.sRGBDevice,
            // The file as the system shows it, in its own colour space (a wide-gamut source keeps
            // its colours); the sRGB numbers only if ImageIO cannot make it.
            original: Self.originalImage(url: sourceURL, maxDimension: options.maxDimension),
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
