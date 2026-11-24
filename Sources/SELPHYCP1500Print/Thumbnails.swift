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
    static func make(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Square thumbnail, loaded off the main thread.
struct ThumbnailView: View {
    let url: URL
    let side: CGFloat
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: url) {
            let pixels = Int(side * 3)
            let target = url
            image = await Task.detached(priority: .utility) { Thumbnail.make(url: target, maxPixel: pixels) }.value
        }
        .accessibilityHidden(true)
    }
}
