import CoreGraphics
import Foundation
import SwiftUI

/// What the horizontal axis of the ΔE distribution scope represents.
enum ScopeAxis: String, CaseIterable, Identifiable, Sendable {
    case width, height, lightness, hue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .width: tr("Image width")
        case .height: tr("Image height")
        case .lightness: tr("Lightness L*")
        case .hue: tr("Hue")
        }
    }

    /// Columns of the scope: one per 2 analysis pixels for position, 1 L* unit, 3° of hue.
    func columns(for maps: PixelMaps) -> Int {
        switch self {
        case .width: max(1, min(256, maps.width))
        case .height: max(1, min(256, maps.height))
        case .lightness: 100
        case .hue: 120
        }
    }

    /// Labels under the axis, at 0, 25, 50, 75 and 100% of its length.
    var tickLabels: [String] {
        switch self {
        case .width: [tr("left"), "25%", "50%", "75%", tr("right")]
        case .height: [tr("top"), "25%", "50%", "75%", tr("bottom")]
        case .lightness: ["0", "25", "50", "75", "100"]
        case .hue: ["0°", "90°", "180°", "270°", "360°"]
        }
    }
}

/// Distribution of the predicted ΔE00 along one axis, like a waveform: each column is the
/// histogram of ΔE00 of the pixels that fall in it (a column of the photo, a row, a lightness or a
/// hue). Computed from the analysis maps (the reduced copy of the photo), so it matches the ΔE map
/// and the statistics.
struct DeltaEScope: Equatable, Sendable {
    /// ΔE00 bins per column, from 0 to `maxDeltaE`; the top bin also collects everything above.
    static let rows = 96
    static let maxDeltaE: Float = 12
    /// Below this chroma the hue of a pixel is not meaningful: those pixels are left out of the hue axis.
    static let minimumHueChroma: Float = 5
    /// Median and 95th percentile are drawn only for columns with at least this many pixels.
    static let minimumPixelsForLines = 8

    let axis: ScopeAxis
    let columns: Int
    /// counts[column * rows + row]; row 0 = ΔE00 0.
    let counts: [UInt32]
    let columnTotals: [Int]
    let median: [Float?]
    let p95: [Float?]
    let plottedPixels: Int
    let totalPixels: Int
    let maxCount: UInt32

    static var binWidth: Float { maxDeltaE / Float(rows) }

    static func make(maps: PixelMaps, axis: ScopeAxis) -> DeltaEScope {
        let columns = axis.columns(for: maps)
        var counts = [UInt32](repeating: 0, count: columns * rows)
        var totals = [Int](repeating: 0, count: columns)
        var plotted = 0
        for index in 0..<maps.count {
            let x = index % maps.width
            let y = index / maps.width
            let column: Int
            switch axis {
            case .width:
                column = x * columns / maps.width
            case .height:
                column = y * columns / maps.height
            case .lightness:
                let l = maps.intendedLab[3 * index]
                column = Int((min(100, max(0, l)) * Float(columns) / 100).rounded(.down))
            case .hue:
                let a = maps.intendedLab[3 * index + 1], b = maps.intendedLab[3 * index + 2]
                guard (a * a + b * b).squareRoot() >= minimumHueChroma else { continue }
                var degrees = atan2(b, a) * 180 / .pi
                if degrees < 0 { degrees += 360 }
                column = Int(degrees / 360 * Float(columns))
            }
            let c = min(columns - 1, max(0, column))
            let de = maps.deltaE[index]
            let row = de.isFinite ? min(rows - 1, max(0, Int(de / binWidth))) : rows - 1
            counts[c * rows + row] += 1
            totals[c] += 1
            plotted += 1
        }
        var median: [Float?] = []
        var p95: [Float?] = []
        for c in 0..<columns {
            median.append(quantile(counts, column: c, total: totals[c], q: 0.5))
            p95.append(quantile(counts, column: c, total: totals[c], q: 0.95))
        }
        return DeltaEScope(
            axis: axis, columns: columns, counts: counts, columnTotals: totals, median: median, p95: p95,
            plottedPixels: plotted, totalPixels: maps.count, maxCount: counts.max() ?? 0
        )
    }

    /// The q-quantile of a column, at the centre of the bin where it falls (bin resolution).
    private static func quantile(_ counts: [UInt32], column: Int, total: Int, q: Double) -> Float? {
        guard total >= minimumPixelsForLines else { return nil }
        let target = q * Double(total)
        var cumulative = 0.0
        for row in 0..<rows {
            cumulative += Double(counts[column * rows + row])
            if cumulative >= target { return (Float(row) + 0.5) * binWidth }
        }
        return maxDeltaE
    }

    /// The column at a position along the axis (0...1).
    func column(at fraction: Double) -> Int {
        min(columns - 1, max(0, Int(fraction * Double(columns))))
    }

    /// The density image: one pixel per bin, ΔE00 0 at the bottom, coloured by the ΔE00 band of
    /// its row, opacity on a log scale of the count (so that isolated pixels stay visible).
    func densityImage() -> CGImage? {
        guard columns > 0, maxCount > 0 else { return nil }
        let width = columns, height = Self.rows
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let logMax = log1p(Double(maxCount))
        for column in 0..<width {
            for row in 0..<height {
                let count = counts[column * height + row]
                guard count > 0 else { continue }
                let alpha = 0.18 + 0.82 * log1p(Double(count)) / logMax
                let lower = Double(Float(row) * Self.binWidth)
                let rgb = DeviationBand.band(forLower: lower).rgb
                let offset = ((height - 1 - row) * width + column) * 4
                // Premultiplied RGBA.
                bytes[offset] = UInt8((rgb.red * alpha * 255).rounded())
                bytes[offset + 1] = UInt8((rgb.green * alpha * 255).rounded())
                bytes[offset + 2] = UInt8((rgb.blue * alpha * 255).rounded())
                bytes[offset + 3] = UInt8((alpha * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// A column or row of the photo to mark on the preview, while the pointer is over the scope.
@MainActor
@Observable
final class ScopeHighlight {
    static let shared = ScopeHighlight()

    struct Marker: Equatable {
        let photo: URL
        /// true: a column (image width axis); false: a row (image height axis).
        let vertical: Bool
        /// Start and width of the band, as fractions of the image width or height.
        let start: Double
        let span: Double
    }

    var marker: Marker?
}

/// Draws the scope marker over the preview image (same aspect-fit frame as the image).
struct ScopeMarkerOverlay: View {
    let photo: URL?
    let aspect: CGFloat
    private let highlight = ScopeHighlight.shared

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    if let marker = highlight.marker, marker.photo == photo {
                        let size = geometry.size
                        let rect = marker.vertical
                            ? CGRect(x: size.width * marker.start, y: 0, width: max(1, size.width * marker.span), height: size.height)
                            : CGRect(x: 0, y: size.height * marker.start, width: size.width, height: max(1, size.height * marker.span))
                        ZStack {
                            Rectangle().fill(Color.white.opacity(0.18))
                            Rectangle().stroke(Color.black.opacity(0.8), lineWidth: 2)
                            Rectangle().stroke(Color.white, lineWidth: 1)
                        }
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .allowsHitTesting(false)
    }
}

/// The scope plot: density image, ΔE00 guides at 1, 3 and 6, median and 95th percentile lines,
/// axis labels and a readout of the column under the pointer.
struct DeltaEScopeView: View {
    let scope: DeltaEScope
    /// Position under the pointer along the axis (0...1), nil when it leaves the plot.
    var onHover: (Double?) -> Void
    @State private var hover: Double?
    /// Made once per scope, not at every pointer move.
    private let image: CGImage?

    init(scope: DeltaEScope, onHover: @escaping (Double?) -> Void = { _ in }) {
        self.scope = scope
        self.onHover = onHover
        self.image = scope.densityImage()
    }

    private static let plotBackground = Color(.sRGB, red: 0.11, green: 0.11, blue: 0.11, opacity: 1)
    private static let medianColour = Color.white
    private static let p95Colour = Color(.sRGB, red: 0.55, green: 0.80, blue: 1.0, opacity: 1)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                ZStack {
                    Self.plotBackground
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.none)
                    }
                    Canvas { context, size in draw(in: &context, size: size) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let fraction = min(1, max(0, point.x / max(1, geometry.size.width)))
                        hover = fraction
                        onHover(fraction)
                    case .ended:
                        hover = nil
                        onHover(nil)
                    }
                }
            }
            .frame(height: 200)
            axisStrip
            ticks
            HStack(spacing: 14) {
                legend(tr("median"), Self.medianColour)
                legend(tr("95th pct"), Self.p95Colour)
                Text(readout)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if scope.axis == .hue {
                Text(trf("Pixels with chroma below C* %.0f have no definite hue and are left out: %.0f%% of the photo.",
                         Double(DeltaEScope.minimumHueChroma),
                         Double(scope.totalPixels - scope.plottedPixels) / Double(max(1, scope.totalPixels)) * 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func y(_ deltaE: Float, height: CGFloat) -> CGFloat {
        height * (1 - CGFloat(min(deltaE, DeltaEScope.maxDeltaE) / DeltaEScope.maxDeltaE))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        // Guides at ΔE00 1, 3, 6 and labels on the left.
        for value: Float in [1, 3, 6, 12] {
            let yy = y(value, height: size.height)
            if value < DeltaEScope.maxDeltaE {
                var guide = Path()
                guide.move(to: CGPoint(x: 0, y: yy))
                guide.addLine(to: CGPoint(x: size.width, y: yy))
                context.stroke(guide, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            }
            let label = value < DeltaEScope.maxDeltaE ? String(format: "%.0f", value) : String(format: "%.0f+", value)
            context.draw(Text(label).font(.system(size: 9)).foregroundColor(.white.opacity(0.7)),
                         at: CGPoint(x: 4, y: max(7, yy + (value < DeltaEScope.maxDeltaE ? -7 : 7))), anchor: .leading)
        }
        let columnWidth = size.width / CGFloat(scope.columns)
        func line(_ values: [Float?]) -> Path {
            var path = Path()
            var drawing = false
            for (column, value) in values.enumerated() {
                guard let value else { drawing = false; continue }
                let point = CGPoint(x: (CGFloat(column) + 0.5) * columnWidth, y: y(value, height: size.height))
                if drawing { path.addLine(to: point) } else { path.move(to: point); drawing = true }
            }
            return path
        }
        context.stroke(line(scope.p95), with: .color(Self.p95Colour.opacity(0.9)), lineWidth: 1.2)
        context.stroke(line(scope.median), with: .color(Self.medianColour.opacity(0.9)), lineWidth: 1.2)
        if let hover {
            let column = scope.column(at: hover)
            let rect = CGRect(x: CGFloat(column) * columnWidth, y: 0, width: max(1, columnWidth), height: size.height)
            context.fill(Path(rect), with: .color(.white.opacity(0.12)))
            context.stroke(Path(rect), with: .color(.white.opacity(0.6)), lineWidth: 0.5)
        }
        context.draw(Text("ΔE00").font(.system(size: 9)).foregroundColor(.white.opacity(0.6)),
                     at: CGPoint(x: size.width - 4, y: 8), anchor: .trailing)
    }

    /// Under the lightness and hue axes, the colours they stand for (drawn in CIELab, so the
    /// system converts them for the display).
    @ViewBuilder
    private var axisStrip: some View {
        switch scope.axis {
        case .lightness:
            LinearGradient(colors: (0...10).map { Self.labColour(l: Double($0) * 10, a: 0, b: 0) },
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 6)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        case .hue:
            LinearGradient(colors: (0...24).map { step in
                let h = Double(step) * 15 * .pi / 180
                return Self.labColour(l: 65, a: 45 * cos(h), b: 45 * sin(h))
            }, startPoint: .leading, endPoint: .trailing)
            .frame(height: 6)
            .clipShape(RoundedRectangle(cornerRadius: 2))
        default:
            EmptyView()
        }
    }

    private static let labSpace = CGColorSpace(labWhitePoint: [0.9642, 1.0, 0.8249], blackPoint: [0, 0, 0], range: [-128, 127, -128, 127])

    private static func labColour(l: Double, a: Double, b: Double) -> Color {
        guard let space = labSpace,
              let colour = CGColor(colorSpace: space, components: [CGFloat(l), CGFloat(a), CGFloat(b), 1]) else { return .gray }
        return Color(cgColor: colour)
    }

    private var ticks: some View {
        GeometryReader { geometry in
            ForEach(Array(scope.axis.tickLabels.enumerated()), id: \.offset) { index, label in
                let fraction = Double(index) / Double(scope.axis.tickLabels.count - 1)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: min(geometry.size.width - 14, max(14, geometry.size.width * fraction)), y: 6)
            }
        }
        .frame(height: 12)
    }

    private func legend(_ title: String, _ colour: Color) -> some View {
        HStack(spacing: 4) {
            Rectangle().fill(colour).frame(width: 14, height: 2)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var readout: String {
        guard let hover else { return tr("Move the pointer over the plot to read a column.") }
        let column = scope.column(at: hover)
        let lower = Double(column) / Double(scope.columns)
        let upper = Double(column + 1) / Double(scope.columns)
        let place: String
        switch scope.axis {
        case .width: place = trf("%.0f–%.0f%% from the left", lower * 100, upper * 100)
        case .height: place = trf("%.0f–%.0f%% from the top", lower * 100, upper * 100)
        case .lightness: place = trf("L* %.0f–%.0f", lower * 100, upper * 100)
        case .hue: place = trf("hue %.0f–%.0f°", lower * 360, upper * 360)
        }
        let total = scope.columnTotals[column]
        guard let median = scope.median[column], let p95 = scope.p95[column] else {
            return trf("%@: too few pixels (%d)", place, total)
        }
        return trf("%@: median ΔE00 %.1f, 95th pct %.1f, %d pixels", place, Double(median), Double(p95), total)
    }
}
