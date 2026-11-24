import SwiftUI
import Charts
import UniformTypeIdentifiers

/// Computes the statistics table and the intent comparison off the main thread.
@MainActor
final class StatisticsModel: ObservableObject {
    @Published private(set) var rows: [PhotoAnalysisRow] = []
    @Published private(set) var intentResults: [IntentResult] = []
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?

    func loadRows(photos: [URL], printerICC: Data, intent: RenderingIntent, blackPointCompensation: Bool) async {
        isWorking = true
        defer { isWorking = false }
        rows = []
        done = 0
        total = photos.count
        var collected: [PhotoAnalysisRow] = []
        for url in photos {
            if Task.isCancelled { return }
            let row = await Task.detached(priority: .utility) { () -> PhotoAnalysisRow in
                do {
                    let analysis = try PreviewSession().quickAnalysis(
                        sourceURL: url, printerICC: printerICC, intent: intent, blackPointCompensation: blackPointCompensation)
                    return PhotoAnalysisRow.make(url: url, analysis: analysis)
                } catch {
                    return PhotoAnalysisRow(url: url, error: error.localizedDescription)
                }
            }.value
            collected.append(row)
            rows = collected
            done += 1
        }
    }

    func loadIntents(photo: URL?, printerICC: Data, blackPointCompensation: Bool) async {
        intentResults = []
        guard let photo else { return }
        var results: [IntentResult] = []
        for intent in RenderingIntent.allCases {
            if Task.isCancelled { return }
            let result = await Task.detached(priority: .utility) { () -> IntentResult? in
                guard let analysis = try? PreviewSession().quickAnalysis(
                    sourceURL: photo, printerICC: printerICC, intent: intent, blackPointCompensation: blackPointCompensation)
                else { return nil }
                return PhotoAnalysisRow.result(for: analysis, intent: intent)
            }.value
            if let result { results.append(result) }
            intentResults = results
        }
    }
}

/// The statistics sheet: deviation distribution of the selected photo, a table of all the loaded
/// photos, the comparison of the three rendering intents, and CSV/PDF export.
struct StatisticsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let photos: [URL]
    @State private var selected: URL?
    @StateObject private var model = StatisticsModel()
    @State private var printerICC: Data?
    @State private var errorMessage: String?

    private struct RowsKey: Equatable {
        var photos: [URL]
        var intent: RenderingIntent
        var bpc: Bool
        var profile: Data?
    }

    private struct IntentsKey: Equatable {
        var photo: URL?
        var bpc: Bool
        var profile: Data?
    }

    init(photos: [URL], selected: URL?) {
        self.photos = photos
        _selected = State(initialValue: selected)
    }

    private var selectedRow: PhotoAnalysisRow? { model.rows.first { $0.url == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detail
                    intents
                    table
                    Text(tr("Computed on a reduced copy of each photo, from the printer profile's model: estimates, not print measurements."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 560)
        .onAppear { loadProfile() }
        .task(id: RowsKey(photos: photos, intent: settings.renderingIntent, bpc: settings.blackPointCompensation, profile: settings.profileBookmark)) {
            guard let printerICC else { return }
            await model.loadRows(photos: photos, printerICC: printerICC, intent: settings.renderingIntent, blackPointCompensation: settings.blackPointCompensation)
        }
        .task(id: IntentsKey(photo: selected, bpc: settings.blackPointCompensation, profile: settings.profileBookmark)) {
            guard let printerICC else { return }
            await model.loadIntents(photo: selected, printerICC: printerICC, blackPointCompensation: settings.blackPointCompensation)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(tr("Colour deviation statistics")).font(.title3.weight(.semibold))
            Spacer()
            if model.isWorking {
                ProgressView(value: Double(model.done), total: Double(max(1, model.total)))
                    .frame(width: 90)
            }
            Button(tr("Export CSV…")) { export(csv: true) }.disabled(model.rows.isEmpty)
            Button(tr("Export PDF…")) { export(csv: false) }.disabled(model.rows.isEmpty)
            Button(tr("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var detail: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if photos.count > 1 {
                    Picker(tr("Photo"), selection: $selected) {
                        ForEach(photos, id: \.self) { url in
                            Text(url.lastPathComponent).tag(Optional(url))
                        }
                    }
                    .frame(maxWidth: 360)
                }
                if let row = selectedRow, let s = row.statistics {
                    HStack(spacing: 18) {
                        metric(tr("Mean"), s.mean)
                        metric(tr("Median"), s.median)
                        metric(tr("95th pct"), s.p95)
                        metric(tr("99th pct"), s.p99)
                        metric(tr("Max"), s.max)
                    }
                    HStack(spacing: 14) {
                        ForEach(Array(zip(s.thresholds, s.shareAbove)), id: \.0) { threshold, share in
                            Text(trf("ΔE00 above %.0f: %.0f%%", Double(threshold), share * 100)).font(.caption)
                        }
                    }
                    Chart(s.histogram) { bin in
                        BarMark(
                            xStart: .value("from", bin.lower), xEnd: .value("to", bin.upper),
                            y: .value("share", bin.share * 100)
                        )
                    }
                    .chartXAxisLabel(tr("ΔE00 (the last bar collects everything above)"))
                    .chartYAxisLabel(tr("% of pixels"))
                    .frame(height: 150)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            Text(tr("Lightness zone")).bold()
                            Text(tr("Pixels")).bold()
                            Text(tr("Mean")).bold()
                            Text(tr("95th pct")).bold()
                            Text(tr("ΔE > 3")).bold()
                        }
                        ForEach(s.zones, id: \.zone) { zone in
                            GridRow {
                                Text(zone.zone.title)
                                Text(String(format: "%.0f%%", zone.share * 100))
                                Text(String(format: "%.1f", zone.mean))
                                Text(String(format: "%.1f", zone.p95))
                                Text(String(format: "%.0f%%", zone.shareAbove * 100))
                            }
                        }
                    }
                    .font(.caption)
                } else if let error = selectedRow?.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    Text(tr("Computing…")).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(selected?.lastPathComponent ?? tr("Photo"))
        }
    }

    @ViewBuilder
    private var intents: some View {
        GroupBox(tr("Rendering intents compared (selected photo)")) {
            VStack(alignment: .leading, spacing: 8) {
                if model.intentResults.isEmpty {
                    Text(tr("Computing…")).foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            Text(tr("Intent")).bold()
                            Text(tr("Mean")).bold()
                            Text(tr("95th pct")).bold()
                            Text(tr("ΔE > 3")).bold()
                            Text(tr("Shadows lost")).bold()
                            Text(tr("Dull colours")).bold()
                        }
                        ForEach(model.intentResults) { result in
                            GridRow {
                                Text(result.intent.title)
                                Text(String(format: "%.1f", result.meanDeltaE))
                                Text(String(format: "%.1f", result.p95DeltaE))
                                Text(String(format: "%.0f%%", result.shareNotReproducible * 100))
                                Text(String(format: "%.0f%%", result.shareBelowDarkest * 100))
                                Text(String(format: "%.0f%%", result.gamutLossShare * 100))
                            }
                        }
                    }
                    .font(.caption)
                    if model.intentResults.count == RenderingIntent.allCases.count,
                       let best = IntentAdvisor.best(model.intentResults) {
                        Label(IntentAdvisor.explanation(for: best, among: model.intentResults), systemImage: "lightbulb")
                            .font(.callout)
                        Text(tr("The suggestion is based on the predicted deviation only: judge shadows and saturated colours in the Dark zones and Out of gamut views, and confirm with a print."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var table: some View {
        GroupBox(tr("All loaded photos")) {
            Table(model.rows.sorted { ($0.statistics?.mean ?? 0) > ($1.statistics?.mean ?? 0) }) {
                TableColumn(tr("Photo")) { Text($0.name).lineLimit(1) }
                TableColumn(tr("Mean")) { Text($0.statistics.map { String(format: "%.1f", $0.mean) } ?? "—") }
                TableColumn(tr("Median")) { Text($0.statistics.map { String(format: "%.1f", $0.median) } ?? "—") }
                TableColumn(tr("95th pct")) { Text($0.statistics.map { String(format: "%.1f", $0.p95) } ?? "—") }
                TableColumn(tr("Max")) { Text($0.statistics.map { String(format: "%.1f", $0.max) } ?? "—") }
                TableColumn(tr("ΔE > 3")) { Text($0.statistics == nil ? "—" : String(format: "%.0f%%", $0.shareNotReproducible * 100)) }
                TableColumn(tr("Shadows lost")) { Text($0.statistics == nil ? "—" : String(format: "%.0f%%", $0.shareBelowDarkest * 100)) }
                TableColumn(tr("Dull colours")) { Text($0.statistics == nil ? "—" : String(format: "%.0f%%", $0.gamutLossShare * 100)) }
            }
            .frame(minHeight: 120, maxHeight: 240)
        }
    }

    private func metric(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.1f", value)).font(.title3.monospacedDigit())
        }
    }

    // MARK: Profile and export

    private func loadProfile() {
        do {
            guard let url = try settings.resolveProfileURL() else {
                errorMessage = tr("Choose the ICC profile to see the preview.")
                return
            }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            printerICC = try Data(contentsOf: url)
        } catch {
            errorMessage = trf("Unable to access the ICC profile: %@", error.localizedDescription)
        }
    }

    private func export(csv: Bool) {
        let rows = model.rows.sorted { $0.name < $1.name }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .pdf]
        panel.nameFieldStringValue = csv ? "selphy-analysis.csv" : "selphy-analysis.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if csv {
                let text = AnalysisExport.csv(rows: rows, intent: settings.renderingIntent, blackPointCompensation: settings.blackPointCompensation)
                try Data(text.utf8).write(to: url, options: .atomic)
            } else {
                guard let data = AnalysisExport.pdf(
                    rows: rows, intent: settings.renderingIntent, intentPhoto: selected?.lastPathComponent,
                    intentResults: model.intentResults) else {
                    errorMessage = tr("The report could not be created.")
                    return
                }
                try data.write(to: url, options: .atomic)
            }
            errorMessage = nil
        } catch {
            errorMessage = trf("Saving failed: %@", error.localizedDescription)
        }
    }
}
