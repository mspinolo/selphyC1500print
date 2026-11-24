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

        var errorDescription: String? {
            switch self {
            case .unreadableImage(let url):
                return "Impossibile leggere l'immagine: \(url.lastPathComponent)"
            case .unsupportedColorSpace(let url):
                return "Spazio colore non supportato (sono accettati RGB, scala di grigi, CMYK, Lab): \(url.lastPathComponent)"
            case .profileLoad(let detail):
                return "Impossibile caricare il profilo ICC: \(detail)"
            case .transformCreation(let detail):
                return "Impossibile creare la trasformazione colore: \(detail)"
            case .bitmapContext:
                return "Impossibile creare il buffer bitmap RGB."
            case .imageEncoding(let url):
                return "Impossibile generare l'immagine temporanea: \(url.lastPathComponent)"
            }
        }
    }

    /// Owns a `selphy_transform`. Immutable after creation, so it can be shared across
    /// the images of one batch that use the same source profile.
    final class ColorTransform {
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
        outputFormat: OutputFormat = .png
    ) throws -> Result {
        let printerICC: Data
        do {
            printerICC = try Data(contentsOf: printerProfileURL)
        } catch {
            throw CorrectionError.profileLoad(error.localizedDescription)
        }
        // Fail before touching any source if the printer profile is unusable.
        _ = try ColorTransform(
            sourceICC: nil,
            printerICC: printerICC,
            intent: intent,
            blackPointCompensation: blackPointCompensation
        )

        let sessionFolder = try makeSessionFolder()
        var transformCache: [Data: ColorTransform] = [:]
        var outputs: [URL] = []
        var assumedSRGB: [URL] = []
        var converted: [URL] = []

        do {
            for sourceURL in sourceURLs {
                let hasAccess = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }

                let uniqueSuffix = String(UUID().uuidString.prefix(8))
                let outputURL = sessionFolder
                    .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent + "_SELPHY-test-\(uniqueSuffix)")
                    .appendingPathExtension(outputFormat.fileExtension)

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
            assumedSRGBSources: assumedSRGB, convertedSources: converted
        )
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
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CorrectionError.unreadableImage(sourceURL)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let orientation = (1...8).contains(rawOrientation) ? rawOrientation : 1
        let sourceDPI = Self.resolution(from: properties)

        guard let imageColorSpace = image.colorSpace else {
            throw CorrectionError.unsupportedColorSpace(sourceURL)
        }

        // RGB sources use their embedded profile; without one they are assumed sRGB. Grayscale, CMYK, Lab
        // and indexed sources are converted to sRGB by Core Graphics while decoding, using
        // their own profile, and then go through the same transform.
        let interpretation: SourceInterpretation
        var embeddedICC: Data?
        switch imageColorSpace.model {
        case .rgb where imageColorSpace.numberOfComponents == 3:
            embeddedICC = imageColorSpace.copyICCData() as Data?
            interpretation = embeddedICC == nil ? .assumedSRGB : .embeddedProfile
        case .monochrome, .cmyk, .lab, .indexed, .XYZ:
            interpretation = .convertedToSRGB
        default:
            throw CorrectionError.unsupportedColorSpace(sourceURL)
        }
        let decodeSpace: CGColorSpace
        if interpretation != .embeddedProfile {
            embeddedICC = nil
            decodeSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        } else {
            decodeSpace = imageColorSpace
        }

        let cacheKey = embeddedICC ?? Data()
        let transform: ColorTransform
        if let cached = transformCache[cacheKey] {
            transform = cached
        } else {
            transform = try ColorTransform(
                sourceICC: embeddedICC,
                printerICC: printerICC,
                intent: intent,
                blackPointCompensation: blackPointCompensation
            )
            transformCache[cacheKey] = transform
        }

        let width = image.width
        let height = image.height
        try validateDimensions(width: width, height: height)
        let (outputWidth, outputHeight) = orientedSize(width: width, height: height, orientation: orientation)
        let sourceBytesPerRow = width * 8

        // The source is decoded to 16 bits per component (8 bytes/pixel, RGBX) so that 16-bit
        // and linear sources keep their precision; the result is 4 bytes/pixel.
        var sourcePixels = Data(count: sourceBytesPerRow * height)
        let sourceContextCreated = sourcePixels.withUnsafeMutableBytes { rawBuffer -> Bool in
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
        guard sourceContextCreated else { throw CorrectionError.bitmapContext }

        // EXIF orientation is applied while the converted pixels are written, at full precision.
        let correctedPixels = try convertRGBX16Pixels(
            sourcePixels,
            width: width,
            height: height,
            transform: transform,
            orientation: orientation
        )
        sourcePixels = Data()

        // Deliberately re-tag the corrected numeric RGB values as sRGB. The
        // SELPHY has a fixed internal color pipeline; the profile is used to
        // pre-adjust its expected input values, not installed in the printer.
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: correctedPixels as CFData),
              let correctedImage = CGImage(
                width: outputWidth,
                height: outputHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: outputWidth * 4,
                space: sRGB,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            throw CorrectionError.bitmapContext
        }

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

    /// Applies the colour transform to a 16-bit big-endian RGBX Core Graphics buffer
    /// (8 bytes/pixel, the fourth component is padding) and returns 8-bit RGBX
    /// (4 bytes/pixel) with the EXIF orientation applied. Blocks of rows are converted in
    /// parallel (the transform is thread-safe: no cache, no shared scratch); each 16-bit
    /// result is rounded to 8 bits once. Internal so tests can check the buffer handling
    /// without image encoding.
    static func convertRGBX16Pixels(
        _ sourcePixels: Data,
        width: Int,
        height: Int,
        transform: ColorTransform,
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
                guard let sourceBase = sourceRaw.baseAddress,
                      let outputBase = outputRaw.baseAddress else { return }
                let destination = outputBase.assumingMemoryBound(to: UInt8.self)
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
                    transform.apply16(input, to: converted, pixelCount: pixelCount)
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

    private static func makeSessionFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SELPHYCP1500Print", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Remove abandoned sessions older than one day; never touch source photos.
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            for entry in entries {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
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
