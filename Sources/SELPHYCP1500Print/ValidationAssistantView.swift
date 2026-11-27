import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The steps of the print validation assistant (Documentation/PHYSICAL_VALIDATION.md).
enum ValidationStep: String, CaseIterable, Identifiable {
    case intro, reference, files, printing, scannerCheck, scans, visual, report

    var id: String { rawValue }

    var title: String {
        switch self {
        case .intro: tr("Introduction")
        case .reference: tr("Reference chart")
        case .files: tr("Files to print")
        case .printing: tr("Print session")
        case .scannerCheck: tr("Scanner check")
        case .scans: tr("Chart scans")
        case .visual: tr("Photographs")
        case .report: tr("Report")
        }
    }

    var systemImage: String {
        switch self {
        case .intro: "info.circle"
        case .reference: "square.grid.3x2"
        case .files: "doc.on.doc"
        case .printing: "printer"
        case .scannerCheck: "scanner"
        case .scans: "doc.viewfinder"
        case .visual: "eye"
        case .report: "doc.text"
        }
    }

    func isVisible(in mode: ValidationMode) -> Bool {
        switch self {
        case .reference, .scannerCheck, .scans: mode == .scanner
        default: true
        }
    }
}

struct ValidationAssistantView: View {
    static let windowID = "validation"

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model: ValidationModel
    @State private var step: ValidationStep? = .intro
    @State private var colorCheckerScan: ScanImage?
    @State private var colorCheckerThumbnail: CGImage?
    @State private var confirmingReset = false

    init(settings: AppSettings, storeURL: URL? = ValidationModel.defaultStoreURL, initialStep: ValidationStep = .intro) {
        _model = StateObject(wrappedValue: ValidationModel(settings: settings, storeURL: storeURL))
        _step = State(initialValue: initialStep)
    }

    private var steps: [ValidationStep] { ValidationStep.allCases.filter { $0.isVisible(in: model.data.mode) } }

    var body: some View {
        NavigationSplitView {
            List(selection: $step) {
                ForEach(Array(steps.enumerated()), id: \.element) { index, item in
                    HStack {
                        Label("\(index + 1). \(item.title)", systemImage: item.systemImage)
                        Spacer()
                        if isDone(item) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                    .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        content(step ?? .intro)
                        navigation
                    }
                    .padding(24)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                statusBar
            }
            .background(settings.theme.palette.windowBackground)
        }
        .themed(settings.theme)
        .frame(minWidth: 860, minHeight: 600)
        .navigationTitle(tr("Print validation assistant"))
        .confirmationDialog(tr("Start a new validation session?"), isPresented: $confirmingReset) {
            Button(tr("Start again"), role: .destructive) {
                model.reset()
                colorCheckerScan = nil
                colorCheckerThumbnail = nil
                step = .intro
            }
        } message: {
            Text(tr("The choices, results and notes of the current session are discarded. Exported files are not touched."))
        }
        .task { await model.updateReport() }
    }

    private func isDone(_ item: ValidationStep) -> Bool {
        let d = model.data
        switch item {
        case .intro: return settings.profileBookmark != nil
        case .reference: return true
        case .files: return d.exportedAt != nil
        case .printing: return !d.record.isEmpty && PrintChecklist.items.allSatisfy { d.checklist[$0.key] == true }
        case .scannerCheck: return d.scannerCheck != nil
        case .scans:
            let charts = d.plan.filter { $0.chartVariant != nil }
            return !charts.isEmpty && charts.allSatisfy { d.scans[$0.code]?.result != nil }
        case .visual: return d.visual.contains { $0.choice != .notJudged }
        case .report: return false
        }
    }

    // MARK: Layout helpers

    @ViewBuilder
    private func content(_ step: ValidationStep) -> some View {
        Text(step.title).font(.title2.bold())
        switch step {
        case .intro: intro
        case .reference: reference
        case .files: files
        case .printing: printing
        case .scannerCheck: scannerCheck
        case .scans: scans
        case .visual: visual
        case .report: reportView
        }
    }

    private var navigation: some View {
        HStack {
            if let index = steps.firstIndex(of: step ?? .intro), index > 0 {
                Button(tr("Back")) { self.step = steps[index - 1] }
            }
            Spacer()
            if let index = steps.firstIndex(of: step ?? .intro), index < steps.count - 1 {
                Button(tr("Next")) { self.step = steps[index + 1] }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var statusBar: some View {
        if model.busy != nil || model.message != nil || model.errorMessage != nil {
            HStack(spacing: 8) {
                if let busy = model.busy {
                    ProgressView().controlSize(.small)
                    Text(busy)
                } else if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if let message = model.message {
                    Label(message, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 1. Introduction

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            paragraph(tr("This assistant checks with real prints whether the pre-correction improves the printed colour, which rendering intent prints best, and whether the printer's own Image Optimize stays out of the way. It follows the procedure the project uses for its validation."))
            paragraph(tr("It takes two sessions: printing (about an hour), and scanning at least 24 hours later, when the prints have settled. The assistant remembers where you are, so you can close it in between."))
            Picker(tr("How will you judge the prints?"), selection: $model.data.mode) {
                ForEach(ValidationMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            note(model.data.mode == .scanner
                 ? tr("With a flatbed scanner and its ICC profile the prints are measured: the result is an estimate of the printed colours (not a spectrophotometer), good at telling the variants apart. You also need a physical ColorChecker to check the scanner.")
                 : tr("Without a scanner the corrected and original prints of the same pictures are compared by eye, side by side under neutral light, without knowing which is which."))
            if settings.profileBookmark == nil {
                Label(tr("Choose the printer ICC profile in Settings first."), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                Label(trf("Printer profile: %@", settings.profileDisplayName), systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
            Button(tr("Start a new session…")) { confirmingReset = true }
        }
    }

    // MARK: 2. Reference chart

    private var reference: some View {
        VStack(alignment: .leading, spacing: 12) {
            paragraph(tr("The physical ColorChecker is scanned once to measure the error of the scanner chain. Its reference values depend on the chart model and on when it was made: X-Rite changed the formulation in November 2014."))
            ForEach(ColourTargetModel.allCases) { targetModel in
                GroupBox(targetModel.title) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(ReferenceSet.builtIn.filter { $0.model == targetModel }) { set in
                            referenceRow(set)
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            GroupBox(tr("Your own values")) {
                VStack(alignment: .leading, spacing: 8) {
                    if let imported = model.data.importedReference { referenceRow(imported) }
                    note(tr("A CSV file with L, a, b columns (D50), or a CGATS / IT8 file with LAB or XYZ data, in the order of the patches: 24 for a Classic, 140 for an SG."))
                    Button(tr("Import values…")) { importReference() }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func referenceRow(_ set: ReferenceSet) -> some View {
        let selected = model.data.referenceID == set.id
        return Button {
            model.data.referenceID = set.id
            model.data.scannerCheck = nil
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(set.edition.capitalized(with: nil)).fontWeight(selected ? .semibold : .regular)
                        if set.id == ReferenceSet.defaultID { Text(tr("default")).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(set.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(trf("Source: %@", set.source)).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func importReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text, UTType(filenameExtension: "cgats") ?? .data,
                                     UTType(filenameExtension: "it8") ?? .data, UTType(filenameExtension: "txt") ?? .data]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { model.importReference(from: url) }
    }

    // MARK: 3. Files to print

    private var files: some View {
        VStack(alignment: .leading, spacing: 12) {
            paragraph(model.data.mode == .scanner
                      ? tr("The chart is printed five times: original and corrected, with the printer's Image Optimize off and on, and corrected with the other rendering intent. Four photographs of your own (optional) are printed as original and corrected.")
                      : tr("The chart is printed as original and corrected; your photographs as original and corrected, to be compared side by side."))
            GroupBox(tr("Photographs")) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(PhotoRole.allCases) { role in
                        HStack {
                            Text(role.title).frame(width: 190, alignment: .leading)
                            if let slot = model.data.photos.first(where: { $0.role == role }) {
                                Text(slot.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button(tr("Remove")) { model.setPhoto(nil, for: role) }
                            } else {
                                Text(tr("none")).foregroundStyle(.secondary)
                                Spacer()
                            }
                            Button(tr("Choose…")) { choosePhoto(role) }
                        }
                    }
                    note(tr("The black-and-white photograph settles how neutral greys print; skin tones, foliage and dark pictures show the typical problems."))
                }
                .padding(.vertical, 4)
            }
            HStack {
                Button(model.data.plan.isEmpty ? tr("Make the print order") : tr("Shuffle the print order again")) { model.makePlan() }
                Button(tr("Export the files to print…")) { exportPrintSet() }
                    .disabled(settings.profileBookmark == nil)
            }
            if !model.data.plan.isEmpty { printOrder }
            if let exported = model.data.exportedAt {
                note(trf("Exported on %@ to %@. Open the files with Preview to print them.",
                         exported.formatted(date: .abbreviated, time: .shortened), model.data.exportFolderName ?? ""))
            }
            note(tr("The files are named only by code (P01, P02, ...) in random order, so that you do not know which is which while printing and scanning. The key is written to a separate folder: open it only after scanning."))
        }
    }

    private var printOrder: some View {
        GroupBox(tr("Print order")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(model.data.plan) { item in
                    HStack(spacing: 6) {
                        Text(item.code).font(.body.monospacedDigit().bold())
                        Text(item.imageOptimizeOn ? tr("Image Optimize ON") : tr("Image Optimize off"))
                            .foregroundStyle(item.imageOptimizeOn ? Color.orange : Color.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func choosePhoto(_ role: PhotoRole) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .tiff, UTType(filenameExtension: "jxl") ?? .image]
        if panel.runModal() == .OK, let url = panel.url { model.setPhoto(url, for: role) }
    }

    private func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func exportPrintSet() {
        guard let folder = chooseFolder(prompt: tr("Export here")) else { return }
        Task { await model.exportPrintSet(to: folder) }
    }

    // MARK: 4. Print session

    private var printing: some View {
        VStack(alignment: .leading, spacing: 12) {
            paragraph(tr("Print every sheet in code order, from Preview (File > Print), with the same paper and ink pack, in the same room and away from sunlight."))
            GroupBox(tr("Checklist")) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(PrintChecklist.items, id: \.key) { item in
                        Toggle(item.text, isOn: Binding(
                            get: { model.data.checklist[item.key] ?? false },
                            set: { model.data.checklist[item.key] = $0 }))
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.data.plan.isEmpty { printOrder }
            GroupBox(tr("Session record")) {
                VStack(alignment: .leading, spacing: 6) {
                    note(tr("Write down what can change the result: it goes into the report."))
                    TextEditor(text: $model.data.record)
                        .font(.body.monospaced())
                        .frame(minHeight: 160)
                    if model.data.record.isEmpty {
                        Button(tr("Insert the record template")) { model.data.record = PrintChecklist.recordTemplate }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: 5. Scanner check

    private var scannerCheck: some View {
        VStack(alignment: .leading, spacing: 12) {
            paragraph(tr("Scan the ColorChecker with exactly the settings you will use for the prints: VueScan with every automatic correction off (levels, colour restoration, sharpening, dust), 16-bit TIFF, 600 dpi. Save the TIFF without applying your scanner profile, or with the profile embedded — never both."))
            GroupBox(tr("Scanner profile")) {
                HStack {
                    Text(model.data.scannerProfileName ?? tr("none: the profile embedded in the scans is used"))
                        .foregroundStyle(model.data.scannerProfileName == nil ? .secondary : .primary)
                    Spacer()
                    if model.data.scannerProfileName != nil { Button(tr("Remove")) { model.setScannerProfile(nil) } }
                    Button(tr("Choose…")) { chooseScannerProfile() }
                }
                .padding(.vertical, 4)
            }
            GroupBox(trf("ColorChecker scan (%@)", model.data.reference.title)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.data.colorCheckerScanName ?? tr("no scan chosen"))
                            .foregroundStyle(model.data.colorCheckerScanName == nil ? .secondary : .primary)
                        Spacer()
                        Button(tr("Choose…")) { chooseColorCheckerScan() }
                    }
                    if let thumbnail = colorCheckerThumbnail, let scan = colorCheckerScan {
                        let target = model.data.reference.model
                        note(model.data.corners.count < 4
                             ? trf("Click the centre of: %@. %@", target.cornerPatches[model.data.corners.count], target.orientationHint)
                             : tr("The grid shows where each patch is sampled. Check it, then measure."))
                        CornerPicker(image: thumbnail, scanSize: CGSize(width: scan.width, height: scan.height),
                                     corners: $model.data.corners, model: target)
                            .frame(height: 420)
                        HStack {
                            Button(tr("Clear the points")) { model.data.corners = []; model.data.scannerCheck = nil }
                                .disabled(model.data.corners.isEmpty)
                            Button(tr("Measure")) { Task { await model.runScannerCheck(scan: scan) } }
                                .disabled(model.data.corners.count < 4)
                                .keyboardShortcut(.return, modifiers: [.command])
                        }
                    }
                    if let check = model.data.scannerCheck { scannerCheckResult(check) }
                }
                .padding(.vertical, 4)
            }
        }
        .task(id: model.data.colorCheckerScanBookmark) {
            colorCheckerScan = await model.loadColorCheckerScan()
            colorCheckerThumbnail = colorCheckerScan?.thumbnail(maxDimension: 1400)
        }
    }

    @ViewBuilder
    private func scannerCheckResult(_ check: ScannerCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: "ΔE00 mean %.2f · median %.2f · 95th pct %.2f · max %.2f", check.summary.mean, check.summary.median,
                        check.summary.p95, check.summary.max))
                .font(.body.monospacedDigit())
            Text(trf("Profile used: %@. Reference: %@.", check.profileUsed, check.referenceTitle)).font(.caption).foregroundStyle(.secondary)
            if check.isTrustworthy {
                Label(trf("Normal for a flatbed: differences between prints smaller than about %.1f ΔE00 will not be interpreted.", check.resolution),
                      systemImage: "checkmark.circle").foregroundStyle(.green)
            } else {
                Label(tr("Too large for a flatbed: the scanner profile is probably applied twice or not at all, the chart edition may be wrong, or an automatic correction is on."),
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let other = check.alternativeProfile, let mean = check.alternativeMean {
                note(trf("With the %@ instead, the mean would be %.2f ΔE00.", other, mean)
                     + (mean + 2 < check.summary.mean ? " " + tr("That is much lower: the scan was probably already converted, so do not apply the scanner profile again.") : ""))
            }
            let worst = check.de00.enumerated().sorted { $0.element > $1.element }.prefix(3)
            Text(trf("Worst patches: %@", worst.map { "\(model.data.reference.patches[$0.offset].name) (\(String(format: "%.1f", $0.element)))" }.joined(separator: ", ")))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chooseScannerProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "icc") ?? .data, UTType(filenameExtension: "icm") ?? .data]
        if panel.runModal() == .OK, let url = panel.url { model.setScannerProfile(url) }
    }

    private func chooseColorCheckerScan() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.tiff]
        if panel.runModal() == .OK, let url = panel.url { model.setColorCheckerScan(url) }
    }

    // MARK: 6. Chart scans

    private var scans: some View {
        VStack(alignment: .leading, spacing: 12) {
            paragraph(tr("Scan every chart print at least 24 hours after printing, flat under the lid, glossy side down, always the same way, with the same settings as the ColorChecker. The whole print with its four corner marks must be in the scan; the orientation does not matter. Name the files by code (P05.tif)."))
            let charts = model.data.plan.filter { $0.chartVariant != nil }
            if charts.isEmpty {
                note(tr("Make the print order first (step Files to print)."))
            } else {
                GroupBox(tr("Chart prints")) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(charts) { item in
                            HStack {
                                Text(item.code).font(.body.monospacedDigit().bold()).frame(width: 44, alignment: .leading)
                                if let entry = model.data.scans[item.code] {
                                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if let result = entry.result {
                                        Text(String(format: "ΔE00 %.2f", result.summary.all.mean)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                    } else if let error = entry.error {
                                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(2)
                                    }
                                } else {
                                    Text(tr("no scan")).foregroundStyle(.secondary)
                                    Spacer()
                                }
                                Button(tr("Choose…")) { chooseScan(item.code) }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                HStack {
                    Button(tr("Take them from a folder…")) {
                        if let folder = chooseFolder(prompt: tr("Use this folder")) {
                            model.message = trf("%d scans found by their code.", model.matchScans(in: folder))
                        }
                    }
                    Button(tr("Analyse")) { Task { await model.analyseScans() } }
                        .disabled(!charts.contains { model.data.scans[$0.code] != nil })
                        .keyboardShortcut(.return, modifiers: [.command])
                }
                if model.data.scannerCheck == nil {
                    note(tr("Without the scanner check the measured values carry an unknown error; the comparison between variants still holds."))
                }
            }
        }
    }

    private func chooseScan(_ code: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.tiff]
        panel.message = trf("Scan of the print %@", code)
        if panel.runModal() == .OK, let url = panel.url { model.setScan(url, code: code) }
    }

    // MARK: 7. Photographs

    private var visual: some View {
        VStack(alignment: .leading, spacing: 12) {
            paragraph(tr("Put the two prints of the same photograph side by side under neutral light (daylight from a window, not direct sun) and compare them with the photo on the screen — ideally in the full-screen view on the neutral grey. Which one is closer?"))
            let roles = PhotoRole.allCases.filter { role in model.data.plan.contains { if case .photo(role, _) = $0.content { return true } else { return false } } }
            if roles.isEmpty {
                note(tr("No photographs in the print order."))
            }
            ForEach(roles) { role in
                visualRow(role)
            }
        }
    }

    private func codes(for role: PhotoRole) -> (original: String, corrected: String)? {
        var original: String?, corrected: String?
        for item in model.data.plan {
            if case .photo(role, let isCorrected) = item.content {
                if isCorrected { corrected = item.code } else { original = item.code }
            }
        }
        guard let original, let corrected else { return nil }
        return (original, corrected)
    }

    @ViewBuilder
    private func visualRow(_ role: PhotoRole) -> some View {
        if let index = model.data.visual.firstIndex(where: { $0.photoRole == role.rawValue }), let pair = codes(for: role) {
            // Shown by code, in code order: the choice is made blind and decoded with the plan.
            let shown = [pair.original, pair.corrected].sorted()
            GroupBox(role.title) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(tr("Closer to the screen"), selection: Binding<String>(
                        get: {
                            switch model.data.visual[index].choice {
                            case .corrected: pair.corrected
                            case .original: pair.original
                            case .same: "same"
                            case .notJudged: ""
                            }
                        },
                        set: { value in
                            model.data.visual[index].choice = value == pair.corrected ? .corrected
                                : (value == pair.original ? .original : (value == "same" ? .same : .notJudged))
                        })) {
                        Text(tr("Not judged yet")).tag("")
                        ForEach(shown, id: \.self) { code in Text(trf("Print %@", code)).tag(code) }
                        Text(tr("No visible difference")).tag("same")
                    }
                    .pickerStyle(.radioGroup)
                    TextField(tr("Notes: skin tones, shadows, colour cast…"), text: $model.data.visual[index].notes, axis: .vertical)
                        .lineLimit(2...4)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 8. Report

    private var reportView: some View {
        VStack(alignment: .leading, spacing: 12) {
            let results = model.data.chartResults
            if !results.isEmpty {
                GroupBox(tr("Chart prints (ΔE00, paper-relative)")) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        GridRow {
                            Text(tr("Variant")).bold()
                            Text(tr("Mean")).bold()
                            Text(tr("Median")).bold()
                            Text(tr("95th pct")).bold()
                            Text(tr("Neutral C* p95")).bold()
                            Text(tr("Dark steps")).bold()
                            Text(tr("Model")).bold().help(tr("What the printer profile's own model predicts for the same chart."))
                        }
                        ForEach(ChartVariant.allCases.filter { results[$0] != nil }) { variant in
                            let s = results[variant]!.summary
                            GridRow {
                                Text(variant.title).lineLimit(1)
                                Text(ValidationReport.format(s.all.mean))
                                Text(ValidationReport.format(s.all.median))
                                Text(ValidationReport.format(s.all.p95))
                                Text(ValidationReport.format(s.neutralChromaP95))
                                Text("\(s.darkStepsDistinguishable)/\(s.darkStepsTotal)")
                                Text(ValidationReport.format(model.models[variant]?.all.mean)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.callout.monospacedDigit())
                    .padding(.vertical, 4)
                }
                GroupBox(tr("Gates (declared before printing)")) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ValidationReport.gates(results), id: \.name) { gate in
                            HStack(alignment: .top) {
                                Image(systemName: gate.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(gate.passed ? Color.green : Color.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(gate.name)
                                    Text(gate.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if model.data.mode == .scanner {
                note(tr("No chart scan analysed yet."))
            }
            GroupBox(tr("REPORT.md")) {
                ScrollView {
                    Text(model.report)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 220, maxHeight: 360)
            }
            HStack {
                Button(tr("Export the report…")) {
                    if let folder = chooseFolder(prompt: tr("Export here")) { Task { await model.exportReport(to: folder) } }
                }
                Button(tr("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.report, forType: .string)
                }
            }
            note(tr("The export also writes the per-variant results in the format of the project's Python tools (validation/report.py can merge them), the scanner check and the key of the print order. Do not share scans or personal photographs."))
        }
        .task(id: model.data) { await model.updateReport() }
    }
}

/// The printing checklist (Documentation/PHYSICAL_VALIDATION.md, Print session).
enum PrintChecklist {
    struct Item {
        let key: String
        let text: String
    }

    static var items: [Item] {
        [
            Item(key: "autoPowerOff", text: tr("On the printer: Setup > Auto power off set to Off (Image Optimize resets when the printer switches off).")),
            Item(key: "imageOptimize", text: tr("Before every sheet: Setup > Print settings > Image Optimize as the print order says (off, ON only where marked).")),
            Item(key: "postcard", text: tr("In the print dialog: paper size Postcard (100 x 148 mm), the same scaling and borderless choice for every sheet.")),
            Item(key: "pack", text: tr("One paper and ink pack for all the sheets.")),
            Item(key: "codes", text: tr("The code written on the back of every print, nothing else.")),
            Item(key: "rest", text: tr("The prints left to rest for at least 24 hours before scanning.")),
        ]
    }

    static var recordTemplate: String {
        [tr("Date:"), tr("Room temperature:"), tr("Paper and ink pack:"), tr("Printer firmware:"), tr("macOS version:"),
         tr("Print dialog options:"), tr("Notes (jams, colour casts, banding):")].joined(separator: "\n")
    }
}

/// Shows the ColorChecker scan; clicks place the four corner patches (in scan pixels) and the
/// grid of sampled patch centres is drawn on top.
struct CornerPicker: View {
    let image: CGImage
    let scanSize: CGSize
    @Binding var corners: [[Double]]
    let model: ColourTargetModel

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / scanSize.width, geometry.size.height / scanSize.height)
            let shown = CGSize(width: scanSize.width * scale, height: scanSize.height * scale)
            let origin = CGPoint(x: (geometry.size.width - shown.width) / 2, y: (geometry.size.height - shown.height) / 2)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: shown.width, height: shown.height)
                    .offset(x: origin.x, y: origin.y)
                Canvas { context, _ in
                    func view(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
                    if corners.count == 4 {
                        let centres = ScannerCheck.patchCentres(corners: corners.map { CGPoint(x: $0[0], y: $0[1]) },
                                                                columns: model.columns, rows: model.rows)
                        for c in centres {
                            let p = view(c)
                            context.stroke(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.white), lineWidth: 2)
                            context.stroke(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.black), lineWidth: 1)
                        }
                    }
                    for (index, corner) in corners.enumerated() {
                        let p = view(CGPoint(x: corner[0], y: corner[1]))
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.red))
                        context.draw(Text("\(index + 1)").font(.caption.bold()).foregroundColor(.white), at: CGPoint(x: p.x + 12, y: p.y - 10))
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                guard corners.count < 4 else { return }
                let x = (location.x - origin.x) / scale, y = (location.y - origin.y) / scale
                guard x >= 0, y >= 0, x < scanSize.width, y < scanSize.height else { return }
                corners.append([Double(x), Double(y)])
            }
        }
        .background(Color.black.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
