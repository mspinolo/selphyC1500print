import CoreGraphics
import Foundation

/// The dE00 range of the colour ramp of the deviation map: transparent up to `low`, red from `high`.
struct DeltaEScale: Equatable {
    var low: Float = 1
    var high: Float = 6

    static let standard = DeltaEScale()

    /// Keeps the range usable: low within 0...49, high at least 0.5 above it and at most 50.
    func clamped() -> DeltaEScale {
        var result = self
        result.low = max(0, min(result.low, 49))
        result.high = min(50, max(result.low + 0.5, result.high))
        return result
    }
}

/// Translucent overlays built from the per-pixel results (premultiplied RGBA, sRGB).
enum Overlays {
    typealias RGBA = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

    /// Ramp position (0 = at `low`, 1 = at `high`) -> green component (0...255) and alpha (0...255)
    /// of the overlay colour (red is always 255): yellow turning to red, more opaque as it grows.
    static func ramp(_ t: Float) -> (green: Float, alpha: Float) {
        (255 * (1 - t), 90 + 130 * t)
    }

    static func heatColor(deltaE: Float, scale: DeltaEScale = .standard) -> RGBA {
        let range = scale.clamped()
        guard deltaE.isFinite, deltaE > range.low else { return (0, 0, 0, 0) }
        let t = min(1, (deltaE - range.low) / (range.high - range.low))
        let (green, alpha) = ramp(t)
        let k = alpha / 255
        return (UInt8((255 * k).rounded()), UInt8((green * k).rounded()), 0, UInt8(alpha.rounded()))
    }

    static let shadowColor: RGBA = (0, 138, 185, 185)    // cyan, 72% opaque (premultiplied)
    static let gamutColor: RGBA = (190, 82, 0, 190)      // orange, 75% opaque (premultiplied)
    private static let clear: RGBA = (0, 0, 0, 0)

    static func image(width: Int, height: Int, pixel: (Int) -> RGBA) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let target = raw.bindMemory(to: UInt8.self)
            for i in 0..<(width * height) {
                let color = pixel(i)
                target[i * 4] = color.r
                target[i * 4 + 1] = color.g
                target[i * 4 + 2] = color.b
                target[i * 4 + 3] = color.a
            }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    static func heatMap(_ maps: PixelMaps, scale: DeltaEScale) -> CGImage? {
        image(width: maps.width, height: maps.height) { heatColor(deltaE: maps.deltaE[$0], scale: scale) }
    }

    /// Pixels whose intended lightness is below the darkest tone the printer reproduces
    /// (plus `margin` L*): their shadows are merged or compressed in the print.
    static func isTooDark(_ maps: PixelMaps, at index: Int, darkestL: Double, margin: Double) -> Bool {
        Double(maps.intendedLab[3 * index]) < darkestL + margin
    }

    static func shadowMask(_ maps: PixelMaps, darkestL: Double, margin: Double) -> CGImage? {
        image(width: maps.width, height: maps.height) {
            isTooDark(maps, at: $0, darkestL: darkestL, margin: margin) ? shadowColor : clear
        }
    }

    static func shadowShare(_ maps: PixelMaps, darkestL: Double, margin: Double) -> Double {
        guard maps.count > 0 else { return 0 }
        var hits = 0
        for i in 0..<maps.count where isTooDark(maps, at: i, darkestL: darkestL, margin: margin) { hits += 1 }
        return Double(hits) / Double(maps.count)
    }

    /// Pixels whose chroma the print loses by more than `minimumLoss` C*: colours more saturated
    /// than the printer can reach (clipped or compressed).
    static func gamutMask(_ maps: PixelMaps, minimumLoss: Float) -> CGImage? {
        image(width: maps.width, height: maps.height) {
            maps.chromaLoss(at: $0) > minimumLoss ? gamutColor : clear
        }
    }

    static func gamutShare(_ maps: PixelMaps, minimumLoss: Float) -> Double {
        guard maps.count > 0 else { return 0 }
        var hits = 0
        for i in 0..<maps.count where maps.chromaLoss(at: i) > minimumLoss { hits += 1 }
        return Double(hits) / Double(maps.count)
    }
}
