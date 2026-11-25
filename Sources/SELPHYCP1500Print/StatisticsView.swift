import SwiftUI
import Charts
import UniformTypeIdentifiers

/// Computes the statistics table and the intent comparison off the main thread, through the
/// session-wide `AnalysisStore` (results already computed are reused).
@MainActor
final class StatisticsModel: ObservableObject {
    @Published private(set) var rows: [PhotoAnalysisRow] = []
    @Published private(set) var intentResults: [IntentResult] = []
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var isWorking = false
    @Published private(set) var scope: DeltaEScope?

    /// The analysis maps of the photo in the scope, kept so that changing the axis is immediate.
    private var scopeMaps: PixelMaps?
    private var scopeMapsKey: String?

    let store: AnalysisStore

    init(store: AnalysisStore = .shared) {
        self.store = store
    }

    /// Photos analysed at the same time. Each analysis already uses several cores for the colour
    /// conversion, so a few in parallel are enough to keep the machine busy.
    static var parallelism: Int { max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)) }

    func loadRows(photos: [URL], printerICC: Data, profileDigest: Data, intent: RenderingIntent,
                  blackPointCompensation: Bool) async {
        isWorking = true
        defer { isWorking = false }
        rows = []
        done = 0
        total = photos.count
        let store = store
        var byURL: [URL: PhotoAnalysisRow] = [:]
        await withTaskGroup(of: (URL, PhotoAnalysisRow).self) { group in
            var next = 0
            while next < min(Self.parallelism, photos.count) {
                let url = photos[next]
                next += 1
                group.addTask(priority: .utility) {
                    Self.row(url: url, store: store, printerICC: printerICC, profileDigest: profileDigest,
                             intent: intent, blackPointCompensation: blackPointCompensation)
                }
            }
            while let result = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                byURL[result.0] = result.1
                rows = photos.compactMap { byURL[$0] }
                done += 1
                if next < photos.count {
                    let url = photos[next]
                    next += 1
                    group.addTask(priority: .utility) {
                        Self.row(url: url, store: store, printerICC: printerICC, profileDigest: profileDigest,
                                 intent: intent, blackPointCompensation: blackPointCompensation)
                    }
                }
            }
        }
    }

    nonisolated private static func row(
        url: URL, store: AnalysisStore, printerICC: Data, profileDigest: Data, intent: RenderingIntent,
        blackPointCompensation: Bool
    ) -> (URL, PhotoAnalysisRow) {
        let entry = store.entries(url: url, printerICC: printerICC, profileDigest: profileDigest,
                                  intents: [intent], blackPointCompensation: blackPointCompensation)[0]
        return (url, entry.row)
    }

    /// The ΔE distribution of `photo` along `axis`, for the rendering intent in use.
    func loadScope(photo: URL?, printerICC: Data, profileDigest: Data, intent: RenderingIntent,
                   blackPointCompensation: Bool, axis: ScopeAxis) async {
        guard let photo else {
            scope = nil
            return
        }
        let key = "\(photo.path)|\(intent.rawValue)|\(blackPointCompensation)|\(profileDigest.base64EncodedString())"
        var maps = key == scopeMapsKey ? scopeMaps : nil
        if maps == nil {
            scope = nil
            maps = try? await Task.detached(priority: .utility) {
                try PreviewSession().quickAnalysis(sourceURL: photo, printerICC: printerICC, intent: intent,
                                                   blackPointCompensation: blackPointCompensation).maps
            }.value
            if Task.isCancelled { return }
            scopeMaps = maps
            scopeMapsKey = maps == nil ? nil : key
        }
        guard let maps else {
            scope = nil
            return
        }
        let made = await Task.detached(priority: .utility) { DeltaEScope.make(maps: maps, axis: axis) }.value
        if Task.isCancelled { return }
        scope = made
    }

    func loadIntents(photo: URL?, printerICC: Data, profileDigest: Data, blackPointCompensation: Bool) async {
        intentResults = []
        guard let photo else { return }
        let store = store
        let entries = await Task.detached(priority: .utility) {
            store.entries(url: photo, printerICC: printerICC, profileDigest: profileDigest,
                          intents: RenderingIntent.allCases, blackPointCompensation: blackPointCompensation)
        }.value
        if Task.isCancelled { return }
        intentResults = entries.compactMap(\.result)
    }
}

/// The Statistics window: deviation distribution of the selected photo, the comparison of the three
/// rendering intents, a sortable table of all the loaded photos (a click selects the photo in the
/// main window too), and CSV/PDF export. It can stay open next to the main window.
struct StatisticsView: View {
    static let windowID = "statistics"

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var selection: PhotoSelection
    @StateObject private var model = StatisticsModel()
    @State private var printerICC: Data?
    @State private var profileDigest: Data?
    @State private var errorMessage: String?
    @State private var sortOrder = [KeyPathComparator(\PhotoAnalysisRow.sortMean, order: .reverse)]
    @AppStorage("scopeAxis") private var scopeAxis: ScopeAxis = .width

    private struct RowsKey: Equatable {
        var photos: [URL]
        var intent: RenderingIntent
        var bpc: Bool
        var profile: Data?
    }

    private struct ScopeKey: Equatable {
        var photo: URL?
        var intent: RenderingIntent
        var bpc: Bool
        var profile: Data?
        var axis: ScopeAxis
    }

    private struct IntentsKey: Equatable {
        var photo: URL?
        var bpc: Bool
        var profile: Data?
    }

    private var photos: [URL] { selection.photos }
    private var selected: URL? { selection.selected }
    private var selectedRow: PhotoAnalysisRow? { model.rows.first { $0.url == selected } }
    private var sortedRows: [PhotoAnalysisRow] { model.rows.sorted(using: sortOrder) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if photos.isEmpty {
                placeholder
            } else {
                VSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            detail
                            scopeSection
                            intents
                            Text(tr("Computed on a reduced copy of each photo, from the printer profile's model: estimates, not print measurements."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.trailing, 6)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 260)
                    table
                        .padding(.top, 8)
                        .frame(minHeight: 150)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 560)
        // Its own, appearance-aware background: without it the view had none when drawn outside a
        // real window (the light-mode snapshot came out dark), as happened to the main pane.
        .background(settings.theme.palette.windowBackground)
        .themed(settings.theme)
        .navigationTitle(tr("Colour deviation statistics"))
        .onAppear { loadProfile() }
        .onChange(of: settings.profileBookmark) { loadProfile() }
        .task(id: RowsKey(photos: photos, intent: settings.renderingIntent, bpc: settings.blackPointCompensation, profile: profileDigest)) {
            guard let printerICC, let profileDigest else { return }
            await model.loadRows(photos: photos, printerICC: printerICC, profileDigest: profileDigest,
                                 intent: settings.renderingIntent, blackPointCompensation: settings.blackPointCompensation)
        }
        .task(id: ScopeKey(photo: selected, intent: settings.renderingIntent, bpc: settings.blackPointCompensation,
                           profile: profileDigest, axis: scopeAxis)) {
            guard let printerICC, let profileDigest else { return }
            await model.loadScope(photo: selected, printerICC: printerICC, profileDigest: profileDigest,
                                  intent: settings.renderingIntent, blackPointCompensation: settings.blackPointCompensation,
                                  axis: scopeAxis)
        }
        .onChange(of: scopeAxis) { ScopeHighlight.shared.marker = nil }
        .onDisappear { ScopeHighlight.shared.marker = nil }
        .task(id: IntentsKey(photo: selected, bpc: settings.blackPointCompensation, profile: profileDigest)) {
            guard let printerICC, let profileDigest else { return }
            await model.loadIntents(photo: selected, printerICC: printerICC, profileDigest: profileDigest,
                                    blackPointCompensation: settings.blackPointCompensation)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(trf("Rendering intent in use: %@", settings.renderingIntent.title))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if model.isWorking {
                ProgressView(value: Double(model.done), total: Double(max(1, model.total)))
                    .frame(width: 90)
                Text(trf("Analysing %d of %d", min(model.done + 1, model.total), model.total))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button(tr("Export CSV…")) { export(csv: true) }.disabled(model.rows.isEmpty)
            Button(tr("Export PDF…")) { export(csv: false) }.disabled(model.rows.isEmpty)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(tr("Add photos in the main window to see their statistics."))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Sections

    @ViewBuilder
    private var detail: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let row = selectedRow, let s = row.statistics {
                    HStack(spacing: 18) {
                        metric(tr("Mean"), s.mean, help: tr("Average predicted ΔE00 over the pixels of the photo."))
                        metric(tr("Median"), s.median, help: tr("Half of the pixels deviate less than this."))
                        metric(tr("95th pct"), s.p95, help: tr("95% of the pixels deviate less than this: it describes the worst areas."))
                        metric(tr("99th pct"), s.p99, help: tr("99% of the pixels deviate less than this."))
                        metric(tr("Max"), s.max, help: tr("The largest deviation of a single pixel, often an isolated saturated colour."))
                    }
                    HStack(spacing: 14) {
                        ForEach(Array(zip(s.thresholds, s.shareAbove)), id: \.0) { threshold, share in
                            Text(trf("ΔE00 above %.0f: %.0f%%", Double(threshold), share * 100)).font(.caption)
                        }
                    }
                    histogram(s)
                    Text(tr("As a guide: ΔE00 around 1 is at the limit of visibility, 2 to 3 is visible side by side, above 6 the colour looks clearly different."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    zones(s)
                } else if let error = selectedRow?.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    Text(tr("Computing…")).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            if photos.count > 1 {
                Picker(tr("Photo"), selection: $selection.selected) {
                    ForEach(photos, id: \.self) { url in
                        Text(url.lastPathComponent).tag(Optional(url))
                    }
                }
                .frame(maxWidth: 380)
            } else {
                Text(selected?.lastPathComponent ?? tr("Photo"))
            }
        }
    }

    private func histogram(_ s: DeviationStatistics) -> some View {
        let upper = s.histogram.last?.upper ?? 12
        return Chart {
            ForEach(s.histogram) { bin in
                BarMark(
                    xStart: .value("from", bin.lower), xEnd: .value("to", bin.upper),
                    y: .value("share", bin.share * 100)
                )
                .foregroundStyle(by: .value("band", DeviationBand.band(forLower: bin.lower).title))
            }
            RuleMark(x: .value("mean", min(s.mean, upper)))
                .foregroundStyle(Color.primary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text(tr("mean")).font(.caption2).foregroundStyle(.secondary)
                }
            RuleMark(x: .value("p95", min(s.p95, upper)))
                .foregroundStyle(Color.primary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 2]))
                .annotation(position: .top, alignment: .trailing) {
                    Text(tr("95th pct")).font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartForegroundStyleScale(
            domain: DeviationBand.allCases.map(\.title),
            range: DeviationBand.allCases.map(\.color)
        )
        .chartXScale(domain: 0...upper)
        .chartXAxisLabel(tr("ΔE00 (the last bar collects everything above)"))
        .chartYAxisLabel(tr("% of pixels"))
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 190)
    }

    private func zones(_ s: DeviationStatistics) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text(tr("Lightness zone")).bold()
                Text(tr("Pixels")).bold()
                Text(tr("Mean")).bold()
                Text(tr("95th pct")).bold()
                Text(tr("ΔE > 3")).bold().help(tr("Share of the zone's pixels with a predicted ΔE00 above 3."))
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
    }

    private var scopeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker(tr("Along"), selection: $scopeAxis) {
                        ForEach(ScopeAxis.allCases) { axis in
                            Text(axis.title).tag(axis)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 460)
                    Spacer()
                }
                if let scope = model.scope, scope.axis == scopeAxis {
                    DeltaEScopeView(scope: scope) { fraction in markPreview(scope: scope, fraction: fraction) }
                } else {
                    Text(tr("Computing…")).foregroundStyle(.secondary).frame(height: 200)
                }
                Text(scopeExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(tr("ΔE00 distribution (selected photo)"))
        }
    }

    private var scopeExplanation: String {
        switch scopeAxis {
        case .width, .height:
            tr("Each vertical line is the ΔE00 distribution of one strip of the photo, brighter where more pixels are. Move the pointer over the plot to mark the strip on the preview in the main window.")
        case .lightness:
            tr("Each vertical line is the ΔE00 distribution of the pixels of one lightness: it shows which tones (shadows, midtones, highlights) the print reproduces worst.")
        case .hue:
            tr("Each vertical line is the ΔE00 distribution of the pixels of one hue: it shows which colours the print reproduces worst.")
        }
    }

    /// For the width and height axes, marks the strip under the pointer on the main window's preview.
    private func markPreview(scope: DeltaEScope, fraction: Double?) {
        guard let fraction, let photo = selected, scope.axis == .width || scope.axis == .height else {
            ScopeHighlight.shared.marker = nil
            return
        }
        let column = scope.column(at: fraction)
        let span = 1 / Double(scope.columns)
        ScopeHighlight.shared.marker = ScopeHighlight.Marker(
            photo: photo, vertical: scope.axis == .width, start: Double(column) * span, span: span)
    }

    @ViewBuilder
    private var intents: some View {
        GroupBox(tr("Rendering intents compared (selected photo)")) {
            VStack(alignment: .leading, spacing: 8) {
                if model.intentResults.isEmpty {
                    Text(tr("Computing…")).foregroundStyle(.secondary)
                } else {
                    let complete = model.intentResults.count == RenderingIntent.allCases.count
                    let best = complete ? IntentAdvisor.best(model.intentResults) : nil
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            Text("")
                            Text(tr("Intent")).bold()
                            Text(tr("Mean")).bold()
                            Text(tr("95th pct")).bold()
                            Text(tr("ΔE > 3")).bold().help(tr("Share of pixels with a predicted ΔE00 above 3."))
                            Text(tr("Shadows lost")).bold().help(tr("Share of pixels darker than the darkest tone the print reproduces."))
                            Text(tr("Dull colours")).bold().help(tr("Share of pixels whose chroma the print reduces by more than C* 8."))
                        }
                        ForEach(model.intentResults) { result in
                            let isBest = result.intent == best?.intent
                            let weight: Font.Weight = isBest ? .semibold : .regular
                            GridRow {
                                Image(systemName: isBest ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isBest ? Color.green : Color.secondary.opacity(0.4))
                                HStack(spacing: 4) {
                                    Text(result.intent.title).fontWeight(weight)
                                    if result.intent == settings.renderingIntent {
                                        Text(tr("in use")).foregroundStyle(.secondary)
                                    }
                                }
                                Text(String(format: "%.1f", result.meanDeltaE)).fontWeight(weight)
                                Text(String(format: "%.1f", result.p95DeltaE)).fontWeight(weight)
                                Text(String(format: "%.0f%%", result.shareNotReproducible * 100)).fontWeight(weight)
                                Text(String(format: "%.0f%%", result.shareBelowDarkest * 100)).fontWeight(weight)
                                Text(String(format: "%.0f%%", result.gamutLossShare * 100)).fontWeight(weight)
                            }
                        }
                    }
                    .font(.caption)
                    if let best {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Label(IntentAdvisor.explanation(for: best, among: model.intentResults), systemImage: "lightbulb")
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(trf("Use %@", best.intent.title)) { settings.renderingIntent = best.intent }
                                .disabled(settings.renderingIntent == best.intent)
                                .help(tr("Sets this rendering intent for the preview and the copies."))
                        }
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

    private var table: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("All loaded photos")).font(.headline)
            Table(sortedRows, selection: $selection.selected, sortOrder: $sortOrder) {
                TableColumn(tr("Photo"), value: \.name) { Text($0.name).lineLimit(1) }
                TableColumn(tr("Mean"), value: \.sortMean) { Text($0.statistics.map { String(format: "%.1f", $0.mean) } ?? "—") }
                TableColumn(tr("Median"), value: \.sortMedian) { Text($0.statistics.map { String(format: "%.1f", $0.median) } ?? "—") }
                TableColumn(tr("95th pct"), value: \.sortP95) { Text($0.statistics.map { String(format: "%.1f", $0.p95) } ?? "—") }
                TableColumn(tr("Max"), value: \.sortMax) { Text($0.statistics.map { String(format: "%.1f", $0.max) } ?? "—") }
                TableColumn(tr("ΔE > 3"), value: \.sortNotReproducible) { Text($0.statistics == nil ? "—" : String(format: "%.0f%%", $0.shareNotReproducible * 100)) }
                TableColumn(tr("Shadows lost"), value: \.sortShadowsLost) { Text($0.statistics == nil ? "—" : String(format: "%.0f%%", $0.shareBelowDarkest * 100)) }
                TableColumn(tr("Dull colours"), value: \.sortDullColours) { Text($0.statistics == nil ? "—" : String(format: "%.0f%%", $0.gamutLossShare * 100)) }
            }
            Text(tr("Click a photo to show it here and in the main window; click a column title to sort."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, _ value: Double, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.1f", value)).font(.title3.monospacedDigit())
        }
        .help(help)
    }

    // MARK: Profile and export

    private func loadProfile() {
        do {
            guard let url = try settings.resolveProfileURL() else {
                printerICC = nil
                profileDigest = nil
                errorMessage = tr("Choose the ICC profile to see the preview.")
                return
            }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            printerICC = data
            profileDigest = ContentDigest.of(data)
            errorMessage = nil
        } catch {
            printerICC = nil
            profileDigest = nil
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

extension DeviationBand {
    var color: Color { Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1) }
}
