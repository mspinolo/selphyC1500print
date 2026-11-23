import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedPhotos: [URL] = []
    @State private var showingPhotoPicker = false
    @State private var showingProfilePicker = false
    @State private var profileReport: ICCProfileReport?
    @State private var profileError: String?
    @State private var generatedCopies: [URL] = []
    @State private var generatedFolder: URL?
    @State private var isPreparing = false
    @State private var statusMessage = "Seleziona un profilo ICC e una o più fotografie JPEG."

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
                    Toggle("Compensazione del punto nero (BPC)", isOn: $settings.blackPointCompensation)
                    Text("La conversione usa ColorSync. In questa fase è una pre-correzione sperimentale: il JPEG risultante viene etichettato sRGB per il successivo trattamento interno della SELPHY.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Fotografie originali") {
                HStack {
                    Text(selectedPhotos.isEmpty ? "Nessuna fotografia selezionata" : "\(selectedPhotos.count) fotografie selezionate")
                    Spacer()
                    Button("Aggiungi JPEG…") { showingPhotoPicker = true }
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
                Text("Gli originali vengono soltanto letti. La conversione crea nuovi JPEG temporanei.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !generatedCopies.isEmpty {
                GroupBox("Copie di prova generate") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(generatedCopies, id: \.path) { url in
                            Label(url.lastPathComponent, systemImage: "doc.richtext")
                                .lineLimit(1)
                        }
                        HStack {
                            Text("Temporanei: rimossi al prossimo utilizzo se più vecchi di 24 ore.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Mostra nel Finder") {
                                if let generatedFolder {
                                    NSWorkspace.shared.open(generatedFolder)
                                }
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
                Button {
                    prepareCopies()
                } label: {
                    if isPreparing {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 8)
                    } else {
                        Text("Genera copie di prova")
                    }
                }
                .disabled(isPreparing || selectedPhotos.isEmpty || settings.profileBookmark == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .fileImporter(
            isPresented: $showingPhotoPicker,
            allowedContentTypes: [.jpeg],
            allowsMultipleSelection: true,
            onCompletion: handlePhotoSelection
        )
        .fileImporter(
            isPresented: $showingProfilePicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false,
            onCompletion: handleProfileSelection
        )
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
            isPreparing = true
            statusMessage = "Conversione ColorSync in corso…"

            Task {
                let hasProfileAccess = profileURL.startAccessingSecurityScopedResource()
                defer {
                    if hasProfileAccess {
                        profileURL.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try ColorCorrectionService.prepareCopies(
                            from: photoURLs,
                            printerProfileURL: profileURL,
                            intent: intent,
                            blackPointCompensation: bpc
                        )
                    }.value

                    generatedCopies = result.files
                    generatedFolder = result.folder
                    statusMessage = "Generate \(result.files.count) copie temporanee. Non sono state inviate alla stampante."
                } catch {
                    statusMessage = "Conversione non riuscita: \(error.localizedDescription)"
                }
                isPreparing = false
            }
        } catch {
            statusMessage = "Impossibile accedere al profilo ICC: \(error.localizedDescription)"
        }
    }
}
