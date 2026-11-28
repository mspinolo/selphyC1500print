import SwiftUI
import ImageIO

/// Image files the app accepts (also used to filter dropped files).
enum PhotoFiles {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "jxl"]

    static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}

enum Thumbnail {
    /// A small, orientation-corrected rendering of the image, or nil if it cannot be read.
    /// Tries a decoded-and-scaled thumbnail first, then the thumbnail embedded in the file, and as
    /// a last resort decodes the whole image and scales it, so that one odd file does not leave a
    /// placeholder.
    static func make(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        for key in [kCGImageSourceCreateThumbnailFromImageAlways, kCGImageSourceCreateThumbnailFromImageIfAbsent] {
            let options: [CFString: Any] = [
                key: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
        }
        guard let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return scaled(full, maxPixel: maxPixel)
    }

    /// `image` reduced so that its longest side is `maxPixel` (never enlarged), drawn in sRGB.
    static func scaled(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        let factor = min(1, Double(maxPixel) / Double(max(1, longest)))
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// Thumbnails already made, so that hiding the photo list, scrolling or reselecting does not decode
/// the files again. Keyed by path, modification date and size; NSCache drops entries under memory
/// pressure.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 300
        return cache
    }()

    static func key(url: URL, maxPixel: Int) -> String {
        // Read from the file system: URL objects cache resource values.
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return "\(url.path)|\(modified?.timeIntervalSinceReferenceDate ?? 0)|\(maxPixel)"
    }

    func image(for key: String) -> CGImage? { cache.object(forKey: key as NSString)?.image }

    func insert(_ image: CGImage, for key: String) { cache.setObject(Entry(image), forKey: key as NSString) }

    func removeAll() { cache.removeAllObjects() }

    /// The cached thumbnail or a new one (stored for next time).
    func thumbnail(url: URL, maxPixel: Int) -> CGImage? {
        let key = Self.key(url: url, maxPixel: maxPixel)
        if let cached = image(for: key) { return cached }
        guard let made = Thumbnail.make(url: url, maxPixel: maxPixel) else { return nil }
        insert(made, for: key)
        return made
    }
}

/// Square thumbnail, loaded off the main thread (and kept in `ThumbnailCache`).
struct ThumbnailView: View {
    let url: URL
    let side: CGFloat
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: failed ? "exclamationmark.triangle" : "photo")
                    .foregroundStyle(failed ? Color.orange : Color.secondary)
                    .accessibilityLabel(failed ? tr("Cannot be read") : "")
                    .accessibilityHidden(!failed)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: url) {
            let pixels = Int(side * 3)
            let target = url
            failed = false
            image = await Task.detached(priority: .utility) {
                ThumbnailCache.shared.thumbnail(url: target, maxPixel: pixels)
            }.value
            failed = image == nil
        }
        .accessibilityHidden(true)
    }
}

/// Keeps the sandbox access of the photos the user picked or dropped for as long as they stay in
/// the list (the system grants access to a chosen file only while it is held open this way).
@MainActor
final class PhotoAccess {
    private var held: [URL: Bool] = [:]

    func retain(_ url: URL) {
        guard held[url] == nil else { return }
        held[url] = url.startAccessingSecurityScopedResource()
    }

    func release(_ url: URL) {
        if held.removeValue(forKey: url) == true { url.stopAccessingSecurityScopedResource() }
    }

    func releaseAll() {
        for url in Array(held.keys) { release(url) }
    }

    var count: Int { held.count }
}
