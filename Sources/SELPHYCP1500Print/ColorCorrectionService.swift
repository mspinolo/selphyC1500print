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
    }

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
                return "Sono supportate solo immagini RGB (JPEG, JPEG XL, PNG, TIFF): \(url.lastPathComponent)"
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

                try correct(
                    sourceURL: sourceURL,
                    outputURL: outputURL,
                    printerICC: printerICC,
                    intent: intent,
                    blackPointCompensation: blackPointCompensation,
                    outputFormat: outputFormat,
                    transformCache: &transformCache
                )
                outputs.append(outputURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: sessionFolder)
            throw error
        }

        return Result(files: outputs, folder: sessionFolder)
    }

    private static func correct(
        sourceURL: URL,
        outputURL: URL,
        printerICC: Data,
        intent: RenderingIntent,
        blackPointCompensation: Bool,
        outputFormat: OutputFormat,
        transformCache: inout [Data: ColorTransform]
    ) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = makeOrientedImage(from: source) else {
            throw CorrectionError.unreadableImage(sourceURL)
        }

        guard let imageColorSpace = image.colorSpace,
              imageColorSpace.model == .rgb,
              imageColorSpace.numberOfComponents == 3 else {
            throw CorrectionError.unsupportedColorSpace(sourceURL)
        }

        // An embedded profile is used as the source; images without one are assumed sRGB.
        let embeddedICC = imageColorSpace.copyICCData() as Data?
        let sourceColorSpace = embeddedICC == nil ? CGColorSpace(name: CGColorSpace.sRGB)! : imageColorSpace

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
        // Bound allocations before multiplying dimensions. The source is decoded to
        // 16 bits per component (8 bytes/pixel, RGBX) so that 16-bit and linear
        // sources (PNG, TIFF) keep their precision; the result is 4 bytes/pixel.
        let maximumPixelCount = 100_000_000
        guard width > 0, height > 0,
              width <= Int.max / 8,
              height <= Int.max / (width * 8),
              width <= maximumPixelCount / height else {
            throw CorrectionError.bitmapContext
        }
        let bytesPerRow = width * 4
        let sourceBytesPerRow = width * 8
        let byteCount = sourceBytesPerRow * height

        var sourcePixels = Data(count: byteCount)
        let sourceContextCreated = sourcePixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 16,
                bytesPerRow: sourceBytesPerRow,
                space: sourceColorSpace,
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

        let correctedPixels = try convertRGBX16Pixels(
            sourcePixels,
            width: width,
            height: height,
            transform: transform
        )

        // Deliberately re-tag the corrected numeric RGB values as sRGB. The
        // SELPHY has a fixed internal color pipeline; the profile is used to
        // pre-adjust its expected input values, not installed in the printer.
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: correctedPixels as CFData),
              let correctedImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
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
        // be followed by a lossy codec. JPEG is offered for smaller files; its real
        // penalty has not been measured yet (ROADMAP M2).
        let encodingOptions: CFDictionary? = outputFormat == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.98] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, correctedImage, encodingOptions)
        guard CGImageDestinationFinalize(destination) else {
            throw CorrectionError.imageEncoding(outputURL)
        }
    }

    /// Applies the colour transform to a 16-bit big-endian RGBX Core Graphics buffer
    /// (8 bytes/pixel, the fourth component is padding) and returns 8-bit RGBX
    /// (4 bytes/pixel). Rows are converted one at a time to bound memory; the 16-bit
    /// result is rounded to 8 bits once, at the end. Internal so tests can check the
    /// buffer handling without image encoding.
    static func convertRGBX16Pixels(
        _ sourcePixels: Data,
        width: Int,
        height: Int,
        transform: ColorTransform
    ) throws -> Data {
        guard width > 0, height > 0,
              width <= Int.max / 8,
              height <= Int.max / (width * 8),
              sourcePixels.count == width * height * 8 else {
            throw CorrectionError.bitmapContext
        }

        var output = Data(count: width * height * 4)
        var rowIn = [UInt16](repeating: 0, count: width * 3)
        var rowOut = [UInt16](repeating: 0, count: width * 3)
        sourcePixels.withUnsafeBytes { sourceRaw in
            let src = sourceRaw.bindMemory(to: UInt8.self)
            output.withUnsafeMutableBytes { outputRaw in
                let dst = outputRaw.bindMemory(to: UInt8.self)
                for y in 0..<height {
                    let sourceBase = y * width * 8
                    for x in 0..<width {
                        for channel in 0..<3 {
                            let offset = sourceBase + x * 8 + channel * 2
                            rowIn[x * 3 + channel] = (UInt16(src[offset]) << 8) | UInt16(src[offset + 1])
                        }
                    }
                    rowIn.withUnsafeBufferPointer { input in
                        rowOut.withUnsafeMutableBufferPointer { converted in
                            transform.apply16(input.baseAddress!, to: converted.baseAddress!, pixelCount: width)
                        }
                    }
                    let destinationBase = y * width * 4
                    for x in 0..<width {
                        for channel in 0..<3 {
                            let value = UInt32(rowOut[x * 3 + channel])
                            dst[destinationBase + x * 4 + channel] = UInt8((value * 255 + 32767) / 65535)
                        }
                        dst[destinationBase + x * 4 + 3] = 0
                    }
                }
            }
        }
        return output
    }

    /// Decodes the first image. Without an EXIF/TIFF orientation the full-precision decode is
    /// used (keeps 16-bit data). When a rotation or mirroring is needed the thumbnail API is
    /// used to apply it, which yields 8-bit data (ROADMAP M2: 16-bit oriented decode).
    private static func makeOrientedImage(from source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 1
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 1
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if orientation == 1 {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)
            ] as CFDictionary
        )
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
