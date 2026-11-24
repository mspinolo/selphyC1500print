import Foundation

/// The parts of the tonal range the statistics are split by (intended lightness of each pixel).
enum LightnessZone: String, CaseIterable, Identifiable {
    case shadows, midtones, highlights

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shadows: tr("Shadows (L* below 30)")
        case .midtones: tr("Midtones (L* 30 to 70)")
        case .highlights: tr("Highlights (L* above 70)")
        }
    }

    static func zone(forL lightness: Float) -> LightnessZone {
        if lightness < 30 { return .shadows }
        if lightness < 70 { return .midtones }
        return .highlights
    }
}

/// Distribution of the predicted colour deviation (dE00 between the photo as it should look and
/// the predicted print) over the pixels of a photo. Model estimates, not print measurements.
struct DeviationStatistics: Equatable {
    struct Zone: Equatable {
        var zone: LightnessZone
        var share: Double
        var mean: Double
        var p95: Double
        var shareAbove: Double
    }

    struct Bin: Equatable, Identifiable {
        var lower: Double
        var upper: Double
        var share: Double
        var id: Double { lower }
    }

    static let defaultThresholds: [Float] = [1, 2, 3, 6]
    /// dE00 above which a zone counts a pixel as not reproduced (same as the core's threshold).
    static let zoneThreshold: Float = 3

    var pixelCount: Int
    var mean: Double
    var median: Double
    var p95: Double
    var p99: Double
    var max: Double
    var thresholds: [Float]
    /// Share of pixels above each threshold, in the same order.
    var shareAbove: [Double]
    var histogram: [Bin]
    var zones: [Zone]

    /// Nearest-rank percentile of a sorted array (q in 0...1).
    static func percentile(sorted values: [Float], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let rank = Int((q * Double(values.count)).rounded(.up))
        return Double(values[Swift.min(values.count - 1, Swift.max(0, rank - 1))])
    }

    private static func summary(_ values: [Float]) -> (mean: Double, median: Double, p95: Double, p99: Double, max: Double) {
        guard !values.isEmpty else { return (0, 0, 0, 0, 0) }
        let sorted = values.sorted()
        let sum = sorted.reduce(0.0) { $0 + Double($1) }
        return (sum / Double(sorted.count), percentile(sorted: sorted, 0.5), percentile(sorted: sorted, 0.95),
                percentile(sorted: sorted, 0.99), Double(sorted[sorted.count - 1]))
    }

    static func compute(
        _ maps: PixelMaps,
        thresholds: [Float] = defaultThresholds,
        histogramMax: Float = 12,
        bins: Int = 24
    ) -> DeviationStatistics {
        let binWidth = histogramMax / Float(bins)
        var all: [Float] = []
        all.reserveCapacity(maps.count)
        var perZone = [[Float]](repeating: [], count: LightnessZone.allCases.count)
        var counts = [Int](repeating: 0, count: bins)
        var above = [Int](repeating: 0, count: thresholds.count)
        for i in 0..<maps.count {
            let d = maps.deltaE[i]
            guard d.isFinite, d >= 0 else { continue }
            all.append(d)
            let zone = LightnessZone.zone(forL: maps.intendedLab[3 * i])
            perZone[LightnessZone.allCases.firstIndex(of: zone)!].append(d)
            counts[Swift.min(bins - 1, Int(d / binWidth))] += 1
            for (j, threshold) in thresholds.enumerated() where d > threshold { above[j] += 1 }
        }
        let total = Double(Swift.max(1, all.count))
        let overall = summary(all)
        let zones = LightnessZone.allCases.enumerated().map { index, zone -> Zone in
            let values = perZone[index]
            let s = summary(values)
            let over = values.filter { $0 > zoneThreshold }.count
            return Zone(zone: zone, share: Double(values.count) / total, mean: s.mean, p95: s.p95,
                        shareAbove: values.isEmpty ? 0 : Double(over) / Double(values.count))
        }
        return DeviationStatistics(
            pixelCount: all.count, mean: overall.mean, median: overall.median, p95: overall.p95, p99: overall.p99,
            max: overall.max, thresholds: thresholds, shareAbove: above.map { Double($0) / total },
            histogram: counts.enumerated().map {
                Bin(lower: Double(Float($0.offset) * binWidth), upper: Double(Float($0.offset + 1) * binWidth), share: Double($0.element) / total)
            },
            zones: zones
        )
    }
}
