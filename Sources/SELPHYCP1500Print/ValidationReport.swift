import Foundation
import SELPHYColorCore

/// The chart variants of the physical test (validation/make_run_plan.py, report.py).
enum ChartVariant: String, Codable, CaseIterable, Identifiable, Sendable {
    case v0 = "V0", v1 = "V1", v2 = "V2", v3 = "V3", v4 = "V4"

    var id: String { rawValue }

    /// The file printed: the original chart or a corrected copy.
    var correction: (intent: RenderingIntent, bpc: Bool)? {
        switch self {
        case .v0, .v4: nil
        case .v1, .v3: (.perceptual, false)
        case .v2: (.relativeColorimetric, false)
        }
    }

    /// The printer's Image Optimize setting for this sheet.
    var imageOptimizeOn: Bool { self == .v3 || self == .v4 }

    var reportDescription: String {
        switch self {
        case .v0: "original, printer Image Optimize OFF (baseline)"
        case .v1: "corrected, Perceptual, Image Optimize OFF (main result)"
        case .v2: "corrected, Relative colorimetric, Image Optimize OFF (intent choice)"
        case .v3: "corrected, Perceptual, Image Optimize ON (printer default; is it applied on this route?)"
        case .v4: "original, Image Optimize ON (control for V3)"
        }
    }

    var title: String {
        switch self {
        case .v0: tr("V0 — original chart, Image Optimize off")
        case .v1: tr("V1 — corrected Perceptual, Image Optimize off")
        case .v2: tr("V2 — corrected Relative colorimetric, Image Optimize off")
        case .v3: tr("V3 — corrected Perceptual, Image Optimize ON")
        case .v4: tr("V4 — original chart, Image Optimize ON")
        }
    }

    /// The variant whose file and model V3 / V4 reuse.
    var modelVariant: ChartVariant { self == .v3 ? .v1 : (self == .v4 ? .v0 : self) }
}

enum ValidationReport {
    /// dE00 differences below this are not interpreted as real (report.py).
    static let indistinguishable = 1.0

    struct Gate: Equatable, Sendable {
        var name: String
        var passed: Bool
        var detail: String
    }

    /// What the profile's own model predicts for the chart printed as `variant` (A2B, paper-relative).
    static func modelSummary(printerICC: Data, variant: ChartVariant, chart: ValidationChart = .standard) throws -> ScanSummary {
        let srgb = chart.patches.map(\.srgb) + [[255, 255, 255]]
        var device = srgb.flatMap { $0.map { UInt16($0 * 257) } }
        if let correction = variant.modelVariant.correction {
            let transform = try ColorCorrectionService.ColorTransform(
                sourceICC: nil, printerICC: printerICC, intent: correction.intent, blackPointCompensation: correction.bpc)
            let input = device
            input.withUnsafeBufferPointer { inp in
                device.withUnsafeMutableBufferPointer { out in
                    transform.apply16(inp.baseAddress!, to: out.baseAddress!, pixelCount: srgb.count)
                }
            }
        }
        var lab = [Double](repeating: 0, count: srgb.count * 3)
        let status = printerICC.withUnsafeBytes {
            selphy_printer_predict_lab($0.bindMemory(to: UInt8.self).baseAddress, printerICC.count,
                                       SELPHY_INTENT_RELATIVE_COLORIMETRIC, &device, &lab, srgb.count)
        }
        if status != SELPHY_OK { throw ScanAnalysisError.core(status) }
        let labs = (0..<srgb.count).map { [lab[$0 * 3], lab[$0 * 3 + 1], lab[$0 * 3 + 2]] }
        let white = labs[labs.count - 1]
        let patches = zip(chart.patches, labs.dropLast()).map { patch, predicted -> MeasuredPatch in
            let relative = LabMath.normaliseToPaperWhite(predicted, white: white)
            return MeasuredPatch(id: patch.id, group: patch.group, name: patch.name, srgb: patch.srgb,
                                 intendedLab: patch.labIntended, measuredLab: relative,
                                 de00: LabMath.deltaE00(relative, patch.labIntended))
        }
        return .make(patches)
    }

    static func gates(_ results: [ChartVariant: ChartScanResult]) -> [Gate] {
        var gates: [Gate] = []
        let v0 = results[.v0], v1 = results[.v1], v3 = results[.v3]
        if let v0, let v1 {
            let a = v0.summary.all, b = v1.summary.all
            let note = a.mean - b.mean >= indistinguishable ? "improvement" : "difference too small to interpret"
            gates.append(Gate(name: "G1 correction helps (V1 mean < V0 mean and V1 p95 <= V0 p95)",
                              passed: b.mean < a.mean && b.p95 <= a.p95,
                              detail: String(format: "mean %.2f -> %.2f, p95 %.2f -> %.2f (%@)", a.mean, b.mean, a.p95, b.p95, note)))
            let paired = zip(v0.patches, v1.patches).filter { $0.0.group != "uniformity" }
            let better = paired.filter { $0.1.de00 < $0.0.de00 - 0.5 }.count
            let worse = paired.filter { $0.1.de00 > $0.0.de00 + 0.5 }.count
            gates.append(Gate(name: "G1b patches improved / worsened by more than 0.5 dE00", passed: worse <= better / 4 + 1,
                              detail: "\(better) improved, \(worse) worsened of \(paired.count)"))
        }
        if let v1 {
            let c = v1.summary.neutralChromaP95
            gates.append(Gate(name: "G2 neutral axis (C* p95 <= 3 from L* 25 up) in V1", passed: c.map { $0 <= 3 } ?? false,
                              detail: "C* p95 = \(format(c))"))
        }
        if let v1, let v3 {
            gates.append(Gate(
                name: "G3 Image Optimize ON is worse than OFF (the printer-side optimisation acts on this route)",
                passed: v3.summary.all.mean > v1.summary.all.mean + indistinguishable,
                detail: String(format: "V3 mean %.2f vs V1 %.2f; if V3 = V1 the setting has no visible effect on this route (see the procedure)",
                               v3.summary.all.mean, v1.summary.all.mean)))
        }
        for variant in ChartVariant.allCases {
            if let u = results[variant]?.summary.uniformityMax {
                gates.append(Gate(name: "G4 sheet uniformity \(variant.rawValue) (4 mid-greys, max pairwise dE00 < 1)",
                                  passed: u < 1, detail: String(format: "%.2f", u)))
            }
        }
        return gates
    }

    static func format(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "–"
    }

    /// REPORT.md, in the format of validation/report.py, plus the visual verdicts of the photos
    /// and the session record.
    static func markdown(results: [ChartVariant: ChartScanResult], models: [ChartVariant: ScanSummary],
                         scannerCheck: ScannerCheckResult?, visual: [VisualVerdict], record: String) -> String {
        var lines = ["# Physical validation report", "",
                     "Evidence level: scanner-estimated colorimetry (flatbed scanner + ICC profile), not a spectrophotometer. "
                     + "dE00 against the intended appearance of the sRGB source, paper-relative.", ""]
        if let s = scannerCheck {
            lines += [String(format: "Scanner chain on the ColorChecker (%@): dE00 mean %.2f, p95 %.2f, max %.2f. ",
                             s.referenceTitle, s.summary.mean, s.summary.p95, s.summary.max)
                      + String(format: "Differences between variants smaller than about %.1f dE00 are not interpreted.", s.resolution), ""]
        } else if !results.isEmpty {
            lines += ["Scanner chain not checked on the ColorChecker: absolute values carry an unknown measurement error.", ""]
        }
        if !results.isEmpty {
            lines += ["## Summary (dE00 on all patches)", "",
                      "| Variant | Description | Mean | Median | P95 | Max | Neutral C* p95 | Dark steps seen | Model mean |",
                      "|---|---|---|---|---|---|---|---|---|"]
            for variant in ChartVariant.allCases {
                guard let r = results[variant] else { continue }
                let s = r.summary
                lines.append("| \(variant.rawValue) | \(variant.reportDescription) | \(format(s.all.mean)) | \(format(s.all.median)) | "
                             + "\(format(s.all.p95)) | \(format(s.all.max)) | \(format(s.neutralChromaP95)) | "
                             + "\(s.darkStepsDistinguishable)/\(s.darkStepsTotal) | \(format(models[variant]?.all.mean)) |")
            }
            lines += ["", "(Model mean = what the profile's own model predicts for the same chart; V3/V4 reuse V1/V0.)", ""]
            let labels = ChartVariant.allCases.filter { results[$0] != nil }
            let groups = Set(results.values.flatMap { $0.summary.groups.keys }).sorted()
            lines += ["## Mean dE00 by patch group", "", "| Group | " + labels.map(\.rawValue).joined(separator: " | ") + " |",
                      "|---|" + String(repeating: "---|", count: labels.count)]
            for g in groups {
                lines.append("| \(g) | " + labels.map { format(results[$0]?.summary.groups[g]?.mean) }.joined(separator: " | ") + " |")
            }
            lines.append("")
            lines += ["## Gates", "", "| Gate | Result | Detail |", "|---|---|---|"]
            for gate in gates(results) {
                lines.append("| \(gate.name) | \(gate.passed ? "PASS" : "FAIL") | \(gate.detail) |")
            }
            if let a = results[.v1]?.summary, let b = results[.v2]?.summary {
                let better = b.all.mean < a.all.mean ? "V2 (Relative colorimetric)" : "V1 (Perceptual)"
                lines += ["", "## Intent choice", "",
                          String(format: "Lower mean dE00: **%@** (V1 %.2f, V2 %.2f; median %.2f vs %.2f; ", better, a.all.mean, b.all.mean,
                                 a.all.median, b.all.median)
                          + "neutral C* p95 \(format(a.neutralChromaP95)) vs \(format(b.neutralChromaP95)); dark steps seen "
                          + "\(a.darkStepsDistinguishable) vs \(b.darkStepsDistinguishable)). Confirm with the photographs before changing the default."]
            }
        }
        lines += ["", "## Photographs (visual comparison under neutral light)", ""]
        if visual.isEmpty {
            lines.append("The photographs are judged visually side by side under neutral light (V0 against V1); record the verdict in the run notes.")
        } else {
            lines += ["| Photo | Closer to the screen | Notes |", "|---|---|---|"]
            for v in visual {
                lines.append("| \(v.photoRole) | \(v.choice.reportText) | \(v.notes.replacingOccurrences(of: "\n", with: " ")) |")
            }
        }
        if !record.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines += ["", "## Session record", "", record]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// results_<label>.json in the shape of analyze_scan.py, so that report.py can read it.
    static func pythonJSON(_ result: ChartScanResult) throws -> Data {
        var summary: [String: Any] = ["all": stats(result.summary.all)]
        for (group, s) in result.summary.groups { summary[group] = stats(s) }
        summary["neutral_chroma_p95"] = result.summary.neutralChromaP95 ?? NSNull()
        summary["dark_steps_distinguishable"] = result.summary.darkStepsDistinguishable
        summary["dark_steps_total"] = result.summary.darkStepsTotal
        if let u = result.summary.uniformityMax { summary["uniformity_de00_max"] = u }
        let patches: [[String: Any]] = result.patches.map {
            ["id": $0.id, "group": $0.group, "name": $0.name, "srgb": $0.srgb, "intended_lab": $0.intendedLab,
             "measured_lab": $0.measuredLab, "de00": $0.de00]
        }
        let object: [String: Any] = ["label": result.label, "scan": result.scan, "paper_white_lab": result.paperWhiteLab,
                                     "patches": patches, "summary": summary]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func stats(_ s: DeltaStats) -> [String: Any] {
        ["mean": s.mean, "median": s.median, "p95": s.p95, "max": s.max, "n": s.n]
    }

    /// results_<label>.csv of analyze_scan.py.
    static func csv(_ result: ChartScanResult) -> String {
        var lines = ["id,group,name,R,G,B,L_intended,a_intended,b_intended,L_measured,a_measured,b_measured,dE00"]
        for p in result.patches {
            let fields: [String] = [p.id, p.group, p.name] + p.srgb.map(String.init) + p.intendedLab.map { "\($0)" }
                + p.measuredLab.map { "\($0)" } + ["\(p.de00)"]
            lines.append(fields.map { $0.contains(",") ? "\"\($0)\"" : $0 }.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// The verdict on one photo printed as original and corrected, judged side by side.
struct VisualVerdict: Codable, Equatable, Identifiable, Sendable {
    enum Choice: String, Codable, CaseIterable, Identifiable, Sendable {
        case notJudged, corrected, original, same

        var id: String { rawValue }

        var title: String {
            switch self {
            case .notJudged: tr("Not judged yet")
            case .corrected: tr("Corrected print")
            case .original: tr("Original print")
            case .same: tr("No visible difference")
            }
        }

        var reportText: String {
            switch self {
            case .notJudged: "not judged"
            case .corrected: "corrected (V1)"
            case .original: "original (V0)"
            case .same: "no visible difference"
            }
        }
    }

    var id: String { photoRole }
    var photoRole: String
    var choice: Choice = .notJudged
    var notes: String = ""
}
