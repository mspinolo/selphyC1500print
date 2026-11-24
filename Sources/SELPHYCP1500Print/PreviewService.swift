import Foundation
import AppKit
import CoreGraphics
import SELPHYColorCore

/// Soft-proof preview: how a photo is expected to look on paper, with and without the
/// pre-correction, computed from the printer profile's own forward model (A2B).
///
/// This is a model-based simulation shown on the display, not a print proof, and it has not
/// been validated with physical prints.
enum PreviewService {
    /// The three renderings, all with the EXIF orientation applied.
    struct Preview {
        /// The photo as sRGB numbers, i.e. what would reach the printer without any correction.
        let original: CGImage
        /// Expected print of the uncorrected numbers.
        let uncorrected: CGImage
        /// Expected print of the pre-corrected numbers.
        let corrected: CGImage
        /// Share (0...1) of the corrected pixels whose colour lies outside the display gamut and
        /// is clipped in the preview (best effort: depends on the display profile).
        let outOfGamutFraction: Double
        /// True when the display profile was unusable and sRGB was used instead.
        let usedSRGBFallback: Bool
        /// Whether black point compensation was effectively applied in the correction.
        let effectiveBlackPointCompensation: Bool
        /// Checks of the photo against the model (see `PhotoStats`).
        let stats: PhotoStats
        /// dE00 between the original and the predicted print, as a translucent overlay
        /// (transparent where the deviation is small).
        let heatMap: CGImage
        /// Where the colours came from, for the details panel.
        let sourceDescription: String
        let displayName: String
        /// Per-pixel model results at the analysis resolution (overlays, inspector, statistics).
        let maps: PixelMaps
    }

    /// Per-photo checks from the core (`selphy_analyze_photo`), measured against the photo read
    /// as sRGB. Model estimates, not measurements of a print.
    struct PhotoStats: Equatable {
        var meanDeltaE: Double
        var p95DeltaE: Double
        var maxDeltaE: Double
        /// Share (0...1) of pixels with dE00 above `selphy`'s threshold (3).
        var shareNotReproducible: Double
        /// Predicted lightness of the corrected source black: the darkest tone the print reproduces.
        var darkestToneL: Double
        /// Share of pixels darker than that tone (shadows merged or compressed).
        var shareBelowDarkestTone: Double
        /// Share of near-neutral pixels.
        var neutralShare: Double
        /// 95th percentile of the predicted chroma of reproducible neutral pixels; nil if none.
        var neutralP95Chroma: Double?

        /// A photo is treated as black and white when almost all pixels are neutral.
        var isBlackAndWhite: Bool { neutralShare >= Double(SELPHY_NEUTRAL_IMAGE_SHARE) }
    }

    struct Options {
        var intent: RenderingIntent
        var blackPointCompensation: Bool
        /// Simulate the paper tint and brightness instead of mapping paper white to display white.
        var simulatePaperWhite = false
        /// Stretch the printer's black to the display's black in the preview.
        var previewBlackPointCompensation = false
        /// Longest side of the preview images, in pixels.
        var maxDimension = 1400
    }

    /// The display the preview is shown on: ICC bytes for the core and the matching colour space
    /// for the images, so that the system does not convert them a second time.
    struct Display {
        let iccData: Data
        let colorSpace: CGColorSpace
        var name: String = tr("monitor profile")

        /// The profile of the screen the app window is on, or nil if it cannot be determined.
        @MainActor
        static func current(for screen: NSScreen? = NSScreen.main) -> Display? {
            guard let space = screen?.colorSpace?.cgColorSpace,
                  space.model == .rgb,
                  let icc = space.copyICCData() as Data?, !icc.isEmpty else {
                return nil
            }
            return Display(iccData: icc, colorSpace: space, name: screen?.colorSpace?.localizedName ?? tr("monitor profile"))
        }
    }

    /// Owns a `selphy_preview`. Immutable after creation; safe to use from several threads.
    final class PreviewTransform {
        private let handle: OpaquePointer

        init(printerICC: Data, displayICC: Data?, simulatePaperWhite: Bool, blackPointCompensation: Bool) throws {
            var options = selphy_preview_options(
                simulate_paper_white: simulatePaperWhite ? 1 : 0,
                black_point_compensation: blackPointCompensation ? 1 : 0
            )
            var created: OpaquePointer?
            let status: selphy_status = printerICC.withUnsafeBytes { printerBytes in
                let printerBase = printerBytes.bindMemory(to: UInt8.self).baseAddress
                if let displayICC, !displayICC.isEmpty {
                    return displayICC.withUnsafeBytes { displayBytes in
                        selphy_preview_create(
                            printerBase, printerBytes.count,
                            displayBytes.bindMemory(to: UInt8.self).baseAddress, displayBytes.count,
                            &options, &created
                        )
                    }
                }
                return selphy_preview_create(printerBase, printerBytes.count, nil, 0, &options, &created)
            }
            guard status == SELPHY_OK, let created else {
                let message = String(cString: selphy_status_message(status))
                if status == SELPHY_ERR_DISPLAY_PROFILE {
                    throw PreviewError.displayProfile(message)
                }
                if status == SELPHY_ERR_PRINTER_PROFILE || status == SELPHY_ERR_PRINTER_UNSUPPORTED {
                    throw ColorCorrectionService.CorrectionError.profileLoad(message)
                }
                throw ColorCorrectionService.CorrectionError.transformCreation(message)
            }
            handle = created
        }

        deinit { selphy_preview_free(handle) }

        /// Share (0...1) of the given packed RGB device pixels whose colour lies outside the display
        /// gamut. Meant for a reduced sample: the float evaluation is much slower than rendering.
        func outOfGamutFraction(packedRGB: [UInt8]) -> Double {
            let count = packedRGB.count / 3
            guard count > 0 else { return 0 }
            var scratch = [UInt8](repeating: 0, count: count * 3)
            var clipped = 0
            selphy_preview_apply_rgb8(handle, packedRGB, &scratch, count, &clipped)
            return Double(clipped) / Double(count)
        }

        /// Converts oriented 8-bit RGBX device values to display RGBX. Returns the number of
        /// out-of-gamut pixels when `countOutOfGamut` is set (otherwise 0).
        func render(rgbx device: Data, width: Int, height: Int, countOutOfGamut: Bool) -> (pixels: Data, outOfGamut: Int) {
            let pixelCount = width * height
            var output = Data(count: pixelCount * 4)
            guard pixelCount > 0, device.count == pixelCount * 4 else { return (output, 0) }
            let rowsPerBlock = max(1, 65_536 / width)
            let blockCount = (height + rowsPerBlock - 1) / rowsPerBlock
            var blockClipped = [Int](repeating: 0, count: blockCount)
            device.withUnsafeBytes { deviceRaw in
                output.withUnsafeMutableBytes { outputRaw in
                    blockClipped.withUnsafeMutableBufferPointer { clippedBuffer in
                        guard let deviceBase = deviceRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                              let outputBase = outputRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                              let clippedBase = clippedBuffer.baseAddress else { return }
                        DispatchQueue.concurrentPerform(iterations: blockCount) { block in
                            let firstPixel = block * rowsPerBlock * width
                            let count = min(rowsPerBlock * width, pixelCount - firstPixel)
                            let packedIn = UnsafeMutablePointer<UInt8>.allocate(capacity: count * 3)
                            let packedOut = UnsafeMutablePointer<UInt8>.allocate(capacity: count * 3)
                            defer {
                                packedIn.deallocate()
                                packedOut.deallocate()
                            }
                            for i in 0..<count {
                                let source = deviceBase + (firstPixel + i) * 4
                                packedIn[i * 3] = source[0]
                                packedIn[i * 3 + 1] = source[1]
                                packedIn[i * 3 + 2] = source[2]
                            }
                            var clipped = 0
                            if countOutOfGamut {
                                selphy_preview_apply_rgb8(handle, packedIn, packedOut, count, &clipped)
                            } else {
                                selphy_preview_apply_rgb8(handle, packedIn, packedOut, count, nil)
                            }
                            clippedBase[block] = clipped
                            for i in 0..<count {
                                let target = outputBase + (firstPixel + i) * 4
                                target[0] = packedOut[i * 3]
                                target[1] = packedOut[i * 3 + 1]
                                target[2] = packedOut[i * 3 + 2]
                                target[3] = 0
                            }
                        }
                    }
                }
            }
            return (output, blockClipped.reduce(0, +))
        }
    }

    enum PreviewError: LocalizedError {
        case displayProfile(String)

        var errorDescription: String? {
            switch self {
            case .displayProfile(let detail):
                return trf("Monitor profile unusable: %@", detail)
            }
        }
    }

    /// Builds the three preview images for one photo, without keeping anything between calls.
    /// Interactive code should use a long-lived `PreviewSession` instead, which caches the
    /// expensive stages.
    ///
    /// The caller is responsible for security-scoped access to the printer profile; access to
    /// the photo is taken here, as in `ColorCorrectionService.prepareCopies`.
    static func makePreview(
        sourceURL: URL,
        printerICC: Data,
        display: Display?,
        options: Options
    ) throws -> Preview {
        try PreviewSession().makePreview(sourceURL: sourceURL, printerICC: printerICC, display: display, options: options)
    }

    /// What the correction sends to the printer for source black.
    static func correctedBlack(transform: ColorCorrectionService.ColorTransform) -> [UInt8] {
        var input: [UInt16] = [0, 0, 0]
        var output: [UInt16] = [0, 0, 0]
        transform.apply16(&input, to: &output, pixelCount: 1)
        return output.map { UInt8((UInt32($0) * 255 + 32767) / 65535) }
    }

    static func packRGB(_ rgbx: Data) -> [UInt8] {
        let count = rgbx.count / 4
        var packed = [UInt8](repeating: 0, count: count * 3)
        rgbx.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self)
            for i in 0..<count {
                packed[i * 3] = source[i * 4]
                packed[i * 3 + 1] = source[i * 4 + 1]
                packed[i * 3 + 2] = source[i * 4 + 2]
            }
        }
        return packed
    }

    /// Longest side of the buffers used for the checks and the dE map. The statistics do not need
    /// every pixel of the preview, and the dE00 evaluation is the most expensive step.
    static let analysisDimension = 512

    /// Every `factor`-th pixel of an oriented RGBX buffer, as packed RGB.
    static func sampledRGB(_ rgbx: Data, width: Int, height: Int, factor: Int) -> (rgb: [UInt8], width: Int, height: Int) {
        let sampledWidth = (width + factor - 1) / factor
        let sampledHeight = (height + factor - 1) / factor
        var packed = [UInt8](repeating: 0, count: sampledWidth * sampledHeight * 3)
        rgbx.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self)
            for sy in 0..<sampledHeight {
                for sx in 0..<sampledWidth {
                    let from = ((sy * factor) * width + sx * factor) * 4
                    let to = (sy * sampledWidth + sx) * 3
                    packed[to] = source[from]
                    packed[to + 1] = source[from + 1]
                    packed[to + 2] = source[from + 2]
                }
            }
        }
        return (packed, sampledWidth, sampledHeight)
    }

    struct Analysis {
        let stats: PhotoStats
        let deltaEMap: [Float]
        let width: Int
        let height: Int
        let maps: PixelMaps
    }

    /// Intended and predicted Lab per pixel (same inputs as `selphy_analyze_photo`).
    static func pixelMaps(
        printerICC: Data, srgb: [UInt8], device: [UInt8], deltaE: [Float], width: Int, height: Int
    ) throws -> PixelMaps {
        let count = width * height
        let srgb16 = srgb.map { UInt16($0) * 257 }
        let device16 = device.map { UInt16($0) * 257 }
        var intended = [Double](repeating: 0, count: count * 3)
        var predicted = [Double](repeating: 0, count: count * 3)
        let sourceStatus = selphy_source_to_lab(nil, 0, srgb16, &intended, count)
        guard sourceStatus == SELPHY_OK else {
            throw ColorCorrectionService.CorrectionError.transformCreation(String(cString: selphy_status_message(sourceStatus)))
        }
        let printerStatus: selphy_status = printerICC.withUnsafeBytes { bytes in
            selphy_printer_predict_lab(
                bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                SELPHY_INTENT_RELATIVE_COLORIMETRIC, device16, &predicted, count
            )
        }
        guard printerStatus == SELPHY_OK else {
            throw ColorCorrectionService.CorrectionError.transformCreation(String(cString: selphy_status_message(printerStatus)))
        }
        return PixelMaps(
            width: width, height: height, deltaE: deltaE,
            intendedLab: intended.map { Float($0) }, predictedLab: predicted.map { Float($0) }
        )
    }

    /// Runs the core checks on a reduced copy (see `analysisDimension`).
    static func analyse(
        printerICC: Data, srgbRGBX: Data, deviceRGBX: Data, width: Int, height: Int, correctedBlack: [UInt8]
    ) throws -> Analysis {
        let factor = max(1, (max(width, height) + analysisDimension - 1) / analysisDimension)
        let source = sampledRGB(srgbRGBX, width: width, height: height, factor: factor)
        let device = sampledRGB(deviceRGBX, width: width, height: height, factor: factor)
        let pixelCount = source.width * source.height
        var map = [Float](repeating: 0, count: pixelCount)
        var raw = selphy_photo_stats()
        let status: selphy_status = printerICC.withUnsafeBytes { printerBytes in
            selphy_analyze_photo(
                printerBytes.bindMemory(to: UInt8.self).baseAddress, printerBytes.count,
                source.rgb, device.rgb, pixelCount, correctedBlack, &map, &raw
            )
        }
        guard status == SELPHY_OK else {
            throw ColorCorrectionService.CorrectionError.transformCreation(String(cString: selphy_status_message(status)))
        }
        return Analysis(
            stats: PhotoStats(
                meanDeltaE: raw.mean_de, p95DeltaE: raw.p95_de, maxDeltaE: raw.max_de,
                shareNotReproducible: raw.share_not_reproducible,
                darkestToneL: raw.darkest_tone_l, shareBelowDarkestTone: raw.share_below_darkest_tone,
                neutralShare: raw.neutral_share,
                neutralP95Chroma: raw.neutral_p95_chroma >= 0 ? raw.neutral_p95_chroma : nil
            ),
            deltaEMap: map, width: source.width, height: source.height,
            maps: try pixelMaps(
                printerICC: printerICC, srgb: source.rgb, device: device.rgb,
                deltaE: map, width: source.width, height: source.height
            )
        )
    }

    static func describe(_ loaded: ColorCorrectionService.LoadedSource) -> String {
        switch loaded.interpretation {
        case .embeddedProfile:
            return trf("embedded profile %@", loaded.profileName ?? "RGB")
        case .assumedSRGB:
            return tr("RGB without a usable profile, assumed sRGB")
        case .convertedToSRGB:
            return trf("%@, converted to sRGB", loaded.colorModel ?? tr("non-RGB"))
        }
    }

    /// Overlay colour for a dE00 value: transparent below 1, yellow around 3, red from 6.
    /// Returns premultiplied RGBA.
    static func heatColor(deltaE: Float) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        Overlays.heatColor(deltaE: deltaE, scale: .standard)
    }

    static func makeHeatMap(deltaE: [Float], width: Int, height: Int) throws -> CGImage {
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let target = raw.bindMemory(to: UInt8.self)
            for i in 0..<(width * height) {
                let color = heatColor(deltaE: deltaE[i])
                target[i * 4] = color.r
                target[i * 4 + 1] = color.g
                target[i * 4 + 2] = color.b
                target[i * 4 + 3] = color.a
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else {
            throw ColorCorrectionService.CorrectionError.bitmapContext
        }
        return image
    }
}
