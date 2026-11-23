import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedPhotos: [URL] = []
    @State private var showingPhotoPicker = false
    @State private var showingProfilePicker = false
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
                        Button("Rimuovi", role: .destructive) { settings.clearProfile() }
                    }
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
                    statusMessage = "Stampa non ancora abilitata: prima va verificata la trasformazione ICC e il comportamento del driver Canon."
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
            do {
                try settings.chooseProfile(at: url)
                statusMessage = "Profilo selezionato. La conversione ICC sarà abilitata dopo la verifica tecnica."
            } catch {
                statusMessage = "Impossibile memorizzare il profilo: \(error.localizedDescription)"
            }
        case .failure(let error):
            statusMessage = "Selezione profilo non riuscita: \(error.localizedDescription)"
        }
    }

    private func loadPrinters() {
        // Printer discovery will be implemented through the macOS printing APIs.
        statusMessage = "Rilevamento stampanti non ancora implementato; puoi inserire il nome esatto della coda macOS."
    }
}
