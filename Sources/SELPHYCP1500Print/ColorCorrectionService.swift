import Foundation
import AppKit
import ColorSync
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Experimental pre-correction for the SELPHY's fixed internal color pipeline.
///
/// The Farbenwerk profile describes the complete printer response. We convert
/// source-image RGB through PCS into the profile's RGB input values, then tag
/// those numeric values as sRGB for the SELPHY's normal fixed processing path.
/// This workflow must be validated with physical prints before being used
/// for production output.
enum ColorCorrectionService {
    struct Result {
        let files: [URL]
        let folder: URL
    }

    enum CorrectionError: LocalizedError {
        case unreadableImage(URL)
        case unsupportedColorSpace(URL)
        case profileLoad(String)
        case transformCreation
        case transformFailed(URL)
        case bitmapContext
        case imageEncoding(URL)

        var errorDescription: String? {
            switch self {
            case .unreadableImage(let url):
                return "Impossibile leggere l'immagine: \(url.lastPathComponent)"
            case .unsupportedColorSpace(let url):
                return "Per questa prima versione è richiesto un JPEG RGB: \(url.lastPathComponent)"
            case .profileLoad(let detail):
                return "ColorSync non riesce a caricare il profilo: \(detail)"
            case .transformCreation:
                return "ColorSync non è riuscito a creare la trasformazione ICC."
            case .transformFailed(let url):
                return "Conversione ColorSync non riuscita per \(url.lastPathComponent)."
            case .bitmapContext:
                return "Impossibile creare il buffer bitmap RGB."
            case .imageEncoding(let url):
                return "Impossibile generare il JPEG temporaneo: \(url.lastPathComponent)"
            }
        }
    }

    static func prepareCopies(
        from sourceURLs: [URL],
        printerProfileURL: URL,
        intent: RenderingIntent,
        blackPointCompensation: Bool
    ) throws -> Result {
        let printerProfile = try loadProfile(at: printerProfileURL)
        let sessionFolder = try makeSessionFolder()
        var outputs: [URL] = []

        do {
            for sourceURL in sourceURLs {
                let hasAccess = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }

                let outputURL = sessionFolder
                    .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent + "_SELPHY-test")
                    .appendingPathExtension("jpg")

                try correct(
                    sourceURL: sourceURL,
                    outputURL: outputURL,
                    printerProfile: printerProfile,
                    intent: intent,
                    blackPointCompensation: blackPointCompensation
                )
                outputs.append(outputURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: sessionFolder)
            throw error
        }

        return Result(files: outputs, folder: sessionFolder)
    }

    private static func loadProfile(at url: URL) throws -> ColorSyncProfile {
        var cfError: Unmanaged<CFError>?
        guard let unmanaged = ColorSyncProfileCreateWithURL(url as CFURL, &cfError) else {
            let detail = cfError?.takeRetainedValue().localizedDescription ?? "errore sconosciuto"
            throw CorrectionError.profileLoad(detail)
        }
        return unmanaged.takeRetainedValue()
    }

    private static func correct(
        sourceURL: URL,
        outputURL: URL,
        printerProfile: ColorSyncProfile,
        intent: RenderingIntent,
        blackPointCompensation: Bool
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

        let sourceProfile: ColorSyncProfile
        if let iccData = imageColorSpace.copyICCData(),
           let profile = ColorSyncProfileCreate(iccData, nil)?.takeRetainedValue() {
            sourceProfile = profile
        } else {
            sourceProfile = try makeSRGBProfile()
        }

        guard let transform = makeTransform(
            sourceProfile: sourceProfile,
            printerProfile: printerProfile,
            intent: intent,
            blackPointCompensation: blackPointCompensation
        ) else {
            throw CorrectionError.transformCreation
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * 3
        let byteCount = bytesPerRow * height

        var sourcePixels = Data(count: byteCount)
        let sourceContextCreated = sourcePixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: imageColorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard sourceContextCreated else { throw CorrectionError.bitmapContext }

        var correctedPixels = Data(count: byteCount)
        let converted = correctedPixels.withUnsafeMutableBytes { destination in
            sourcePixels.withUnsafeBytes { source in
                ColorSyncTransformConvert(
                    transform,
                    width,
                    height,
                    destination.baseAddress,
                    kColorSync8BitInteger,
                    kColorSyncAlphaNone,
                    bytesPerRow,
                    source.baseAddress,
                    kColorSync8BitInteger,
                    kColorSyncAlphaNone,
                    bytesPerRow,
                    nil
                )
            }
        }
        guard converted else { throw CorrectionError.transformFailed(sourceURL) }

        // Deliberately re-tag the corrected numeric RGB values as sRGB. The
        // SELPHY has a fixed internal color pipeline; the profile is used to
        // pre-adjust its expected input values, not installed in the printer.
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: correctedPixels as CFData),
              let correctedImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 24,
                bytesPerRow: bytesPerRow,
                space: sRGB,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
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

    private static func makeSRGBProfile() throws -> ColorSyncProfile {
        guard let unmanaged = ColorSyncProfileCreateWithName(kColorSyncSRGBProfile.takeUnretainedValue()) else {
            throw CorrectionError.profileLoad("profilo sRGB di sistema non disponibile")
        }
        return unmanaged.takeRetainedValue()
    }

    private static func makeTransform(
        sourceProfile: ColorSyncProfile,
        printerProfile: ColorSyncProfile,
        intent: RenderingIntent,
        blackPointCompensation: Bool
    ) -> ColorSyncTransform? {
        let profileKey = kColorSyncProfile.takeUnretainedValue()
        let intentKey = kColorSyncRenderingIntent.takeUnretainedValue()
        let tagKey = kColorSyncTransformTag.takeUnretainedValue()
        let bpcKey = kColorSyncBlackPointCompensation.takeUnretainedValue()

        let sourceEntry: [CFString: Any] = [
            profileKey: sourceProfile,
            intentKey: intent.colorSyncValue,
            tagKey: kColorSyncTransformDeviceToPCS.takeUnretainedValue(),
            bpcKey: blackPointCompensation
        ]
        let destinationEntry: [CFString: Any] = [
            profileKey: printerProfile,
            intentKey: intent.colorSyncValue,
            tagKey: kColorSyncTransformPCSToDevice.takeUnretainedValue(),
            bpcKey: blackPointCompensation
        ]

        let sequence = [sourceEntry as CFDictionary, destinationEntry as CFDictionary] as CFArray
        return ColorSyncTransformCreate(sequence, nil)?.takeRetainedValue()
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

private extension RenderingIntent {
    var colorSyncValue: CFString {
        switch self {
        case .perceptual:
            kColorSyncRenderingIntentPerceptual.takeUnretainedValue()
        case .relativeColorimetric:
            kColorSyncRenderingIntentRelative.takeUnretainedValue()
        case .saturation:
            kColorSyncRenderingIntentSaturation.takeUnretainedValue()
        }
    }
}
