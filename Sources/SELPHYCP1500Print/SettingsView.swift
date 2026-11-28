import SwiftUI
import AppKit

/// The Settings window (⌘,): profile, rendering intent and black point compensation, language,
/// print notice. The rendering intent is the same setting as the picker in the main window.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var showingProfilePicker = false
    @State private var profileReport: ICCProfileReport?
    @State private var profileMessage: String?
    @State private var profileFailed = false
    @State private var profileDropTargeted = false
    @State private var temporaryFolderMessage: String?

    /// BPC is mandatory for perceptual/saturation with an ICC v4 printer profile.
    private var blackPointCompensationForced: Bool {
        let major = profileReport.flatMap { Int($0.version.prefix(1)) } ?? 4
        return settings.renderingIntent != .relativeColorimetric && major >= 4
    }

    var body: some View {
        Form {
            Section(tr("Farbenwerk ICC profile")) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.profileDisplayName.isEmpty ? tr("No profile selected") : settings.profileDisplayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(tr("The path is remembered securely between launches. You can also drag an .icc file here."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(tr("Choose profile…")) { showingProfilePicker = true }
                    if !settings.profileDisplayName.isEmpty {
                        Button(tr("Show in Finder")) { revealProfile() }
                        Button(tr("Remove"), role: .destructive) {
                            settings.clearProfile()
                            profileReport = nil
                            profileMessage = nil
                        }
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2).opacity(profileDropTargeted ? 1 : 0))
                // A profile dragged from the Finder is chosen like one picked in the dialog.
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first(where: { ["icc", "icm"].contains($0.pathExtension.lowercased()) }) else { return false }
                    handleProfileSelection(.success([url]))
                    return true
                } isTargeted: { profileDropTargeted = $0 }
                if let report = profileReport {
                    Label(report.summary, systemImage: report.isExpectedPrinterProfile ? "checkmark.seal" : "exclamationmark.triangle")
                        .foregroundStyle(report.isExpectedPrinterProfile ? .green : .orange)
                    Text("ICC \(report.version) · \(report.profileClass) · \(report.colorSpace) → \(report.connectionSpace)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                } else if let profileMessage {
                    Label(profileMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(profileFailed ? .orange : .secondary)
                }
            }

            Section(tr("Colour management")) {
                Picker(tr("Rendering intent"), selection: Bindable(settings).renderingIntent) {
                    ForEach(RenderingIntent.allCases) { intent in
                        Text(intent.title).tag(intent)
                    }
                }
                Text(settings.renderingIntent.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    tr("Black point compensation (BPC)"),
                    isOn: blackPointCompensationForced ? .constant(true) : Bindable(settings).blackPointCompensation
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

            Section(tr("Temporary copies")) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.temporaryFolderBookmark == nil ? tr("System temporary folder") : settings.temporaryFolderDisplayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(trf("The corrected copies are written to a subfolder named “%@”; sessions older than 24 hours are removed when new copies are made. Nothing else in the folder is touched.",
                                 ColorCorrectionService.temporarySubfolderName))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if settings.temporaryFolderBookmark != nil {
                        Button(tr("Use the system folder")) { settings.clearTemporaryFolder() }
                    }
                    Button(tr("Choose folder…")) { chooseTemporaryFolder() }
                }
                Button(tr("Show in Finder")) { revealTemporaryFolder() }
                    .buttonStyle(.link)
                if let temporaryFolderMessage {
                    Label(temporaryFolderMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            Section(tr("General")) {
                Picker(tr("Language"), selection: Bindable(settings).language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                Picker(tr("Interface theme"), selection: Bindable(settings).theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Text(settings.theme.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(tr("Show the notice before printing"), isOn: Binding(
                    get: { !settings.hidePrintNotice },
                    set: { settings.hidePrintNotice = !$0 }
                ))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(settings.theme.palette.paintsBackgrounds ? .hidden : .automatic)
        .background(settings.theme.palette.paintsBackgrounds ? settings.theme.palette.windowBackground : Color.clear)
        .themed(settings.theme)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { restoreProfileReport() }
        .fileImporter(
            isPresented: $showingProfilePicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false,
            onCompletion: handleProfileSelection
        )
    }

    private func chooseTemporaryFolder() {
        // NSOpenPanel rather than a second fileImporter on this view (SwiftUI keeps only one).
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("Use this folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.chooseTemporaryFolder(at: url)
            temporaryFolderMessage = nil
        } catch {
            temporaryFolderMessage = trf("The folder cannot be used: %@", error.localizedDescription)
        }
    }

    /// Opens the folder that holds the temporary sessions (creating it if needed).
    private func revealTemporaryFolder() {
        do {
            let root = ColorCorrectionService.sessionRoot(in: try settings.temporaryFolder())
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(root)
            temporaryFolderMessage = nil
        } catch {
            temporaryFolderMessage = trf("The chosen temporary folder cannot be reached: %@", error.localizedDescription)
        }
    }

    /// Selects the remembered profile in a Finder window.
    private func revealProfile() {
        do {
            guard let url = try settings.resolveProfileURL() else { return }
            url.withSecurityScope { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        } catch {
            profileFailed = true
            profileMessage = trf("The remembered profile can no longer be read: %@", error.localizedDescription)
        }
    }

    /// Shows again the report of the remembered profile after a restart.
    private func restoreProfileReport() {
        guard profileReport == nil, settings.profileBookmark != nil else { return }
        do {
            guard let url = try settings.resolveProfileURL() else { return }
            profileReport = try url.withSecurityScope { try ICCProfileInspector.inspect(url: $0) }
        } catch {
            profileFailed = true
            profileMessage = trf("The remembered profile can no longer be read: %@", error.localizedDescription)
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
                profileMessage = nil
                profileFailed = false
            } catch {
                profileReport = nil
                profileFailed = true
                profileMessage = trf("Unable to verify the profile: %@", error.localizedDescription)
            }
        case .failure(let error):
            profileFailed = true
            profileMessage = trf("Profile selection failed: %@", error.localizedDescription)
        }
    }
}
