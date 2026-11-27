import CoreGraphics
import Foundation
import ImageIO
import SELPHYColorCore
import UniformTypeIdentifiers

/// The validation chart (port of validation/chart_layout.py and make_chart.py): ColorChecker
/// colours as sRGB numbers, grey ramp, near-black steps, primaries, skin and nature colours, four
/// mid-greys for sheet uniformity, unprinted paper areas and four corner marks (the large one is
/// top-left). Portrait 100 x 148 mm, 1181 x 1748 px; no text. The tests check that it matches the
/// committed validation/charts/selphy_chart_v1.png and .json exactly.
struct ValidationChart: Equatable, Sendable {
    struct Patch: Codable, Equatable, Sendable {
        var id: String
        var group: String
        var name: String
        var srgb: [Int]
        /// x, y, width, height in chart pixels (top-left origin).
        var rect: [Int]
        var labIntended: [Double]

        enum CodingKeys: String, CodingKey {
            case id, group, name, srgb, rect
            case labIntended = "lab_intended"
        }
    }

    struct Fiducial: Codable, Equatable, Sendable {
        var name: String
        var centre: [Double]
        var size: Double
    }

    struct WhiteSample: Codable, Equatable, Sendable {
        var name: String
        var rect: [Int]
    }

    static let version = 1
    static let designWidth = 1181, designHeight = 1748
    private static let margin = 80.0
    private static let fiducialSmall = 56.0, fiducialBig = 84.0

    let width: Int
    let height: Int
    let patches: [Patch]
    let fiducials: [Fiducial]
    let whiteSamples: [WhiteSample]

    static let standard = ValidationChart()

    /// Distance top-left to top-right mark over top-left to bottom-left mark.
    var aspect: Double {
        let c = fiducials.map(\.centre)
        return hypot(c[1][0] - c[0][0], c[1][1] - c[0][1]) / hypot(c[3][0] - c[0][0], c[3][1] - c[0][1])
    }

    // MARK: Layout (chart_layout.py)

    private static let colorChecker: [(String, [Int])] = [
        ("dark skin", [115, 82, 68]), ("light skin", [194, 150, 130]), ("blue sky", [98, 122, 157]),
        ("foliage", [87, 108, 67]), ("blue flower", [133, 128, 177]), ("bluish green", [103, 189, 170]),
        ("orange", [214, 126, 44]), ("purplish blue", [80, 91, 166]), ("moderate red", [193, 90, 99]),
        ("purple", [94, 60, 108]), ("yellow green", [157, 188, 64]), ("orange yellow", [224, 163, 46]),
        ("blue", [56, 61, 150]), ("green", [70, 148, 73]), ("red", [175, 54, 60]),
        ("yellow", [231, 199, 31]), ("magenta", [187, 86, 149]), ("cyan", [8, 133, 161]),
        ("white", [243, 243, 242]), ("neutral 8", [200, 200, 200]), ("neutral 6.5", [160, 160, 160]),
        ("neutral 5", [122, 122, 121]), ("neutral 3.5", [85, 85, 85]), ("black", [52, 52, 52]),
    ]
    private static let darkSteps = [0, 2, 4, 6, 8, 12, 16, 24, 32, 48]
    private static let primaries: [(String, [Int])] = [
        ("red", [255, 0, 0]), ("green", [0, 255, 0]), ("blue", [0, 0, 255]),
        ("cyan", [0, 255, 255]), ("magenta", [255, 0, 255]), ("yellow", [255, 255, 0]),
    ]
    private static let skin: [[Int]] = [[255, 224, 196], [234, 192, 160], [205, 150, 115], [170, 115, 80], [125, 80, 55], [90, 58, 42]]
    private static let nature: [(String, [Int])] = [
        ("sky", [105, 150, 205]), ("deep sky", [30, 80, 170]), ("foliage", [60, 110, 50]),
        ("grass", [110, 160, 60]), ("sand", [205, 185, 140]), ("rust", [160, 80, 50]),
    ]
    private static let midGrey = [128, 128, 128]

    /// Python's round(): half to even.
    private static func pyRound(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }

    /// Rects of a centred row of equal patches (chart_layout._row).
    private static func row(_ n: Int, y: Double, w: Double, h: Double, gap: Double) -> [[Double]] {
        let contentWidth = Double(designWidth) - 2 * margin
        let total = Double(n) * w + Double(n - 1) * gap
        let x0 = margin + (contentWidth - total) / 2
        return (0..<n).map { [x0 + Double($0) * (w + gap), y, w, h] }
    }

    init() {
        width = Self.designWidth
        height = Self.designHeight
        var list: [(String, String, String, [Int], [Double])] = []
        func add(_ group: String, _ items: [(String, [Int])], _ rects: [[Double]]) {
            for (index, (item, rect)) in zip(items, rects).enumerated() {
                list.append((String(format: "%@-%02d", group, index + 1), group, item.0, item.1, rect))
            }
        }
        var ccRects: [[Double]] = []
        for r in 0..<4 { ccRects += Self.row(6, y: 200 + Double(r) * 167, w: 150, h: 150, gap: 17) }
        add("colorchecker", Self.colorChecker, ccRects)
        let greyRamp = (0...10).map { Self.pyRound(Double($0) * 25.5) }
        add("grey", greyRamp.map { ("grey \($0)", [$0, $0, $0]) }, Self.row(greyRamp.count, y: 881, w: 85, h: 100, gap: 8))
        add("dark", Self.darkSteps.map { ("dark \($0)", [$0, $0, $0]) }, Self.row(Self.darkSteps.count, y: 1011, w: 96, h: 100, gap: 6))
        add("primary", Self.primaries, Self.row(6, y: 1141, w: 150, h: 90, gap: 17))
        add("primary50", Self.primaries.map { ($0.0 + " 50%", $0.1.map { $0 / 2 }) }, Self.row(6, y: 1248, w: 150, h: 90, gap: 17))
        add("skin", Self.skin.enumerated().map { ("skin \($0.offset + 1)", $0.element) }, Self.row(6, y: 1368, w: 150, h: 90, gap: 17))
        add("nature", Self.nature, Self.row(6, y: 1488, w: 150, h: 90, gap: 17))
        let m = Self.margin, big = Self.fiducialBig, small = Self.fiducialSmall
        let top = m, bottom = Double(Self.designHeight) - m - 60
        let leftA = m + big + 30, rightA = Double(Self.designWidth) - m - small - 30 - 60
        let leftB = m + small + 30
        let uniform: [(String, [Double])] = [("grey tl", [leftA, top, 60, 60]), ("grey tr", [rightA, top, 60, 60]),
                                             ("grey bl", [leftB, bottom, 60, 60]), ("grey br", [rightA, bottom, 60, 60])]
        for (index, item) in uniform.enumerated() {
            list.append((String(format: "uniformity-%02d", index + 1), "uniformity", item.0, Self.midGrey, item.1))
        }

        // Intended Lab: the sRGB numbers -> Lab D50, relative colorimetric (rounded as the manifest).
        var rgb16 = list.flatMap { $0.3.map { UInt16($0 * 257) } }
        var lab = [Double](repeating: 0, count: list.count * 3)
        _ = selphy_source_to_lab(nil, 0, &rgb16, &lab, list.count)
        patches = list.enumerated().map { index, item in
            Patch(id: item.0, group: item.1, name: item.2, srgb: item.3, rect: item.4.map { Self.pyRound($0) },
                  labIntended: (0..<3).map { (lab[index * 3 + $0] * 10_000).rounded(.toNearestOrEven) / 10_000 })
        }
        let w = Double(Self.designWidth), h = Double(Self.designHeight)
        fiducials = [
            Fiducial(name: "tl", centre: [m + big / 2, m + big / 2], size: big),
            Fiducial(name: "tr", centre: [w - m - small / 2, m + small / 2], size: small),
            Fiducial(name: "br", centre: [w - m - small / 2, h - m - small / 2], size: small),
            Fiducial(name: "bl", centre: [m + small / 2, h - m - small / 2], size: small),
        ]
        let yTop = m + 10, yBottom = h - m - 56 + 10
        whiteSamples = [WhiteSample(name: "white top", rect: [330, Self.pyRound(yTop), 520, 36]),
                        WhiteSample(name: "white bottom", rect: [330, Self.pyRound(yBottom), 520, 36])]
    }

    // MARK: Image

    /// The chart as 8-bit sRGB pixels (RGBX, top row first).
    func pixels() -> [UInt8] {
        var data = [UInt8](repeating: 255, count: width * height * 4)
        func fill(x0: Int, y0: Int, x1: Int, y1: Int, rgb: [Int]) {   // inclusive bounds, as PIL
            for y in max(0, y0)...min(height - 1, y1) {
                for x in max(0, x0)...min(width - 1, x1) {
                    let o = (y * width + x) * 4
                    data[o] = UInt8(rgb[0]); data[o + 1] = UInt8(rgb[1]); data[o + 2] = UInt8(rgb[2])
                }
            }
        }
        for patch in patches {
            let r = patch.rect
            fill(x0: r[0], y0: r[1], x1: r[0] + r[2] - 1, y1: r[1] + r[3] - 1, rgb: patch.srgb)
        }
        for f in fiducials {
            let half = f.size / 2
            fill(x0: Self.pyRound(f.centre[0] - half), y0: Self.pyRound(f.centre[1] - half),
                 x1: Self.pyRound(f.centre[0] + half) - 1, y1: Self.pyRound(f.centre[1] + half) - 1, rgb: [0, 0, 0])
        }
        return data
    }

    func image() -> CGImage? {
        let bytes = pixels()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Writes the chart as an sRGB-tagged PNG with the print resolution (300 dpi at 100 mm wide).
    func writePNG(to url: URL) throws {
        guard let image = image(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ColorCorrectionService.CorrectionError.imageEncoding(url)
        }
        let dpi = Double(width) / (100 / 25.4)
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ColorCorrectionService.CorrectionError.imageEncoding(url) }
    }
}
