import CoreGraphics
import Foundation

struct Lab3: Equatable {
    var l: Float
    var a: Float
    var b: Float

    var chroma: Float { (a * a + b * b).squareRoot() }
}

/// Per-pixel results of the model, at the analysis resolution (a reduced copy of the oriented
/// photo): the intended appearance (the photo read as sRGB), the appearance predicted for the
/// corrected values, and the dE00 between them. Every overlay and statistic comes from these.
struct PixelMaps {
    let width: Int
    let height: Int
    let deltaE: [Float]
    /// L*, a*, b* per pixel (D50), three values per pixel.
    let intendedLab: [Float]
    let predictedLab: [Float]

    var count: Int { width * height }

    func intended(at index: Int) -> Lab3 {
        Lab3(l: intendedLab[3 * index], a: intendedLab[3 * index + 1], b: intendedLab[3 * index + 2])
    }

    func predicted(at index: Int) -> Lab3 {
        Lab3(l: predictedLab[3 * index], a: predictedLab[3 * index + 1], b: predictedLab[3 * index + 2])
    }

    /// How much chroma (C*) the print loses compared with the intended colour; positive = duller.
    func chromaLoss(at index: Int) -> Float {
        intended(at: index).chroma - predicted(at: index).chroma
    }
}

/// What is under the pointer: the colour the photo should have, the colour predicted in print.
struct PixelReading: Equatable {
    var x: Int
    var y: Int
    var intended: Lab3
    var predicted: Lab3
    var deltaE: Float
}

enum PreviewGeometry {
    /// Size of the preview content. `factor` is points per preview pixel (nil = fit the area); a
    /// zoom smaller than the fitted size keeps the fitted size.
    static func contentSize(imageSize: CGSize, available: CGSize, factor: Double?) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, available.width > 0, available.height > 0 else { return available }
        let fitScale = min(available.width / imageSize.width, available.height / imageSize.height)
        let fit = CGSize(width: imageSize.width * fitScale, height: imageSize.height * fitScale)
        guard let factor else { return fit }
        let zoomed = CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
        return zoomed.width > fit.width ? zoomed : fit
    }

    /// The analysis pixel under a position given as fractions (0...1) of the image, or nil outside.
    static func reading(maps: PixelMaps, u: Double, v: Double) -> PixelReading? {
        guard maps.width > 0, maps.height > 0, u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        let x = min(maps.width - 1, Int(u * Double(maps.width)))
        let y = min(maps.height - 1, Int(v * Double(maps.height)))
        let index = y * maps.width + x
        return PixelReading(x: x, y: y, intended: maps.intended(at: index), predicted: maps.predicted(at: index), deltaE: maps.deltaE[index])
    }
}
