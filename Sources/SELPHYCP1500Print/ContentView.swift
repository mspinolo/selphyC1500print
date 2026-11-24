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
    /// nil = the initial hint, so that it follows the selected language.
    @State private var statusOverride: String?

    private var statusMessage: String {
        get { statusOverride ?? tr("Select an ICC profile and one or more photos (JPEG, JPEG XL, PNG, TIFF).") }
        nonmutating set { statusOverride = newValue }
    }

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
                    Text(tr("Colour preparation and pre-correction"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker(tr("Language"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                .frame(width: 190)
                Image(systemName: "printer")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
            }

            GroupBox(tr("Farbenwerk ICC profile")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(settings.profileDisplayName.isEmpty ? tr("No profile selected") : settings.profileDisplayName)
                                .lineLimit(1)
                            Text(tr("The path is remembered securely between launches."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(tr("Choose profile…")) { showingProfilePicker = true }
                        if !settings.profileDisplayName.isEmpty {
                            Button(tr("Remove"), role: .destructive) {
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

            GroupBox(tr("Colour management")) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(tr("Rendering intent"), selection: $settings.renderingIntent) {
                        ForEach(RenderingIntent.allCases) { intent in
                            Text(intent.title).tag(intent)
                        }
                    }
                    Picker(tr("Output file format"), selection: $settings.outputFormat) {
                        ForEach(OutputFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    Text(settings.outputFormat.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(
                        tr("Black point compensation (BPC)"),
                        isOn: blackPointCompensationForced ? .constant(true) : $settings.blackPointCompensation
                    )
                    .disabled(blackPointCompensationForced)
                    if blackPointCompensationForced {
                        Text(tr("With an ICC v4 profile, black point compensation is always applied for the Perceptual and Saturation intents (ICC rule); the option only matters for Relative colorimetric."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(tr("Conversion uses the built-in colour engine (LittleCMS). At this stage it is an experimental pre-correction: the resulting image is tagged sRGB for the SELPHY's own subsequent processing."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            GroupBox(tr("Original photos")) {
                HStack {
                    Text(selectedPhotos.isEmpty ? tr("No photos selected") : trn(selectedPhotos.count, one: "1 photo selected", other: "%d photos selected"))
                    Spacer()
                    Button(tr("Add images…")) { showingPhotoPicker = true }
                    Button(tr("Clear"), role: .destructive) {
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
                Text(tr("Originals are only read. Conversion creates new temporary images."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PreviewPanel(photos: selectedPhotos)

            if !generatedCopies.isEmpty {
                GroupBox(tr("Generated test copies")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(generatedCopies, id: \.path) { url in
                            Label(url.lastPathComponent, systemImage: "doc.richtext")
                                .lineLimit(1)
                        }
                        if !generatedSummary.isEmpty {
                            Text(trf("Generated with: %@", generatedSummary))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(tr("These copies are temporary and are removed after 24 hours. To keep them, save them to a folder: existing files are never overwritten or deleted."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(tr("Show in Finder")) {
                                if let generatedFolder {
                                    NSWorkspace.shared.open(generatedFolder)
                                }
                            }
                            if settings.saveFolderBookmark != nil {
                                Button(tr("Save to another folder…")) { showingSaveFolderPicker = true }
                                Button(trf("Save to %@", settings.saveFolderDisplayName)) { saveToRememberedFolder() }
                                    .buttonStyle(.borderedProminent)
                            } else {
                                Button(tr("Save to a folder…")) { showingSaveFolderPicker = true }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        if settings.saveFolderBookmark != nil {
                            HStack {
                                Text(trf("Remembered save folder: %@", settings.saveFolderDisplayName))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button(tr("Forget")) { settings.clearSaveFolder() }
                                    .buttonStyle(.link)
                                    .font(.caption)
                            }
                        }
                        if let savedFolder {
                            HStack {
                                Label(trf("Saved to %@", savedFolder.lastPathComponent), systemImage: "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                Button(tr("Open folder")) { NSWorkspace.shared.open(savedFolder) }
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
                    Text(tr("Direct printing is not enabled yet."))
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
                        Button(tr("Cancel")) { conversionWork?.cancel() }
                            .keyboardShortcut(.cancelAction)
                    }
                } else {
                    Button(tr("Generate test copies")) { prepareCopies() }
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
            statusMessage = trf("Folder selection failed: %@", error.localizedDescription)
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
            statusMessage = tr("The save folder is no longer reachable: choose it again.")
            showingSaveFolderPicker = true
        }
    }

    private func save(to folder: URL) {
        do {
            let saved = try ExportService.save(copies: generatedCopies, to: folder)
            savedFolder = folder
            statusMessage = trn(saved.count, one: "Saved 1 copy to %@. Originals and existing files were not modified.", other: "Saved %d copies to %@. Originals and existing files were not modified.", folder.lastPathComponent)
        } catch {
            statusMessage = trf("Saving failed: %@", error.localizedDescription)
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
            profileError = trf("The remembered profile can no longer be read: %@", error.localizedDescription)
        }
    }

    private func handlePhotoSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            selectedPhotos.append(contentsOf: urls.filter { !selectedPhotos.contains($0) })
            statusMessage = trn(selectedPhotos.count, one: "1 photo queued.", other: "%d photos queued.")
            generatedCopies.removeAll()
            generatedFolder = nil
        case .failure(let error):
            statusMessage = trf("Photo selection failed: %@", error.localizedDescription)
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
                    ? tr("ICC profile loaded and structure verified.")
                    : tr("Profile loaded; check the class and colour spaces.")
            } catch {
                profileReport = nil
                profileError = error.localizedDescription
                statusMessage = trf("Unable to verify the profile: %@", error.localizedDescription)
            }
        case .failure(let error):
            statusMessage = trf("Profile selection failed: %@", error.localizedDescription)
        }
    }

    private func prepareCopies() {
        do {
            guard let profileURL = try settings.resolveProfileURL() else {
                statusMessage = tr("First select the Farbenwerk ICC profile.")
                return
            }

            let photoURLs = selectedPhotos
            let intent = settings.renderingIntent
            let bpc = settings.blackPointCompensation
            let format = settings.outputFormat
            isPreparing = true
            statusMessage = tr("Colour conversion in progress…")

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
                    generatedSummary = trf("%@ · BPC %@ · %@", intent.title, result.effectiveBlackPointCompensation ? tr("yes") : tr("no"), format.title)
                    var message = trn(result.files.count, one: "Generated 1 temporary copy. It was not sent to the printer.", other: "Generated %d temporary copies. They were not sent to the printer.")
                    if !result.assumedSRGBSources.isEmpty {
                        message += trf(" No embedded profile (assumed sRGB): %@.", result.assumedSRGBSources.map(\.lastPathComponent).joined(separator: ", "))
                    }
                    if !result.convertedSources.isEmpty {
                        message += trf(" Converted to sRGB first (grey/CMYK/Lab): %@.", result.convertedSources.map(\.lastPathComponent).joined(separator: ", "))
                    }
                    statusMessage = message
                } catch ColorCorrectionService.CorrectionError.cancelled {
                    statusMessage = tr("Conversion cancelled. No files were created.")
                } catch {
                    statusMessage = trf("Conversion failed: %@", error.localizedDescription)
                }
                conversionWork = nil
                isPreparing = false
            }
        } catch {
            statusMessage = trf("Unable to access the ICC profile: %@", error.localizedDescription)
        }
    }
}
