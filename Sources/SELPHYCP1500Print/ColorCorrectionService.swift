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
                return "Per questa prima versione è richiesto un JPEG RGB: \(url.lastPathComponent)"
            case .profileLoad(let detail):
                return "Impossibile caricare il profilo ICC: \(detail)"
            case .transformCreation(let detail):
                return "Impossibile creare la trasformazione colore: \(detail)"
            case .bitmapContext:
                return "Impossibile creare il buffer bitmap RGB."
            case .imageEncoding(let url):
                return "Impossibile generare il JPEG temporaneo: \(url.lastPathComponent)"
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
            let source = sourceICC ?? Data()
            let status: selphy_status = source.withUnsafeBytes { sourceBytes in
                printerICC.withUnsafeBytes { printerBytes in
                    selphy_transform_create(
                        sourceBytes.bindMemory(to: UInt8.self).baseAddress,
                        sourceBytes.count,
                        printerBytes.bindMemory(to: UInt8.self).baseAddress,
                        printerBytes.count,
                        &options,
                        &created
                    )
                }
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

        func apply(_ input: UnsafePointer<UInt8>, to output: UnsafeMutablePointer<UInt8>, pixelCount: Int) {
            selphy_transform_apply_rgb8(handle, input, output, pixelCount)
        }
    }

    static func prepareCopies(
        from sourceURLs: [URL],
        printerProfileURL: URL,
        intent: RenderingIntent,
        blackPointCompensation: Bool
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
                    .appendingPathExtension("jpg")

                try correct(
                    sourceURL: sourceURL,
                    outputURL: outputURL,
                    printerICC: printerICC,
                    intent: intent,
                    blackPointCompensation: blackPointCompensation,
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
        // Bound allocations before multiplying dimensions. A single RGBX
        // buffer is 4 bytes/pixel and the conversion temporarily holds both
        // source and destination buffers.
        let maximumPixelCount = 100_000_000
        guard width > 0, height > 0,
              width <= Int.max / 4,
              height <= Int.max / (width * 4),
              width <= maximumPixelCount / height else {
            throw CorrectionError.bitmapContext
        }
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height

        var sourcePixels = Data(count: byteCount)
        let sourceContextCreated = sourcePixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: sourceColorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)).rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard sourceContextCreated else { throw CorrectionError.bitmapContext }

        let correctedPixels = try convertRGBXPixels(
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

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CorrectionError.imageEncoding(outputURL)
        }

        CGImageDestinationAddImage(
            destination,
            correctedImage,
            [kCGImageDestinationLossyCompressionQuality: 0.98] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw CorrectionError.imageEncoding(outputURL)
        }
    }

    /// Applies the colour transform to a 32-bit big-endian RGBX Core Graphics
    /// buffer (the fourth byte is padding), packing it to 24-bit RGB for the core.
    /// Kept internal so tests can check the buffer handling without JPEG encoding.
    static func convertRGBXPixels(
        _ sourcePixels: Data,
        width: Int,
        height: Int,
        transform: ColorTransform
    ) throws -> Data {
        guard width > 0, height > 0,
              width <= Int.max / 4,
              height <= Int.max / (width * 4),
              sourcePixels.count == width * height * 4 else {
            throw CorrectionError.bitmapContext
        }

        let pixelCount = width * height
        var packedSource = [UInt8](repeating: 0, count: pixelCount * 3)
        sourcePixels.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt8.self)
            packedSource.withUnsafeMutableBufferPointer { dst in
                for pixel in 0..<pixelCount {
                    dst[pixel * 3] = src[pixel * 4]
                    dst[pixel * 3 + 1] = src[pixel * 4 + 1]
                    dst[pixel * 3 + 2] = src[pixel * 4 + 2]
                }
            }
        }

        var packedCorrected = [UInt8](repeating: 0, count: pixelCount * 3)
        packedSource.withUnsafeBufferPointer { input in
            packedCorrected.withUnsafeMutableBufferPointer { output in
                transform.apply(input.baseAddress!, to: output.baseAddress!, pixelCount: pixelCount)
            }
        }

        var correctedPixels = Data(count: sourcePixels.count)
        correctedPixels.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: UInt8.self)
            packedCorrected.withUnsafeBufferPointer { src in
                for pixel in 0..<pixelCount {
                    dst[pixel * 4] = src[pixel * 3]
                    dst[pixel * 4 + 1] = src[pixel * 3 + 1]
                    dst[pixel * 4 + 2] = src[pixel * 3 + 2]
                    dst[pixel * 4 + 3] = 0
                }
            }
        }
        return correctedPixels
    }

    private static func makeOrientedImage(from source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 1
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 1
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
