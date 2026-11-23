import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedPhotos: [URL] = []
    @State private var showingPhotoPicker = false
    @State private var showingProfilePicker = false
    @State private var profileReport: ICCProfileReport?
    @State private var profileError: String?
    @State private var statusMessage = "Seleziona un profilo ICC e una o più fotografie JPEG."

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SELPHY CP1500 Print")
                        .font(.largeTitle.weight(.semibold))
                    Text("Preparazione e stampa con gestione colore")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "printer")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
            }

            GroupBox("Profilo ICC") {
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
                        Text("ICC \(report.version) · \(report.profileClass) · \(report.colorSpace) → \(report.connectionSpace) · \(report.fileSize.formatted()) byte")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text("Intenti con tabelle A2B/B2A: \(report.availableIntents.map(\.title).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let profileError {
                        Label(profileError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Gestione colore") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Intento di rendering", selection: $settings.renderingIntent) {
                        ForEach(RenderingIntent.allCases) { intent in
                            Text(intent.title).tag(intent)
                        }
                    }
                    if let selected = profileReport?.availableIntents.first(where: { $0 == settings.renderingIntent }) {
                        Text(selected.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("L'intento verrà verificato rispetto alle tabelle effettivamente presenti nel profilo.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Compensazione del punto nero (BPC)", isOn: $settings.blackPointCompensation)
                    Text("La BPC resta disattivata inizialmente: verrà applicata solo dopo aver verificato il comportamento del motore ColorSync con questo profilo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Stampante") {
                HStack {
                    TextField("Nome stampante macOS (es. Canon SELPHY CP1500)", text: $settings.selectedPrinterName)
                        .textFieldStyle(.roundedBorder)
                    Button("Rileva") { loadPrinters() }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Fotografie") {
                HStack {
                    Text(selectedPhotos.isEmpty ? "Nessuna fotografia selezionata" : "\(selectedPhotos.count) fotografie selezionate")
                    Spacer()
                    Button("Aggiungi JPEG…") { showingPhotoPicker = true }
                    Button("Svuota", role: .destructive) { selectedPhotos.removeAll() }
                        .disabled(selectedPhotos.isEmpty)
                }
                if !selectedPhotos.isEmpty {
                    List(selectedPhotos, id: \.path) { url in
                        Label(url.lastPathComponent, systemImage: "photo")
                            .lineLimit(1)
                    }
                    .frame(minHeight: 120, maxHeight: 190)
                }
                Text("Gli originali non verranno mai modificati. Le copie di stampa saranno temporanee.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            HStack {
                Image(systemName: "info.circle")
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stampa") {
                    statusMessage = "Stampa non ancora abilitata: prima va validata la pipeline ICC e verificata l'assenza di una seconda conversione colore nel driver."
                }
                .disabled(selectedPhotos.isEmpty || settings.profileBookmark == nil || settings.selectedPrinterName.isEmpty)
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
                    : "Profilo caricato; verifica la classe e gli spazi colore prima della conversione."
            } catch {
                profileReport = nil
                profileError = error.localizedDescription
                statusMessage = "Impossibile verificare il profilo: \(error.localizedDescription)"
            }
        case .failure(let error):
            statusMessage = "Selezione profilo non riuscita: \(error.localizedDescription)"
        }
    }

    private func loadPrinters() {
        statusMessage = "Rilevamento stampanti non ancora implementato; puoi inserire il nome esatto della coda macOS."
    }
}
