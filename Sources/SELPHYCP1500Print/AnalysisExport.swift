import AppKit
import CoreGraphics
import Foundation

/// CSV and PDF reports of the per-photo analysis. The CSV uses fixed English column names and a
/// dot as decimal separator so that it can be read by any tool; the PDF follows the app language.
enum AnalysisExport {
    static let csvHeader = [
        "file", "rendering_intent", "black_point_compensation", "mean_dE00", "median_dE00", "p95_dE00", "max_dE00",
        "pct_dE00_above_3", "pct_below_darkest_tone", "pct_chroma_loss_above_8", "darkest_tone_L"
    ]

    static func escapeCSV(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func number(_ value: Double, _ decimals: Int = 2) -> String {
        String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func csv(rows: [PhotoAnalysisRow], intent: RenderingIntent, blackPointCompensation: Bool) -> String {
        var lines = [csvHeader.joined(separator: ",")]
        for row in rows {
            guard let s = row.statistics else {
                lines.append([escapeCSV(row.name), intent.rawValue, blackPointCompensation ? "yes" : "no"]
                    .joined(separator: ",") + String(repeating: ",", count: csvHeader.count - 3))
                continue
            }
            let fields = [
                escapeCSV(row.name), intent.rawValue, blackPointCompensation ? "yes" : "no",
                number(s.mean), number(s.median), number(s.p95), number(s.max),
                number(row.shareNotReproducible * 100, 1), number(row.shareBelowDarkest * 100, 1),
                number(row.gamutLossShare * 100, 1), number(row.darkestToneL, 1)
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A4 report: the table of all photos and, if given, the intent comparison of one photo.
    static func pdf(
        rows: [PhotoAnalysisRow], intent: RenderingIntent, intentPhoto: String?, intentResults: [IntentResult], date: Date = Date()
    ) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

        var y: CGFloat = 800
        context.beginPDFPage(nil)

        func draw(_ text: String, x: CGFloat, size: CGFloat = 9, bold: Bool = false, color: NSColor = .black) {
            let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
        }
        func newPageIfNeeded(_ needed: CGFloat = 20) {
            if y < 50 + needed {
                context.endPDFPage()
                context.beginPDFPage(nil)
                y = 800
            }
        }
        func line(_ text: String, size: CGFloat = 9, bold: Bool = false, gap: CGFloat = 14, color: NSColor = .black) {
            newPageIfNeeded()
            draw(text, x: 40, size: size, bold: bold, color: color)
            y -= gap
        }

        line("SELPHY CP1500 Print", size: 16, bold: true, gap: 20)
        line(tr("Predicted colour deviation per photo"), size: 11, bold: true, gap: 16)
        line(trf("%@ · %@ · rendering intent: %@", DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short),
                 tr("model estimates on a reduced copy, not print measurements"), intent.title), size: 8, gap: 18, color: .darkGray)

        let columns: [(String, CGFloat)] = [
            (tr("Photo"), 40), (tr("Mean"), 215), (tr("Median"), 255), (tr("95th pct"), 300),
            (tr("Max"), 345), (tr("ΔE > 3"), 385), (tr("Shadows lost"), 430), (tr("Dull colours"), 495)
        ]
        func header() {
            newPageIfNeeded()
            for (title, x) in columns { draw(title, x: x, size: 8, bold: true) }
            y -= 14
        }
        header()
        for row in rows {
            newPageIfNeeded()
            if y == 800 && row.id != rows.first?.id { header() }
            let name = row.name.count > 30 ? String(row.name.prefix(29)) + "…" : row.name
            draw(name, x: 40)
            if let s = row.statistics {
                draw(number(s.mean, 1), x: 215)
                draw(number(s.median, 1), x: 255)
                draw(number(s.p95, 1), x: 300)
                draw(number(s.max, 1), x: 345)
                draw(number(row.shareNotReproducible * 100, 0) + "%", x: 385)
                draw(number(row.shareBelowDarkest * 100, 0) + "%", x: 430)
                draw(number(row.gamutLossShare * 100, 0) + "%", x: 495)
            } else {
                draw(row.error ?? "—", x: 215, color: .red)
            }
            y -= 13
        }

        if let intentPhoto, !intentResults.isEmpty {
            y -= 14
            newPageIfNeeded(90)
            line(trf("Rendering intents for %@", intentPhoto), size: 11, bold: true, gap: 16)
            let intentColumns: [(String, CGFloat)] = [
                (tr("Intent"), 40), (tr("Mean"), 215), (tr("95th pct"), 265), (tr("ΔE > 3"), 320),
                (tr("Shadows lost"), 375), (tr("Dull colours"), 450)
            ]
            for (title, x) in intentColumns { draw(title, x: x, size: 8, bold: true) }
            y -= 14
            for result in intentResults {
                draw(result.intent.title, x: 40)
                draw(number(result.meanDeltaE, 1), x: 215)
                draw(number(result.p95DeltaE, 1), x: 265)
                draw(number(result.shareNotReproducible * 100, 0) + "%", x: 320)
                draw(number(result.shareBelowDarkest * 100, 0) + "%", x: 375)
                draw(number(result.gamutLossShare * 100, 0) + "%", x: 450)
                y -= 13
            }
            if let best = IntentAdvisor.best(intentResults) {
                y -= 6
                line(IntentAdvisor.explanation(for: best, among: intentResults), size: 8, color: .darkGray)
            }
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
