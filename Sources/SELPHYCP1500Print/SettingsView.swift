import SwiftUI
import AppKit

/// The Settings window (⌘,): profile, rendering intent and black point compensation, language,
/// print notice. The rendering intent is the same setting as the picker in the main window.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var showingProfilePicker = false
    @State private var profileReport: ICCProfileReport?
    @State private var profileMessage: String?
    @State private var profileFailed = false

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
                        Text(tr("The path is remembered securely between launches."))
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
                Picker(tr("Rendering intent"), selection: $settings.renderingIntent) {
                    ForEach(RenderingIntent.allCases) { intent in
                        Text(intent.title).tag(intent)
                    }
                }
                Text(settings.renderingIntent.explanation)
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

            Section(tr("General")) {
                Picker(tr("Language"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                Picker(tr("Interface theme"), selection: $settings.theme) {
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

    /// Selects the remembered profile in a Finder window.
    private func revealProfile() {
        do {
            guard let url = try settings.resolveProfileURL() else { return }
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            NSWorkspace.shared.activateFileViewerSelecting([url])
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
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            profileReport = try ICCProfileInspector.inspect(url: url)
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
