import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Progress of a conversion batch, updated from a background thread through the main queue.
@MainActor
final class ConversionProgress: ObservableObject {
    @Published var completed = 0
    @Published var total = 0

    nonisolated func update(completed: Int, total: Int) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.completed = completed
                self?.total = total
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedPhotos: [URL] = []
    @State private var showingPhotoPicker = false
    @State private var showingProfilePicker = false
    @State private var profileReport: ICCProfileReport?
    @State private var profileError: String?
    @State private var generatedCopies: [URL] = []
    @State private var generatedFolder: URL?
    @State private var generatedSummary = ""
    @State private var showingSaveFolderPicker = false
    @State private var savedFolder: URL?
    @State private var isPreparing = false
    @StateObject private var progress = ConversionProgress()
    @State private var conversionWork: Task<ColorCorrectionService.Result, Error>?
    @State private var statusMessage = "Seleziona un profilo ICC e una o più fotografie (JPEG, JPEG XL, PNG, TIFF)."

    /// BPC is mandatory for perceptual/saturation with an ICC v4 printer profile. The
    /// version is known once a profile has been inspected; the Farbenwerk profile is v4.
    private var blackPointCompensationForced: Bool {
        let major = profileReport.flatMap { Int($0.version.prefix(1)) } ?? 4
        return settings.renderingIntent != .relativeColorimetric && major >= 4
    }

    /// JPEG XL needs a recent ImageIO (macOS 14+); it is skipped if the type is unknown.
    private static let supportedImageTypes: [UTType] =
        [.jpeg, .png, .tiff] + [UTType("public.jpeg-xl")].compactMap { $0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SELPHY CP1500 Print")
                        .font(.largeTitle.weight(.semibold))
                    Text("Preparazione e pre-correzione colore")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "printer")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
            }

            GroupBox("Profilo ICC Farbenwerk") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(settings.profileDisplayName.isEmpty ? "Nessun profilo selezionato" : settings.profileDisplayName)
                                .lineLimit(1)
                            Text("Il percorso viene ricordato in modo sicuro tra gli avvii.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Scegli profilo…") { showingProfilePicker = true }
                        if !settings.profileDisplayName.isEmpty {
                            Button("Rimuovi", role: .destructive) {
                                settings.clearProfile()
                                profileReport = nil
                                profileError = nil
                            }
                        }
                    }
                    if let report = profileReport {
                        Divider()
                        Label(report.summary, systemImage: report.isExpectedPrinterProfile ? "checkmark.seal" : "exclamationmark.triangle")
                            .foregroundStyle(report.isExpectedPrinterProfile ? .green : .orange)
                        Text("ICC \(report.version) · \(report.profileClass) · \(report.colorSpace) → \(report.connectionSpace)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else if let profileError {
                        Label(profileError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Gestione colore") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Intento di rendering", selection: $settings.renderingIntent) {
                        ForEach(RenderingIntent.allCases) { intent in
                            Text(intent.title).tag(intent)
                        }
                    }
                    Picker("Formato dei file generati", selection: $settings.outputFormat) {
                        ForEach(OutputFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    Text(settings.outputFormat.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(
                        "Compensazione del punto nero (BPC)",
                        isOn: blackPointCompensationForced ? .constant(true) : $settings.blackPointCompensation
                    )
                    .disabled(blackPointCompensationForced)
                    if blackPointCompensationForced {
                        Text("Con un profilo ICC v4 la compensazione del punto nero è sempre applicata negli intenti Percettivo e Saturazione (regola ICC); l'opzione vale solo per il Colorimetrico relativo.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("La conversione usa il motore colore integrato (LittleCMS). In questa fase è una pre-correzione sperimentale: l'immagine risultante viene etichettata sRGB per il successivo trattamento interno della SELPHY.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Fotografie originali") {
                HStack {
                    Text(selectedPhotos.isEmpty ? "Nessuna fotografia selezionata" : "\(selectedPhotos.count) fotografie selezionate")
                    Spacer()
                    Button("Aggiungi immagini…") { showingPhotoPicker = true }
                    Button("Svuota", role: .destructive) {
                        selectedPhotos.removeAll()
                        generatedCopies.removeAll()
                        generatedFolder = nil
                    }
                    .disabled(selectedPhotos.isEmpty)
                }
                if !selectedPhotos.isEmpty {
                    List(selectedPhotos, id: \.path) { url in
                        Label(url.lastPathComponent, systemImage: "photo")
                            .lineLimit(1)
                    }
                    .frame(minHeight: 90, maxHeight: 150)
                }
                Text("Gli originali vengono soltanto letti. La conversione crea nuove immagini temporanee.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PreviewPanel(photos: selectedPhotos)

            if !generatedCopies.isEmpty {
                GroupBox("Copie di prova generate") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(generatedCopies, id: \.path) { url in
                            Label(url.lastPathComponent, systemImage: "doc.richtext")
                                .lineLimit(1)
                        }
                        if !generatedSummary.isEmpty {
                            Text("Generate con: \(generatedSummary)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Queste copie sono temporanee e vengono rimosse dopo 24 ore. Per conservarle, salvale in una cartella: i file esistenti non vengono mai sovrascritti né cancellati.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Mostra nel Finder") {
                                if let generatedFolder {
                                    NSWorkspace.shared.open(generatedFolder)
                                }
                            }
                            if settings.saveFolderBookmark != nil {
                                Button("Salva in un'altra cartella…") { showingSaveFolderPicker = true }
                                Button("Salva in \(settings.saveFolderDisplayName)") { saveToRememberedFolder() }
                                    .buttonStyle(.borderedProminent)
                            } else {
                                Button("Salva in una cartella…") { showingSaveFolderPicker = true }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        if settings.saveFolderBookmark != nil {
                            HStack {
                                Text("Cartella di salvataggio ricordata: \(settings.saveFolderDisplayName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Dimentica") { settings.clearSaveFolder() }
                                    .buttonStyle(.link)
                                    .font(.caption)
                            }
                        }
                        if let savedFolder {
                            HStack {
                                Label("Salvate in \(savedFolder.lastPathComponent)", systemImage: "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                Button("Apri la cartella") { NSWorkspace.shared.open(savedFolder) }
                                    .buttonStyle(.link)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("La stampa diretta non è ancora abilitata.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isPreparing {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                            .frame(width: 120)
                        Text("\(progress.completed)/\(progress.total)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button("Annulla") { conversionWork?.cancel() }
                            .keyboardShortcut(.cancelAction)
                    }
                } else {
                    Button("Genera copie di prova") { prepareCopies() }
                        .disabled(selectedPhotos.isEmpty || settings.profileBookmark == nil)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .onAppear { restoreProfileReport() }
        .fileImporter(
            isPresented: $showingPhotoPicker,
            allowedContentTypes: Self.supportedImageTypes,
            allowsMultipleSelection: true,
            onCompletion: handlePhotoSelection
        )
        .fileImporter(
            isPresented: $showingSaveFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleSaveFolderSelection
        )
        .fileImporter(
            isPresented: $showingProfilePicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false,
            onCompletion: handleProfileSelection
        )
    }

    private func handleSaveFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let folder = urls.first else { return }
            save(to: folder)
            // Remember the folder only once it has been used successfully.
            if savedFolder == folder { try? settings.chooseSaveFolder(at: folder) }
        case .failure(let error):
            statusMessage = "Selezione cartella non riuscita: \(error.localizedDescription)"
        }
    }

    private func saveToRememberedFolder() {
        do {
            guard let folder = try settings.resolveSaveFolderURL() else {
                showingSaveFolderPicker = true
                return
            }
            save(to: folder)
        } catch {
            // The folder was moved or deleted: ask again.
            settings.clearSaveFolder()
            statusMessage = "La cartella di salvataggio non è più raggiungibile: sceglila di nuovo."
            showingSaveFolderPicker = true
        }
    }

    private func save(to folder: URL) {
        do {
            let saved = try ExportService.save(copies: generatedCopies, to: folder)
            savedFolder = folder
            statusMessage = "Salvate \(saved.count) copie in \(folder.lastPathComponent). Gli originali e i file già presenti non sono stati modificati."
        } catch {
            statusMessage = "Salvataggio non riuscito: \(error.localizedDescription)"
        }
    }

    /// Shows again the report of the remembered profile after a restart.
    private func restoreProfileReport() {
        guard profileReport == nil, profileError == nil, settings.profileBookmark != nil else { return }
        do {
            guard let url = try settings.resolveProfileURL() else { return }
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            profileReport = try ICCProfileInspector.inspect(url: url)
        } catch {
            profileError = "Il profilo ricordato non è più leggibile: \(error.localizedDescription)"
        }
    }

    private func handlePhotoSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            selectedPhotos.append(contentsOf: urls.filter { !selectedPhotos.contains($0) })
            statusMessage = "\(selectedPhotos.count) fotografie in coda."
            generatedCopies.removeAll()
            generatedFolder = nil
        case .failure(let error):
            statusMessage = "Selezione fotografie non riuscita: \(error.localizedDescription)"
        }
    }

    private func handleProfileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            do {
                let report = try ICCProfileInspector.inspect(url: url)
                try settings.chooseProfile(at: url)
                profileReport = report
                profileError = nil
                statusMessage = report.isExpectedPrinterProfile
                    ? "Profilo ICC caricato e struttura verificata."
                    : "Profilo caricato; controllare la classe e gli spazi colore."
            } catch {
                profileReport = nil
                profileError = error.localizedDescription
                statusMessage = "Impossibile verificare il profilo: \(error.localizedDescription)"
            }
        case .failure(let error):
            statusMessage = "Selezione profilo non riuscita: \(error.localizedDescription)"
        }
    }

    private func prepareCopies() {
        do {
            guard let profileURL = try settings.resolveProfileURL() else {
                statusMessage = "Seleziona prima il profilo ICC Farbenwerk."
                return
            }

            let photoURLs = selectedPhotos
            let intent = settings.renderingIntent
            let bpc = settings.blackPointCompensation
            let format = settings.outputFormat
            isPreparing = true
            statusMessage = "Conversione colore in corso…"

            progress.update(completed: 0, total: photoURLs.count)
            let batchProgress = progress
            // A detached task is not cancelled with its parent: the handle is kept so that the
            // Annulla button can cancel the conversion itself.
            let work = Task.detached(priority: .userInitiated) {
                try ColorCorrectionService.prepareCopies(
                    from: photoURLs,
                    printerProfileURL: profileURL,
                    intent: intent,
                    blackPointCompensation: bpc,
                    outputFormat: format,
                    progress: { done, total in batchProgress.update(completed: done, total: total) },
                    shouldCancel: { Task.isCancelled }
                )
            }
            conversionWork = work

            Task {
                let hasProfileAccess = profileURL.startAccessingSecurityScopedResource()
                defer {
                    if hasProfileAccess {
                        profileURL.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    let result = try await work.value

                    generatedCopies = result.files
                    generatedFolder = result.folder
                    savedFolder = nil
                    generatedSummary = "\(intent.title) · BPC \(result.effectiveBlackPointCompensation ? "sì" : "no") · \(format.title)"
                    var message = "Generate \(result.files.count) copie temporanee. Non sono state inviate alla stampante."
                    if !result.assumedSRGBSources.isEmpty {
                        message += " Senza profilo incorporato (assunto sRGB): \(result.assumedSRGBSources.map(\.lastPathComponent).joined(separator: ", "))."
                    }
                    if !result.convertedSources.isEmpty {
                        message += " Convertite prima in sRGB (grigi/CMYK/Lab): \(result.convertedSources.map(\.lastPathComponent).joined(separator: ", "))."
                    }
                    statusMessage = message
                } catch ColorCorrectionService.CorrectionError.cancelled {
                    statusMessage = "Conversione annullata. Nessun file è stato creato."
                } catch {
                    statusMessage = "Conversione non riuscita: \(error.localizedDescription)"
                }
                conversionWork = nil
                isPreparing = false
            }
        } catch {
            statusMessage = "Impossibile accedere al profilo ICC: \(error.localizedDescription)"
        }
    }
}
