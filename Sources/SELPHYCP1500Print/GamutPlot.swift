import CoreGraphics
import Foundation
import SELPHYColorCore
import SwiftUI

/// The a*-b* projection of a gamut: for each hue, the largest chroma reached at any lightness.
struct GamutOutline: Equatable, Sendable {
    static let bins = 180          // 2 degrees of hue each

    /// Largest C* per hue bin (bin i covers hue 2i ... 2i+2 degrees).
    let chroma: [Double]

    init(chroma: [Double]) { self.chroma = chroma }

    init(labs: [[Double]]) {
        var chroma = [Double](repeating: 0, count: Self.bins)
        for lab in labs {
            let c = (lab[1] * lab[1] + lab[2] * lab[2]).squareRoot()
            guard c > 0.5 else { continue }
            var h = atan2(lab[2], lab[1]) * 180 / .pi
            if h < 0 { h += 360 }
            let bin = min(Self.bins - 1, Int(h / 360 * Double(Self.bins)))
            chroma[bin] = max(chroma[bin], c)
        }
        // A bin no sample fell into takes the larger of its neighbours (sparse sampling).
        for i in 0..<Self.bins where chroma[i] == 0 {
            chroma[i] = max(chroma[(i + Self.bins - 1) % Self.bins], chroma[(i + 1) % Self.bins])
        }
        self.chroma = chroma
    }

    /// Chroma of the outline at a hue (degrees).
    func chroma(atHue hue: Double) -> Double {
        var h = hue.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return chroma[min(Self.bins - 1, Int(h / 360 * Double(Self.bins)))]
    }

    /// Device RGB values on the surface of the cube (where the gamut boundary lies), n per edge.
    static func cubeSurface(steps n: Int = 25) -> [UInt16] {
        var out: [UInt16] = []
        func v(_ i: Int) -> UInt16 { UInt16((Double(i) / Double(n - 1) * 65535).rounded()) }
        for i in 0..<n {
            for j in 0..<n {
                for fixed in [0, n - 1] {
                    out += [v(fixed), v(i), v(j)]
                    out += [v(i), v(fixed), v(j)]
                    out += [v(i), v(j), v(fixed)]
                }
            }
        }
        return out
    }

    /// The sRGB gamut (D50, relative colorimetric).
    static let sRGB: GamutOutline = {
        var rgb = cubeSurface()
        var lab = [Double](repeating: 0, count: rgb.count)
        _ = selphy_source_to_lab(nil, 0, &rgb, &lab, rgb.count / 3)
        return GamutOutline(labs: stride(from: 0, to: lab.count, by: 3).map { [lab[$0], lab[$0 + 1], lab[$0 + 2]] })
    }()

    /// The printer's gamut from the profile's A2B model (paper-relative).
    static func printer(icc: Data) -> GamutOutline? {
        var rgb = cubeSurface()
        var lab = [Double](repeating: 0, count: rgb.count)
        let status = icc.withUnsafeBytes {
            selphy_printer_predict_lab($0.bindMemory(to: UInt8.self).baseAddress, icc.count, SELPHY_INTENT_RELATIVE_COLORIMETRIC,
                                       &rgb, &lab, rgb.count / 3)
        }
        guard status == SELPHY_OK else { return nil }
        return GamutOutline(labs: stride(from: 0, to: lab.count, by: 3).map { [lab[$0], lab[$0 + 1], lab[$0 + 2]] })
    }
}

/// A colour of the photo in the a*-b* plot.
struct GamutPoint: Equatable, Sendable {
    let l: Float, a: Float, b: Float
    /// The print loses more than `GamutPoint.dullLoss` of chroma here (the Out of gamut view).
    let dull: Bool

    static let dullLoss: Float = 8

    /// An even subsample of the photo's intended colours.
    static func sample(_ maps: PixelMaps, limit: Int = 3000) -> [GamutPoint] {
        let step = max(1, maps.count / limit)
        return stride(from: 0, to: maps.count, by: step).map { i in
            let lab = maps.intended(at: i)
            return GamutPoint(l: lab.l, a: lab.a, b: lab.b, dull: maps.chromaLoss(at: i) > dullLoss)
        }
    }
}

/// a*-b* plane: sRGB and printer gamut outlines, and the photo's colours on top.
struct GamutPlotView: View {
    let printer: GamutOutline
    let points: [GamutPoint]
    var sRGB: GamutOutline = .sRGB
    /// Half-width of the plot in a*/b* units.
    var extent: Double = 100

    private static let labSpace = CGColorSpace(labWhitePoint: [0.9642, 1.0, 0.8249], blackPoint: [0, 0, 0], range: [-128, 127, -128, 127])

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in draw(in: &context, size: size) }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 420)
                .background(Color(.sRGB, red: 0.5, green: 0.5, blue: 0.5, opacity: 1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack(spacing: 14) {
                legend(tr("printer (profile model)"), solid: true)
                legend(tr("sRGB"), solid: false)
                HStack(spacing: 4) {
                    Circle().stroke(Color.white, lineWidth: 1.5).frame(width: 8, height: 8)
                    Text(tr("colours the print dulls")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(trf("%.0f%% of the sampled colours lie outside the printer's gamut outline.", outsideShare * 100))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var outsideShare: Double {
        guard !points.isEmpty else { return 0 }
        let outside = points.filter { p in
            let c = Double((p.a * p.a + p.b * p.b).squareRoot())
            var h = Double(atan2(p.b, p.a)) * 180 / .pi
            if h < 0 { h += 360 }
            return c > printer.chroma(atHue: h) + 1
        }
        return Double(outside.count) / Double(points.count)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let scale = min(size.width, size.height) / 2 / extent
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        func point(_ a: Double, _ b: Double) -> CGPoint { CGPoint(x: centre.x + a * scale, y: centre.y - b * scale) }
        // Axes and chroma circles every 25.
        var axes = Path()
        axes.move(to: CGPoint(x: 0, y: centre.y)); axes.addLine(to: CGPoint(x: size.width, y: centre.y))
        axes.move(to: CGPoint(x: centre.x, y: 0)); axes.addLine(to: CGPoint(x: centre.x, y: size.height))
        context.stroke(axes, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
        for r in stride(from: 25.0, through: extent, by: 25) {
            let rect = CGRect(x: centre.x - r * scale, y: centre.y - r * scale, width: 2 * r * scale, height: 2 * r * scale)
            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.15)), lineWidth: 0.5)
        }
        context.draw(Text("+a*").font(.system(size: 9)).foregroundColor(.white.opacity(0.7)), at: CGPoint(x: size.width - 14, y: centre.y - 8))
        context.draw(Text("+b*").font(.system(size: 9)).foregroundColor(.white.opacity(0.7)), at: CGPoint(x: centre.x + 14, y: 8))

        // The photo's colours, each in its own colour (the system converts Lab for the display).
        for p in points {
            let q = point(Double(p.a), Double(p.b))
            let rect = CGRect(x: q.x - 2, y: q.y - 2, width: 4, height: 4)
            if let space = Self.labSpace,
               let colour = CGColor(colorSpace: space, components: [CGFloat(p.l), CGFloat(p.a), CGFloat(p.b), 1]) {
                context.fill(Path(ellipseIn: rect), with: .color(Color(cgColor: colour)))
            }
            if p.dull {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -1, dy: -1)), with: .color(.white), lineWidth: 1)
            }
        }

        func outline(_ g: GamutOutline) -> Path {
            var path = Path()
            for i in 0...GamutOutline.bins {
                let bin = i % GamutOutline.bins
                let h = (Double(bin) + 0.5) * 360 / Double(GamutOutline.bins) * .pi / 180
                let c = min(g.chroma[bin], extent * 1.4)
                let q = point(c * cos(h), c * sin(h))
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            path.closeSubpath()
            return path
        }
        context.stroke(outline(sRGB), with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        context.stroke(outline(printer), with: .color(.black), lineWidth: 2.5)
        context.stroke(outline(printer), with: .color(.white), lineWidth: 1)
    }

    private func legend(_ title: String, solid: Bool) -> some View {
        HStack(spacing: 4) {
            Rectangle()
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.5, dash: solid ? [] : [3, 2]))
                .frame(width: 16, height: 0.5)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
