import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SELPHYColorCore

/// Experimental pre-correction for the SELPHY's fixed internal color pipeline.
///
/// The Farbenwerk profile describes the complete printer response. We convert
/// source-image RGB through PCS into the profile's RGB input values, then tag
/// those numeric values as sRGB for the SELPHY's normal fixed processing path.
/// The conversion itself runs in the portable LittleCMS-based colour core
/// (`SELPHYColorCore`). This workflow is trusted on the vendor's documentation
/// and has not been validated with physical prints.
enum ColorCorrectionService {
    struct Result {
        let files: [URL]
        let folder: URL
        /// RGB sources without an embedded profile: interpreted as sRGB.
        var assumedSRGBSources: [URL] = []
        /// Grayscale, CMYK, Lab or indexed sources: converted to sRGB by Core Graphics first.
        var convertedSources: [URL] = []
        /// Whether black point compensation was really applied (forced for v4 perceptual/saturation).
        var effectiveBlackPointCompensation = false
    }

    /// How the colour of a source was interpreted.
    enum SourceInterpretation {
        case embeddedProfile
        case assumedSRGB
        case convertedToSRGB
    }

    /// Upper bound on decoded pixels (the 16-bit working buffer needs 8 bytes/pixel).
    static let maximumPixelCount = 100_000_000

    enum CorrectionError: LocalizedError {
        case unreadableImage(URL)
        case unsupportedColorSpace(URL)
        case profileLoad(String)
        case transformCreation(String)
        case bitmapContext
        case imageEncoding(URL)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unreadableImage(let url):
                return trf("Unable to read the image: %@", url.lastPathComponent)
            case .unsupportedColorSpace(let url):
                return trf("Unsupported colour space (RGB, greyscale, CMYK, Lab are accepted): %@", url.lastPathComponent)
            case .profileLoad(let detail):
                return trf("Unable to load the ICC profile: %@", detail)
            case .transformCreation(let detail):
                return trf("Unable to create the colour transform: %@", detail)
            case .bitmapContext:
                return tr("Unable to create the RGB bitmap buffer.")
            case .imageEncoding(let url):
                return trf("Unable to generate the temporary image: %@", url.lastPathComponent)
            case .cancelled:
                return tr("Conversion cancelled.")
            }
        }
    }

    /// Owns a `selphy_transform`. Immutable after creation, so it can be shared across
    /// the images of one batch that use the same source profile, and across threads: LittleCMS
    /// (built with HasTHREADS) keeps no per-call state in a transform, which is why `@unchecked`.
    final class ColorTransform: @unchecked Sendable {
        private let handle: OpaquePointer
        let effectiveBlackPointCompensation: Bool

        init(
            sourceICC: Data?,
            printerICC: Data,
            intent: RenderingIntent,
            blackPointCompensation: Bool,
            exact: Bool = false
        ) throws {
            var options = selphy_options(
                intent: intent.coreValue,
                black_point_compensation: blackPointCompensation ? 1 : 0,
                exact: exact ? 1 : 0
            )
            var created: OpaquePointer?
            let status: selphy_status = printerICC.withUnsafeBytes { printerBytes in
                let printerBase = printerBytes.bindMemory(to: UInt8.self).baseAddress
                // An empty Data still yields a non-nil pointer in Swift; the core expects
                // NULL (with size 0) for "no embedded profile, assume sRGB".
                if let sourceICC, !sourceICC.isEmpty {
                    return sourceICC.withUnsafeBytes { sourceBytes in
                        selphy_transform_create(
                            sourceBytes.bindMemory(to: UInt8.self).baseAddress, sourceBytes.count,
                            printerBase, printerBytes.count,
                            &options, &created
                        )
                    }
                }
                return selphy_transform_create(nil, 0, printerBase, printerBytes.count, &options, &created)
            }
            guard status == SELPHY_OK, let created else {
                let message = String(cString: selphy_status_message(status))
                if status == SELPHY_ERR_PRINTER_PROFILE || status == SELPHY_ERR_PRINTER_UNSUPPORTED {
                    throw CorrectionError.profileLoad(message)
                }
                throw CorrectionError.transformCreation(message)
            }
            handle = created
            effectiveBlackPointCompensation = selphy_transform_effective_bpc(created) != 0
        }

        deinit { selphy_transform_free(handle) }

        func apply16(_ input: UnsafePointer<UInt16>, to output: UnsafeMutablePointer<UInt16>, pixelCount: Int) {
            selphy_transform_apply_rgb16(handle, input, output, pixelCount)
        }
    }

    static func prepareCopies(
        from sourceURLs: [URL],
        printerProfileURL: URL,
        intent: RenderingIntent,
        blackPointCompensation: Bool,
        outputFormat: OutputFormat = .png,
        temporaryParent: URL? = nil,
        progress: ((_ completed: Int, _ total: Int) -> Void)? = nil,
        shouldCancel: (() -> Bool)? = nil
    ) throws -> Result {
        let printerICC: Data
        do {
            // The profile comes from a security-scoped bookmark: in the sandbox it can be read
            // only with access open (an extra start/stop by the caller is harmless).
            let hasProfileAccess = printerProfileURL.startAccessingSecurityScopedResource()
            defer { if hasProfileAccess { printerProfileURL.stopAccessingSecurityScopedResource() } }
            printerICC = try Data(contentsOf: printerProfileURL)
        } catch {
            throw CorrectionError.profileLoad(error.localizedDescription)
        }
        // Fail before touching any source if the printer profile is unusable.
        let validation = try ColorTransform(
            sourceICC: nil,
            printerICC: printerICC,
            intent: intent,
            blackPointCompensation: blackPointCompensation
        )

        let sessionFolder = try makeSessionFolder(in: temporaryParent)
        var transformCache: [Data: ColorTransform] = [:]
        var outputs: [URL] = []
        var assumedSRGB: [URL] = []
        var converted: [URL] = []

        do {
            progress?(0, sourceURLs.count)
            for sourceURL in sourceURLs {
                // Cancellation is checked between photos; a photo being converted is finished.
                if shouldCancel?() == true { throw CorrectionError.cancelled }
                let hasAccess = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }

                // "<name>_SELPHY.<ext>", numbered if two sources share a name.
                let outputURL = ExportService.uniqueURL(
                    in: sessionFolder,
                    baseName: sourceURL.deletingPathExtension().lastPathComponent + "_SELPHY",
                    pathExtension: outputFormat.fileExtension
                )

                let interpretation = try correct(
                    sourceURL: sourceURL,
                    outputURL: outputURL,
                    printerICC: printerICC,
                    intent: intent,
                    blackPointCompensation: blackPointCompensation,
                    outputFormat: outputFormat,
                    transformCache: &transformCache
                )
                outputs.append(outputURL)
                progress?(outputs.count, sourceURLs.count)
                switch interpretation {
                case .embeddedProfile: break
                case .assumedSRGB: assumedSRGB.append(sourceURL)
                case .convertedToSRGB: converted.append(sourceURL)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: sessionFolder)
            throw error
        }

        return Result(
            files: outputs, folder: sessionFolder,
            assumedSRGBSources: assumedSRGB, convertedSources: converted,
            effectiveBlackPointCompensation: validation.effectiveBlackPointCompensation
        )
    }

    /// A decoded source: 16-bit big-endian RGBX pixels (not yet oriented) plus how its colour
    /// was interpreted.
    struct LoadedSource {
        let pixels: Data
        let width: Int
        let height: Int
        let orientation: Int
        /// ICC data of the source colour space; nil means the pixels are sRGB.
        let embeddedICC: Data?
        let interpretation: SourceInterpretation
        let dpi: (width: Double, height: Double)?
        /// Profile description reported by ImageIO (e.g. "sRGB IEC61966-2.1"), if any.
        let profileName: String?
        /// Colour model of the file as decoded by ImageIO (RGB, Gray, CMYK...).
        let colorModel: String?
    }

    /// Decodes the first image of a file to 16-bit RGBX.
    /// - Parameters:
    ///   - maxDimension: if the longest side is larger, the image is scaled down while decoding
    ///     (used by the preview; the export always decodes at full size).
    ///   - forceSRGB: decode into sRGB even when the file has its own profile.
    static func loadSource(from sourceURL: URL, maxDimension: Int? = nil, forceSRGB: Bool = false) throws -> LoadedSource {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CorrectionError.unreadableImage(sourceURL)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let orientation = (1...8).contains(rawOrientation) ? rawOrientation : 1

        guard let imageColorSpace = image.colorSpace else {
            throw CorrectionError.unsupportedColorSpace(sourceURL)
        }

        // RGB sources use their embedded profile; without one they are assumed sRGB. Grayscale,
        // CMYK, Lab and indexed sources are converted to sRGB by Core Graphics while decoding,
        // using their own profile, and then go through the same transform.
        var interpretation: SourceInterpretation
        var embeddedICC: Data?
        switch imageColorSpace.model {
        case .rgb where imageColorSpace.numberOfComponents == 3:
            embeddedICC = imageColorSpace.copyICCData() as Data?
            // ImageIO reports an sRGB colour space (and profile name) even for files that carry
            // no profile at all, so a really untagged JPEG/PNG cannot be told from a tagged sRGB
            // one: both are, correctly, treated as sRGB. "Assumed" is therefore reported only
            // when no ICC data is available for an RGB colour space.
            interpretation = embeddedICC == nil ? .assumedSRGB : .embeddedProfile
        case .monochrome, .cmyk, .lab, .indexed, .XYZ:
            interpretation = .convertedToSRGB
        default:
            throw CorrectionError.unsupportedColorSpace(sourceURL)
        }
        let decodeSpace: CGColorSpace
        if interpretation != .embeddedProfile || forceSRGB {
            if forceSRGB && interpretation == .embeddedProfile { interpretation = .convertedToSRGB }
            embeddedICC = nil
            decodeSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        } else {
            decodeSpace = imageColorSpace
        }

        try validateDimensions(width: image.width, height: image.height)
        var width = image.width
        var height = image.height
        if let maxDimension, max(width, height) > maxDimension {
            let scale = Double(maxDimension) / Double(max(width, height))
            width = max(1, Int((Double(width) * scale).rounded()))
            height = max(1, Int((Double(height) * scale).rounded()))
        }
        let sourceBytesPerRow = width * 8

        // 16 bits per component (8 bytes/pixel, RGBX) so that 16-bit and linear sources keep
        // their precision.
        var pixels = Data(count: sourceBytesPerRow * height)
        let contextCreated = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 16,
                bytesPerRow: sourceBytesPerRow,
                space: decodeSpace,
                bitmapInfo: CGBitmapInfo.byteOrder16Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .high
            // Transparent areas (PNG/TIFF with alpha) are composited on white, the
            // sensible background for a print, instead of on black.
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard contextCreated else { throw CorrectionError.bitmapContext }

        return LoadedSource(
            pixels: pixels, width: width, height: height, orientation: orientation,
            embeddedICC: embeddedICC, interpretation: interpretation,
            dpi: resolution(from: properties),
            profileName: properties?[kCGImagePropertyProfileName] as? String,
            colorModel: properties?[kCGImagePropertyColorModel] as? String
        )
    }

    /// Wraps oriented 8-bit RGBX pixels (alpha byte ignored) into a CGImage.
    static func makeImage(rgbx: Data, width: Int, height: Int, colorSpace: CGColorSpace) throws -> CGImage {
        guard rgbx.count == width * height * 4,
              let provider = CGDataProvider(data: rgbx as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            throw CorrectionError.bitmapContext
        }
        return image
    }

    @discardableResult
    private static func correct(
        sourceURL: URL,
        outputURL: URL,
        printerICC: Data,
        intent: RenderingIntent,
        blackPointCompensation: Bool,
        outputFormat: OutputFormat,
        transformCache: inout [Data: ColorTransform]
    ) throws -> SourceInterpretation {
        var loaded = try loadSource(from: sourceURL)

        let cacheKey = loaded.embeddedICC ?? Data()
        let transform: ColorTransform
        if let cached = transformCache[cacheKey] {
            transform = cached
        } else {
            transform = try ColorTransform(
                sourceICC: loaded.embeddedICC,
                printerICC: printerICC,
                intent: intent,
                blackPointCompensation: blackPointCompensation
            )
            transformCache[cacheKey] = transform
        }

        let (outputWidth, outputHeight) = orientedSize(width: loaded.width, height: loaded.height, orientation: loaded.orientation)

        // EXIF orientation is applied while the converted pixels are written, at full precision.
        let correctedPixels = try convertRGBX16Pixels(
            loaded.pixels,
            width: loaded.width,
            height: loaded.height,
            transform: transform,
            orientation: loaded.orientation
        )
        let orientation = loaded.orientation
        let sourceDPI = loaded.dpi
        let interpretation = loaded.interpretation
        loaded = LoadedSource(pixels: Data(), width: 0, height: 0, orientation: 1, embeddedICC: nil, interpretation: interpretation, dpi: nil, profileName: nil, colorModel: nil)

        // Deliberately re-tag the corrected numeric RGB values as sRGB. The
        // SELPHY has a fixed internal color pipeline; the profile is used to
        // pre-adjust its expected input values, not installed in the printer.
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let correctedImage = try makeImage(rgbx: correctedPixels, width: outputWidth, height: outputHeight, colorSpace: sRGB)

        let outputType: UTType = outputFormat == .png ? .png : .jpeg
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            outputType.identifier as CFString,
            1,
            nil
        ) else {
            throw CorrectionError.imageEncoding(outputURL)
        }

        // PNG is the default because it is lossless: a precision pre-correction should not
        // be followed by a lossy codec. JPEG is offered for smaller files.
        var encodingOptions: [CFString: Any] = [:]
        if outputFormat == .jpeg {
            encodingOptions[kCGImageDestinationLossyCompressionQuality] = 0.98
        }
        // The orientation is already applied, so the resolution axes follow the rotation.
        // A source without resolution metadata gets none (nothing is invented).
        if let dpi = sourceDPI {
            let swapped = orientation >= 5
            encodingOptions[kCGImagePropertyDPIWidth] = swapped ? dpi.height : dpi.width
            encodingOptions[kCGImagePropertyDPIHeight] = swapped ? dpi.width : dpi.height
        }
        CGImageDestinationAddImage(destination, correctedImage, encodingOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CorrectionError.imageEncoding(outputURL)
        }
        return interpretation
    }

    /// Resolution from the source metadata, if present and sensible.
    private static func resolution(from properties: [CFString: Any]?) -> (width: Double, height: Double)? {
        guard let width = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
              let height = (properties?[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, width > 0, height > 0 else {
            return nil
        }
        return (width, height)
    }

    /// Rejects empty or oversized images before any buffer is allocated.
    static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0,
              width <= Int.max / 8,
              height <= Int.max / (width * 8),
              width <= maximumPixelCount / height else {
            throw CorrectionError.bitmapContext
        }
    }

    /// Size after applying an EXIF orientation (5-8 swap the axes).
    static func orientedSize(width: Int, height: Int, orientation: Int) -> (width: Int, height: Int) {
        orientation >= 5 && orientation <= 8 ? (height, width) : (width, height)
    }

    /// Where source pixel (sx, sy) lands in the oriented output, as a pixel index
    /// `base + sx * xStride + sy * yStride`. EXIF values: 1 none, 2 mirror horizontally,
    /// 3 rotate 180, 4 mirror vertically, 5 transpose, 6 rotate 90 CW, 7 transverse, 8 rotate 90 CCW.
    static func orientationMapping(width w: Int, height h: Int, orientation: Int) -> (base: Int, xStride: Int, yStride: Int) {
        switch orientation {
        case 2: return (w - 1, -1, w)
        case 3: return (w * h - 1, -1, -w)
        case 4: return ((h - 1) * w, 1, -w)
        case 5: return (0, h, 1)
        case 6: return (h - 1, h, -1)
        case 7: return (w * h - 1, -h, -1)
        case 8: return ((w - 1) * h, -h, 1)
        default: return (0, 1, w)
        }
    }

    /// Applies the colour transform (none: just repack and orient) to a 16-bit big-endian RGBX Core Graphics buffer
    /// (8 bytes/pixel, the fourth component is padding) and returns 8-bit RGBX
    /// (4 bytes/pixel) with the EXIF orientation applied. Blocks of rows are converted in
    /// parallel (the transform is thread-safe: no cache, no shared scratch); each 16-bit
    /// result is rounded to 8 bits once. Internal so tests can check the buffer handling
    /// without image encoding.
    static func convertRGBX16Pixels(
        _ sourcePixels: Data,
        width: Int,
        height: Int,
        transform: ColorTransform?,
        orientation: Int = 1
    ) throws -> Data {
        try validateDimensions(width: width, height: height)
        guard sourcePixels.count == width * height * 8 else {
            throw CorrectionError.bitmapContext
        }

        let mapping = orientationMapping(width: width, height: height, orientation: orientation)
        let rowsPerBlock = max(1, 65_536 / width)
        let blockCount = (height + rowsPerBlock - 1) / rowsPerBlock
        var output = Data(count: width * height * 4)
        sourcePixels.withUnsafeBytes { sourceRaw in
            output.withUnsafeMutableBytes { outputRaw in
                guard let sourceStart = sourceRaw.baseAddress,
                      let outputBase = outputRaw.baseAddress else { return }
                // Each block reads its own rows and writes its own pixels: no overlap between
                // the concurrent iterations, and the buffers outlive concurrentPerform.
                nonisolated(unsafe) let sourceBase = sourceStart
                nonisolated(unsafe) let destination = outputBase.assumingMemoryBound(to: UInt8.self)
                DispatchQueue.concurrentPerform(iterations: blockCount) { block in
                    let firstRow = block * rowsPerBlock
                    let rows = min(rowsPerBlock, height - firstRow)
                    let pixelCount = rows * width
                    let input = UnsafeMutablePointer<UInt16>.allocate(capacity: pixelCount * 3)
                    let converted = UnsafeMutablePointer<UInt16>.allocate(capacity: pixelCount * 3)
                    defer {
                        input.deallocate()
                        converted.deallocate()
                    }
                    for row in 0..<rows {
                        let rowBase = sourceBase + (firstRow + row) * width * 8
                        let target = input + row * width * 3
                        for x in 0..<width {
                            let offset = x * 8
                            target[x * 3] = UInt16(bigEndian: rowBase.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                            target[x * 3 + 1] = UInt16(bigEndian: rowBase.loadUnaligned(fromByteOffset: offset + 2, as: UInt16.self))
                            target[x * 3 + 2] = UInt16(bigEndian: rowBase.loadUnaligned(fromByteOffset: offset + 4, as: UInt16.self))
                        }
                    }
                    if let transform {
                        transform.apply16(input, to: converted, pixelCount: pixelCount)
                    } else {
                        // No colour transform: only repack to 8 bit and orient.
                        converted.update(from: input, count: pixelCount * 3)
                    }
                    for row in 0..<rows {
                        let sy = firstRow + row
                        for x in 0..<width {
                            let index = mapping.base + x * mapping.xStride + sy * mapping.yStride
                            let pixel = destination + index * 4
                            let value = converted + (row * width + x) * 3
                            pixel[0] = UInt8((UInt32(value[0]) * 255 + 32767) / 65535)
                            pixel[1] = UInt8((UInt32(value[1]) * 255 + 32767) / 65535)
                            pixel[2] = UInt8((UInt32(value[2]) * 255 + 32767) / 65535)
                            pixel[3] = 0
                        }
                    }
                }
            }
        }
        return output
    }

    /// Name of the subfolder that holds the sessions in a folder chosen by the user.
    static let temporarySubfolderName = "SELPHY CP1500 Print temporary"

    /// Where the sessions live: a subfolder of the chosen folder, or of the system temporary folder.
    static func sessionRoot(in parent: URL?) -> URL {
        if let parent { return parent.appendingPathComponent(temporarySubfolderName, isDirectory: true) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("SELPHYCP1500Print", isDirectory: true)
    }

    static func makeSessionFolder(in parent: URL? = nil, now: Date = Date()) throws -> URL {
        let root = sessionRoot(in: parent)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Remove abandoned sessions older than one day. Only the app's own session folders (named
        // with a UUID) inside its own subfolder are removed: never source photos, never anything
        // else the user keeps in a folder they chose.
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let cutoff = now.addingTimeInterval(-24 * 60 * 60)
            for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
                let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                guard values?.isDirectory == true else { continue }
                let modified = values?.contentModificationDate ?? .distantPast
                if modified < cutoff {
                    try? FileManager.default.removeItem(at: entry)
                }
            }
        }

        let session = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
        return session
    }
}

extension RenderingIntent {
    var coreValue: selphy_intent {
        switch self {
        case .perceptual: SELPHY_INTENT_PERCEPTUAL
        case .relativeColorimetric: SELPHY_INTENT_RELATIVE_COLORIMETRIC
        case .saturation: SELPHY_INTENT_SATURATION
        }
    }
}
