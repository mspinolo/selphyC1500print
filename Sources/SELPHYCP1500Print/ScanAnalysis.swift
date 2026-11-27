import CoreGraphics
import Foundation
import ImageIO
import SELPHYColorCore

/// A scan as the device values the scanner wrote (no colour conversion) and its embedded profile.
struct ScanImage {
    let width: Int
    let height: Int
    /// Interleaved 16-bit RGB, host byte order, top row first (8-bit scans are scaled by 257).
    let rgb16: [UInt16]
    let embeddedICC: Data?
    /// Name of the embedded profile, if any.
    let profileName: String?

    enum LoadError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self { case .unreadable(let name): trf("Unable to read the scan: %@", name) }
        }
    }

    static func load(_ url: URL) throws -> ScanImage {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        // The same decoder as the photos: RGB files are drawn in their own colour space (no
        // conversion), so these are the numbers the scanner wrote.
        let loaded: ColorCorrectionService.LoadedSource
        do {
            loaded = try ColorCorrectionService.loadSource(from: url)
        } catch {
            throw LoadError.unreadable(url.lastPathComponent)
        }
        let count = loaded.width * loaded.height
        var rgb = [UInt16](repeating: 0, count: count * 3)
        loaded.pixels.withUnsafeBytes { raw in
            let words = raw.bindMemory(to: UInt16.self)
            for i in 0..<count {
                rgb[i * 3] = UInt16(bigEndian: words[i * 4])
                rgb[i * 3 + 1] = UInt16(bigEndian: words[i * 4 + 1])
                rgb[i * 3 + 2] = UInt16(bigEndian: words[i * 4 + 2])
            }
        }
        return ScanImage(width: loaded.width, height: loaded.height, rgb16: rgb,
                         embeddedICC: loaded.embeddedICC, profileName: loaded.profileName)
    }

    /// A reduced copy for display (8-bit, in the scan's own colour space).
    func thumbnail(maxDimension: Int = 1400) -> CGImage? {
        let factor = max(1, max(width, height) / maxDimension)
        let w = width / factor, h = height / factor
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let s = ((y * factor) * width + x * factor) * 3
                let o = (y * w + x) * 4
                bytes[o] = UInt8(rgb16[s] >> 8); bytes[o + 1] = UInt8(rgb16[s + 1] >> 8); bytes[o + 2] = UInt8(rgb16[s + 2] >> 8)
            }
        }
        let space = embeddedICC.flatMap { CGColorSpace(iccData: $0 as CFData) } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

enum ScanAnalysisError: LocalizedError {
    case core(selphy_status)
    case noScannerProfile
    case patchOutside

    var errorDescription: String? {
        switch self {
        case .core(let status):
            switch status {
            case SELPHY_ERR_CHART_MARKS: tr("Fewer than 4 corner marks found: check that the whole print is in the scan.")
            case SELPHY_ERR_CHART_ORIENTATION: tr("The large corner mark is not clearly identified.")
            case SELPHY_ERR_CHART_SHAPE: tr("The corner marks do not form the expected rectangle: check the scan.")
            default: trf("Colour core error: %@", String(cString: selphy_status_message(status)))
            }
        case .noScannerProfile: tr("No scanner profile: embed it in the TIFF or choose it.")
        case .patchOutside: tr("A patch lies outside the scan: check the corner points.")
        }
    }
}

/// Statistics in the format of validation/analyze_scan.py (rounded to 3 decimals, numpy's
/// linear percentile), so that results can be merged with the Python tools.
struct DeltaStats: Codable, Equatable, Sendable {
    var mean: Double
    var median: Double
    var p95: Double
    var max: Double
    var n: Int

    static func round3(_ v: Double) -> Double { (v * 1000).rounded(.toNearestOrEven) / 1000 }

    /// numpy.percentile with linear interpolation.
    static func percentile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        let position = Double(sorted.count - 1) * q / 100
        let lower = Int(position.rounded(.down))
        let upper = Swift.min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    init(mean: Double, median: Double, p95: Double, max: Double, n: Int) {
        self.mean = mean; self.median = median; self.p95 = p95; self.max = max; self.n = n
    }

    init(_ values: [Double]) {
        mean = Self.round3(values.reduce(0, +) / Double(Swift.max(1, values.count)))
        median = Self.round3(Self.percentile(values, 50))
        p95 = Self.round3(Self.percentile(values, 95))
        max = Self.round3(values.max() ?? 0)
        n = values.count
    }
}

/// One measured patch (results_<label>.json of analyze_scan.py).
struct MeasuredPatch: Codable, Equatable, Sendable {
    var id: String
    var group: String
    var name: String
    var srgb: [Int]
    var intendedLab: [Double]
    var measuredLab: [Double]
    var de00: Double

    enum CodingKeys: String, CodingKey {
        case id, group, name, srgb
        case intendedLab = "intended_lab"
        case measuredLab = "measured_lab"
        case de00
    }
}

struct ScanSummary: Codable, Equatable, Sendable {
    var all: DeltaStats
    var groups: [String: DeltaStats]
    var neutralChromaP95: Double?
    var darkStepsDistinguishable: Int
    var darkStepsTotal: Int
    var uniformityMax: Double?

    static let neutralGroups: Set<String> = ["grey", "dark"]

    /// analyze_scan.summarise.
    static func make(_ patches: [MeasuredPatch]) -> ScanSummary {
        let scored = patches.filter { $0.group != "uniformity" }
        var groups: [String: DeltaStats] = [:]
        for group in Set(scored.map(\.group)) {
            groups[group] = DeltaStats(scored.filter { $0.group == group }.map(\.de00))
        }
        let neutral = scored.filter { neutralGroups.contains($0.group) && $0.measuredLab[0] >= 25 }.map { LabMath.chroma($0.measuredLab) }
        let dark = scored.filter { $0.group == "dark" }.sorted { $0.srgb[0] < $1.srgb[0] }
        var distinguishable = 1
        if dark.count > 1 {
            for i in 0..<(dark.count - 1) where LabMath.deltaE00(dark[i].measuredLab, dark[i + 1].measuredLab) >= 1 {
                distinguishable += 1
            }
        }
        let grey = patches.filter { $0.group == "uniformity" }.map(\.measuredLab)
        var uniformity: Double?
        if grey.count > 1 {
            var worst = 0.0
            for i in 0..<grey.count { for j in (i + 1)..<grey.count { worst = Swift.max(worst, LabMath.deltaE00(grey[i], grey[j])) } }
            uniformity = DeltaStats.round3(worst)
        }
        return ScanSummary(all: DeltaStats(scored.map(\.de00)), groups: groups,
                           neutralChromaP95: neutral.isEmpty ? nil : DeltaStats.round3(DeltaStats.percentile(neutral, 95)),
                           darkStepsDistinguishable: dark.isEmpty ? 0 : distinguishable, darkStepsTotal: dark.count,
                           uniformityMax: uniformity)
    }
}

/// The analysis of one chart scan.
struct ChartScanResult: Codable, Equatable, Sendable {
    var label: String
    var scan: String
    var paperWhiteLab: [Double]
    var patches: [MeasuredPatch]
    var summary: ScanSummary
    /// Corner marks found (scan pixels), for the overlay.
    var marks: [[Double]]
}

enum ChartScanAnalysis {
    private static func status(_ s: selphy_status) throws {
        if s != SELPHY_OK { throw ScanAnalysisError.core(s) }
    }

    static func lab(_ rgb: [UInt16], icc: Data?) throws -> [[Double]] {
        var input = rgb
        var out = [Double](repeating: 0, count: rgb.count)
        let count = rgb.count / 3
        let s: selphy_status
        if let icc {
            s = icc.withUnsafeBytes { selphy_source_to_lab($0.bindMemory(to: UInt8.self).baseAddress, icc.count, &input, &out, count) }
        } else {
            s = selphy_source_to_lab(nil, 0, &input, &out, count)
        }
        try status(s)
        return (0..<count).map { [out[$0 * 3], out[$0 * 3 + 1], out[$0 * 3 + 2]] }
    }

    /// The corner marks (tl, tr, br, bl) found by the core.
    static func marks(_ scan: ScanImage, icc: Data?, chart: ValidationChart) throws -> [selphy_point] {
        var out = [selphy_point](repeating: selphy_point(x: 0, y: 0), count: 4)
        let s: selphy_status = scan.rgb16.withUnsafeBufferPointer { pixels in
            if let icc {
                return icc.withUnsafeBytes {
                    selphy_chart_find_marks(pixels.baseAddress, scan.width, scan.height,
                                            $0.bindMemory(to: UInt8.self).baseAddress, icc.count, chart.aspect, &out)
                }
            }
            return selphy_chart_find_marks(pixels.baseAddress, scan.width, scan.height, nil, 0, chart.aspect, &out)
        }
        try status(s)
        return out
    }

    static func sample(_ scan: ScanImage, homography h: [Double], rects: [[Int]]) throws -> [UInt16] {
        var flat = rects.flatMap { $0.map(Double.init) }
        var out = [UInt16](repeating: 0, count: rects.count * 3)
        var matrix = h
        let s = scan.rgb16.withUnsafeBufferPointer {
            selphy_chart_sample($0.baseAddress, scan.width, scan.height, &matrix, &flat, rects.count, 0.6, 14, &out)
        }
        try status(s)
        return out
    }

    /// analyze_scan.analyse: marks, homography, samples, paper-relative Lab, dE00, summary.
    static func analyse(_ scan: ScanImage, scannerICC: Data?, chart: ValidationChart = .standard,
                        label: String, scanName: String) throws -> ChartScanResult {
        guard let icc = scannerICC ?? scan.embeddedICC else { throw ScanAnalysisError.noScannerProfile }
        let found = try marks(scan, icc: icc, chart: chart)
        var src = chart.fiducials.map { selphy_point(x: $0.centre[0], y: $0.centre[1]) }
        var dst = found
        var h = [Double](repeating: 0, count: 9)
        try status(selphy_homography4(&src, &dst, &h))

        let whiteSamples = try sample(scan, homography: h, rects: chart.whiteSamples.map(\.rect))
        let whiteLabs = try lab(whiteSamples, icc: icc)
        // numpy median over the white areas, per channel.
        let white = (0..<3).map { c in DeltaStats.percentile(whiteLabs.map { $0[c] }, 50) }

        let samples = try sample(scan, homography: h, rects: chart.patches.map(\.rect))
        let absolute = try lab(samples, icc: icc)
        var patches: [MeasuredPatch] = []
        for (patch, measured) in zip(chart.patches, absolute) {
            let relative = LabMath.normaliseToPaperWhite(measured, white: white)
            patches.append(MeasuredPatch(
                id: patch.id, group: patch.group, name: patch.name, srgb: patch.srgb, intendedLab: patch.labIntended,
                measuredLab: relative.map(DeltaStats.round3), de00: DeltaStats.round3(LabMath.deltaE00(relative, patch.labIntended))))
        }
        return ChartScanResult(label: label, scan: scanName, paperWhiteLab: white.map(DeltaStats.round3), patches: patches,
                               summary: .make(patches), marks: found.map { [$0.x, $0.y] })
    }
}

/// The ColorChecker check of the scanner chain (check_scanner.py).
struct ScannerCheckResult: Codable, Equatable, Sendable {
    var referenceID: String
    var referenceTitle: String
    var corners: [[Double]]
    var measuredLab: [[Double]]
    var referenceLab: [[Double]]
    var de00: [Double]
    var summary: DeltaStats
    /// Which profile was used: "scanner profile", "embedded profile" or "sRGB".
    var profileUsed: String
    /// The same scan read with the other available profile, when there is one (the "applied
    /// twice or not at all" check).
    var alternativeProfile: String?
    var alternativeMean: Double?

    /// A flatbed typically measures a ColorChecker within a few dE00; above this something is off.
    static let suspiciousMean = 5.0

    var isTrustworthy: Bool { summary.mean <= Self.suspiciousMean }

    /// Differences between variants smaller than this are not interpreted (report.py).
    var resolution: Double { max(1.0, summary.mean) }

    enum CodingKeys: String, CodingKey {
        case referenceID = "reference_id", referenceTitle = "reference"
        case corners
        case measuredLab = "measured_lab", referenceLab = "reference_lab"
        case de00, summary
        case profileUsed = "profile_used", alternativeProfile = "alternative_profile", alternativeMean = "alternative_mean"
    }
}

enum ScannerCheck {
    /// Patch centres from the four corner patches (tl, tr, bl, br), row-major.
    static func patchCentres(corners: [CGPoint], columns: Int, rows: Int) -> [CGPoint] {
        let tl = corners[0], tr = corners[1], bl = corners[2], br = corners[3]
        var centres: [CGPoint] = []
        for r in 0..<rows {
            let v = Double(r) / Double(rows - 1)
            let left = CGPoint(x: tl.x + (bl.x - tl.x) * v, y: tl.y + (bl.y - tl.y) * v)
            let right = CGPoint(x: tr.x + (br.x - tr.x) * v, y: tr.y + (br.y - tr.y) * v)
            for c in 0..<columns {
                let u = Double(c) / Double(columns - 1)
                centres.append(CGPoint(x: left.x + (right.x - left.x) * u, y: left.y + (right.y - left.y) * u))
            }
        }
        return centres
    }

    /// Median of the square window around each centre (radius 22% of the patch pitch).
    static func samples(_ scan: ScanImage, corners: [CGPoint], model: ColourTargetModel) throws -> [UInt16] {
        let centres = patchCentres(corners: corners, columns: model.columns, rows: model.rows)
        let pitch = hypot(corners[1].x - corners[0].x, corners[1].y - corners[0].y) / Double(model.columns - 1)
        let radius = max(2, Int(pitch * 0.22))
        var out: [UInt16] = []
        for centre in centres {
            let x0 = Int(centre.x) - radius, x1 = Int(centre.x) + radius + 1
            let y0 = Int(centre.y) - radius, y1 = Int(centre.y) + radius + 1
            guard x0 >= 0, y0 >= 0, x1 <= scan.width, y1 <= scan.height else { throw ScanAnalysisError.patchOutside }
            for channel in 0..<3 {
                var values: [Double] = []
                values.reserveCapacity((x1 - x0) * (y1 - y0))
                for y in y0..<y1 { for x in x0..<x1 { values.append(Double(scan.rgb16[(y * scan.width + x) * 3 + channel])) } }
                out.append(UInt16(DeltaStats.percentile(values, 50)))
            }
        }
        return out
    }

    static func check(_ scan: ScanImage, corners: [CGPoint], reference: ReferenceSet, scannerICC: Data?) throws -> ScannerCheckResult {
        let samples = try samples(scan, corners: corners, model: reference.model)
        // The profile to use: the one chosen for the scanner, else the embedded one, else sRGB.
        var candidates: [(String, Data?)] = []
        if let scannerICC { candidates.append((tr("scanner profile"), scannerICC)) }
        if let embedded = scan.embeddedICC, embedded != scannerICC { candidates.append((tr("embedded profile"), embedded)) }
        if candidates.isEmpty { candidates.append((tr("sRGB"), nil)) }
        let reference3 = reference.patches.map(\.lab)
        func evaluate(_ icc: Data?) throws -> ([[Double]], [Double]) {
            let measured = try ChartScanAnalysis.lab(samples, icc: icc)
            return (measured, zip(measured, reference3).map { LabMath.deltaE00($0, $1) })
        }
        let (measured, de) = try evaluate(candidates[0].1)
        var alternativeName: String?
        var alternativeMean: Double?
        if candidates.count > 1 {
            let (_, other) = try evaluate(candidates[1].1)
            alternativeName = candidates[1].0
            alternativeMean = DeltaStats(other).mean
        }
        return ScannerCheckResult(
            referenceID: reference.id, referenceTitle: reference.title,
            corners: corners.map { [Double($0.x), Double($0.y)] },
            measuredLab: measured.map { $0.map(DeltaStats.round3) }, referenceLab: reference3,
            de00: de.map(DeltaStats.round3), summary: DeltaStats(de), profileUsed: candidates[0].0,
            alternativeProfile: alternativeName, alternativeMean: alternativeMean)
    }
}
