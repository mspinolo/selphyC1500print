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
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @State private var selectedPhotos: [URL]
    @State private var previewPhoto: URL?
    @State private var showingPhotoPicker = false
    @State private var generatedCopies: [URL] = []
    @StateObject private var printService = PrintService()
    @State private var isPrinting = false
    @State private var generatedFolder: URL?
    @State private var generatedSummary = ""
    @State private var showingSaveFolderPicker = false
    @State private var savedFolder: URL?
    @State private var isPreparing = false
    @StateObject private var progress = ConversionProgress()
    @State private var conversionWork: Task<ColorCorrectionService.Result, Error>?
    /// nil = the initial hint, so that it follows the selected language.
    @State private var statusOverride: String?

    /// `initialPhotos` is only used to present the window with photos already loaded (snapshots).
    init(initialPhotos: [URL] = []) {
        _selectedPhotos = State(initialValue: initialPhotos)
        _previewPhoto = State(initialValue: initialPhotos.first)
    }

    private var statusMessage: String {
        get { statusOverride ?? tr("Select an ICC profile and one or more photos (JPEG, JPEG XL, PNG, TIFF).") }
        nonmutating set { statusOverride = newValue }
    }

    /// The photo shown in the preview: the chosen one, or the first when the choice is gone.
    private var currentPhoto: URL? {
        if let previewPhoto, selectedPhotos.contains(previewPhoto) { return previewPhoto }
        return selectedPhotos.first
    }

    /// JPEG XL needs a recent ImageIO (macOS 14+); it is skipped if the type is unknown.
    private static let supportedImageTypes: [UTType] =
        [.jpeg, .png, .tiff] + [UTType("public.jpeg-xl")].compactMap { $0 }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                PhotoSidebar(
                    photos: selectedPhotos,
                    selection: currentPhoto,
                    select: { previewPhoto = $0 },
                    remove: removePhoto,
                    clear: clearPhotos,
                    add: { showingPhotoPicker = true },
                    drop: { addPhotos($0) }
                )
                .frame(width: 220)
                .transition(.move(edge: .leading))
                Divider()
            }
            detail
        }
        .animation(.easeInOut(duration: 0.18), value: sidebarVisible)
        .frame(minWidth: 760, minHeight: 520)
        .navigationTitle("SELPHY CP1500 Print")
        .navigationSubtitle(currentPhoto?.lastPathComponent ?? "")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { sidebarVisible.toggle() } label: {
                    Label(tr("Show or hide the photo list"), systemImage: "sidebar.leading")
                }
                .help(tr("Show or hide the photo list"))
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
            ToolbarItem(placement: .primaryAction) {
                Button { openSettings() } label: {
                    Label(tr("Settings"), systemImage: "gearshape")
                }
                .help(tr("Settings"))
            }
        }
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
    }

    private var detail: some View {
        VStack(spacing: 0) {
            PreviewPanel(photo: currentPhoto, hasPhotos: !selectedPhotos.isEmpty)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if settings.profileBookmark == nil {
                HStack {
                    Label(tr("No ICC profile yet: choose the Farbenwerk profile in Settings."), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                    Spacer()
                    Button(tr("Open Settings…")) { openSettings() }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            if !generatedCopies.isEmpty {
                generatedStrip
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            Divider()
            bottomBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        // Explicit, appearance-aware background: without it the pane showed white under light-coloured
        // text in dark mode when the view was not drawn inside a window (and never depends on the host).
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var generatedStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(trn(generatedCopies.count, one: "1 copy ready", other: "%d copies ready"), systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                if !generatedSummary.isEmpty {
                    Text(generatedSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(tr("Show in Finder")) {
                    if let generatedFolder { NSWorkspace.shared.open(generatedFolder) }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            HStack(spacing: 10) {
                Picker(tr("Image placement"), selection: $settings.printFit) {
                    ForEach(PrintFit.allCases) { fit in
                        Text(fit.title).tag(fit)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 230)
                Spacer()
                Button(tr("Print…")) { printCopies() }
                    .disabled(isPrinting)
                if settings.saveFolderBookmark != nil {
                    Button(tr("Save to another folder…")) { showingSaveFolderPicker = true }
                    Button(trf("Save to %@", settings.saveFolderDisplayName)) { saveToRememberedFolder() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(tr("Save to a folder…")) { showingSaveFolderPicker = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            Text(tr("These copies are temporary and are removed after 24 hours. To keep them, save them to a folder: existing files are never overwritten or deleted."))
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Picker(tr("Rendering intent"), selection: $settings.renderingIntent) {
                    ForEach(RenderingIntent.allCases) { intent in
                        Text(intent.title).tag(intent)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
                .help(settings.renderingIntent.explanation)
                Picker(tr("Output file format"), selection: $settings.outputFormat) {
                    ForEach(OutputFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
                .help(settings.outputFormat.explanation)
                Spacer()
                if isPreparing {
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                        .frame(width: 100)
                    Text("\(progress.completed)/\(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button(tr("Cancel")) { conversionWork?.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button(tr("Generate test copies")) { prepareCopies() }
                        .disabled(selectedPhotos.isEmpty || settings.profileBookmark == nil)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
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

    /// Sends the generated copies to the macOS print dialog (AirPrint is the only path for the CP1500).
    private func printCopies() {
        guard !generatedCopies.isEmpty, !isPrinting else { return }
        if !settings.hidePrintNotice, !confirmPrintNotice() { return }
        isPrinting = true
        let files = generatedCopies
        let fit = settings.printFit
        Task {
            let outcome = await printService.print(files: files, fit: fit, in: NSApp.keyWindow)
            switch outcome {
            case .sent(let count):
                statusMessage = trn(count, one: "Sent 1 copy to the printer.", other: "Sent %d copies to the printer.")
            case .cancelled(let sent):
                statusMessage = sent == 0
                    ? tr("Printing cancelled.")
                    : trn(sent, one: "Printing cancelled after 1 copy.", other: "Printing cancelled after %d copies.")
            case .failed(let error):
                statusMessage = trf("Printing failed: %@", error.localizedDescription)
            }
            isPrinting = false
        }
    }

    private func confirmPrintNotice() -> Bool {
        let alert = NSAlert()
        alert.messageText = tr("Before printing")
        alert.informativeText = tr("On the printer, switch Image Optimize off (Setup > Print settings): it would correct brightness and contrast again after this correction, and it resets when the printer is turned off. In the print dialog choose the Postcard paper size and leave scaling and any colour adjustment off. Printing is experimental and has not been validated with physical prints.")
        alert.addButton(withTitle: tr("Continue"))
        alert.addButton(withTitle: tr("Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = tr("Don't show this again")
        let proceed = alert.runModal() == .alertFirstButtonReturn
        if proceed, alert.suppressionButton?.state == .on { settings.hidePrintNotice = true }
        return proceed
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

    private func handlePhotoSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            addPhotos(urls)
        case .failure(let error):
            statusMessage = trf("Photo selection failed: %@", error.localizedDescription)
        }
    }

    /// Adds photos to the list (used by the picker and by drag and drop); returns whether any was added.
    @discardableResult
    private func addPhotos(_ urls: [URL]) -> Bool {
        let fresh = urls.filter { PhotoFiles.isSupported($0) && !selectedPhotos.contains($0) }
        guard !fresh.isEmpty else { return false }
        selectedPhotos.append(contentsOf: fresh)
        if previewPhoto == nil || !selectedPhotos.contains(previewPhoto!) { previewPhoto = selectedPhotos.first }
        statusMessage = trn(selectedPhotos.count, one: "1 photo queued.", other: "%d photos queued.")
        resetGeneratedCopies()
        return true
    }

    private func removePhoto(_ url: URL) {
        selectedPhotos.removeAll { $0 == url }
        if previewPhoto == url { previewPhoto = selectedPhotos.first }
        resetGeneratedCopies()
    }

    private func clearPhotos() {
        selectedPhotos.removeAll()
        previewPhoto = nil
        resetGeneratedCopies()
    }

    private func resetGeneratedCopies() {
        generatedCopies.removeAll()
        generatedFolder = nil
        savedFolder = nil
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
