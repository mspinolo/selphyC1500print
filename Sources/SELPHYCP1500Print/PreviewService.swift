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
        var name: String = "profilo del monitor"

        /// The profile of the screen the app window is on, or nil if it cannot be determined.
        @MainActor
        static func current(for screen: NSScreen? = NSScreen.main) -> Display? {
            guard let space = screen?.colorSpace?.cgColorSpace,
                  space.model == .rgb,
                  let icc = space.copyICCData() as Data?, !icc.isEmpty else {
                return nil
            }
            return Display(iccData: icc, colorSpace: space, name: screen?.colorSpace?.localizedName ?? "profilo del monitor")
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
                return "Profilo del monitor non utilizzabile: \(detail)"
            }
        }
    }

    /// Builds the three preview images for one photo.
    ///
    /// The caller is responsible for security-scoped access to the printer profile; access to
    /// the photo is taken here, as in `ColorCorrectionService.prepareCopies`.
    static func makePreview(
        sourceURL: URL,
        printerICC: Data,
        display: Display?,
        options: Options
    ) throws -> Preview {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        // 1. Corrected device values (the same code path as the export, on a reduced copy).
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

        // 2. Uncorrected device values: the photo as sRGB numbers, as any application would
        //    hand it to the printer. A source with its own wide-gamut profile is converted to
        //    sRGB first, like at export.
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

        // 3. Printer -> display. An unusable display profile falls back to sRGB.
        var usedFallback = false
        var imageSpace = display?.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let previewTransform: PreviewTransform
        do {
            previewTransform = try PreviewTransform(
                printerICC: printerICC, displayICC: display?.iccData,
                simulatePaperWhite: options.simulatePaperWhite,
                blackPointCompensation: options.previewBlackPointCompensation
            )
        } catch where display != nil {
            // The display profile parses but cannot be used (wrong class, no output tables...).
            usedFallback = true
            imageSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            previewTransform = try PreviewTransform(
                printerICC: printerICC, displayICC: nil,
                simulatePaperWhite: options.simulatePaperWhite,
                blackPointCompensation: options.previewBlackPointCompensation
            )
        }
        let corrected = previewTransform.render(rgbx: correctedDevice, width: width, height: height, countOutOfGamut: true)
        let uncorrected = previewTransform.render(rgbx: sRGBDevice, width: width, height: height, countOutOfGamut: false)

        // 4. Checks and dE map, measured on the same reduced buffers.
        let blackDevice = correctedBlack(transform: correctionTransform)
        let (stats, deltaEMap) = try analyse(
            printerICC: printerICC, srgbRGBX: sRGBDevice, deviceRGBX: correctedDevice,
            pixelCount: width * height, correctedBlack: blackDevice
        )

        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        return Preview(
            original: try ColorCorrectionService.makeImage(rgbx: sRGBDevice, width: width, height: height, colorSpace: sRGB),
            uncorrected: try ColorCorrectionService.makeImage(rgbx: uncorrected.pixels, width: width, height: height, colorSpace: imageSpace),
            corrected: try ColorCorrectionService.makeImage(rgbx: corrected.pixels, width: width, height: height, colorSpace: imageSpace),
            outOfGamutFraction: Double(corrected.outOfGamut) / Double(max(1, width * height)),
            usedSRGBFallback: usedFallback,
            effectiveBlackPointCompensation: correctionTransform.effectiveBlackPointCompensation,
            stats: stats,
            heatMap: try makeHeatMap(deltaE: deltaEMap, width: width, height: height),
            sourceDescription: describe(loaded),
            displayName: usedFallback || display == nil ? "sRGB" : display!.name
        )
    }

    /// What the correction sends to the printer for source black.
    private static func correctedBlack(transform: ColorCorrectionService.ColorTransform) -> [UInt8] {
        var input: [UInt16] = [0, 0, 0]
        var output: [UInt16] = [0, 0, 0]
        transform.apply16(&input, to: &output, pixelCount: 1)
        return output.map { UInt8((UInt32($0) * 255 + 32767) / 65535) }
    }

    private static func packRGB(_ rgbx: Data) -> [UInt8] {
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

    private static func analyse(
        printerICC: Data, srgbRGBX: Data, deviceRGBX: Data, pixelCount: Int, correctedBlack: [UInt8]
    ) throws -> (PhotoStats, [Float]) {
        let source = packRGB(srgbRGBX)
        let device = packRGB(deviceRGBX)
        var map = [Float](repeating: 0, count: pixelCount)
        var raw = selphy_photo_stats()
        let status: selphy_status = printerICC.withUnsafeBytes { printerBytes in
            selphy_analyze_photo(
                printerBytes.bindMemory(to: UInt8.self).baseAddress, printerBytes.count,
                source, device, pixelCount, correctedBlack, &map, &raw
            )
        }
        guard status == SELPHY_OK else {
            throw ColorCorrectionService.CorrectionError.transformCreation(String(cString: selphy_status_message(status)))
        }
        return (
            PhotoStats(
                meanDeltaE: raw.mean_de, p95DeltaE: raw.p95_de, maxDeltaE: raw.max_de,
                shareNotReproducible: raw.share_not_reproducible,
                darkestToneL: raw.darkest_tone_l, shareBelowDarkestTone: raw.share_below_darkest_tone,
                neutralShare: raw.neutral_share,
                neutralP95Chroma: raw.neutral_p95_chroma >= 0 ? raw.neutral_p95_chroma : nil
            ),
            map
        )
    }

    private static func describe(_ loaded: ColorCorrectionService.LoadedSource) -> String {
        switch loaded.interpretation {
        case .embeddedProfile:
            return "profilo incorporato \(loaded.profileName ?? "RGB")"
        case .assumedSRGB:
            return "RGB senza profilo utilizzabile, assunto sRGB"
        case .convertedToSRGB:
            return "\(loaded.colorModel ?? "non RGB"), convertito in sRGB"
        }
    }

    /// Overlay colour for a dE00 value: transparent below 1, yellow around 3, red from 6.
    /// Returns premultiplied RGBA.
    static func heatColor(deltaE: Float) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard deltaE.isFinite, deltaE > 1 else { return (0, 0, 0, 0) }
        let t = min(1, (deltaE - 1) / 5)
        let alpha = 90 + 130 * t
        let green = 255 * (1 - t)
        let scale = alpha / 255
        return (UInt8((255 * scale).rounded()), UInt8((green * scale).rounded()), 0, UInt8(alpha.rounded()))
    }

    private static func makeHeatMap(deltaE: [Float], width: Int, height: Int) throws -> CGImage {
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
