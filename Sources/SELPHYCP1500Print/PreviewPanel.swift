import SwiftUI
import AppKit

/// Soft-proof preview of the selected photo: original, expected print without correction and
/// expected print with correction, plus a before/after slider. A model-based simulation from
/// the printer profile, not a print proof.
struct PreviewPanel: View {
    @EnvironmentObject private var settings: AppSettings
    let photos: [URL]

    enum Mode: String, CaseIterable, Identifiable {
        case original, uncorrected, corrected, compare, heatMap

        var id: String { rawValue }

        var title: String {
            switch self {
            case .original: tr("Original")
            case .uncorrected: tr("Without correction")
            case .corrected: tr("With correction")
            case .compare: tr("Compare")
            case .heatMap: tr("ΔE map")
            }
        }
    }

    @State private var selectedPhoto: URL?
    @State private var mode: Mode = .compare
    @State private var simulatePaperWhite = false
    @State private var previewBlackPointCompensation = false
    @State private var preview: PreviewService.Preview?
    @State private var errorMessage: String?
    @State private var isRendering = false
    @State private var sliderFraction = 0.5
    /// Keeps the decoded/corrected buffers and renderings between re-renders.
    @State private var session = PreviewSession()

    /// Everything that changes the result; used to re-render automatically.
    private struct RenderKey: Equatable {
        var photo: URL?
        var intent: RenderingIntent
        var bpc: Bool
        var paper: Bool
        var previewBPC: Bool
        var profile: Data?
    }

    /// The chosen photo, or the first one when the choice is gone (e.g. the list was cleared).
    private var currentPhoto: URL? {
        if let selectedPhoto, photos.contains(selectedPhoto) { return selectedPhoto }
        return photos.first
    }

    private var renderKey: RenderKey {
        RenderKey(
            photo: currentPhoto,
            intent: settings.renderingIntent,
            bpc: settings.blackPointCompensation,
            paper: simulatePaperWhite,
            previewBPC: previewBlackPointCompensation,
            profile: settings.profileBookmark
        )
    }

    var body: some View {
        GroupBox(tr("Print preview (simulation)")) {
            VStack(alignment: .leading, spacing: 8) {
                if photos.isEmpty {
                    Text(tr("Add a photo to see the preview."))
                        .foregroundStyle(.secondary)
                } else if settings.profileBookmark == nil {
                    Text(tr("Choose the ICC profile to see the preview."))
                        .foregroundStyle(.secondary)
                } else {
                    controls
                    previewArea
                    notes
                    if let preview {
                        ColorDetails(preview: preview)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .task(id: renderKey) { await render() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if photos.count > 1 {
                    Picker("Fotografia", selection: Binding(
                        get: { currentPhoto },
                        set: { selectedPhoto = $0 }
                    )) {
                        ForEach(photos, id: \.path) { url in
                            Text(url.lastPathComponent).tag(Optional(url))
                        }
                    }
                    .frame(maxWidth: 320)
                }
                Spacer()
                Picker(tr("View"), selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 560)
            }
            HStack(spacing: 16) {
                Toggle(tr("Simulate paper white"), isOn: $simulatePaperWhite)
                Toggle(tr("Monitor black instead of printed black"), isOn: $previewBlackPointCompensation)
                    .disabled(simulatePaperWhite)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var previewArea: some View {
        ZStack {
            if let preview {
                imageArea(for: preview)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if isRendering {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 340)
    }

    @ViewBuilder
    private func imageArea(for preview: PreviewService.Preview) -> some View {
        switch mode {
        case .original:
            ImageFit(image: preview.original)
        case .uncorrected:
            ImageFit(image: preview.uncorrected)
        case .corrected:
            ImageFit(image: preview.corrected)
        case .heatMap:
            ZStack {
                ImageFit(image: preview.original).opacity(0.45)
                ImageFit(image: preview.heatMap)
            }
        case .compare:
            ComparisonSlider(
                before: preview.uncorrected,
                after: preview.corrected,
                fraction: $sliderFraction
            )
        }
    }

    @ViewBuilder
    private var notes: some View {
        VStack(alignment: .leading, spacing: 3) {
            if mode == .heatMap {
                Text(tr("Transparent: the predicted print is close to the original (ΔE00 below 1). Yellow: about 3. Red: 6 or more."))
                    .font(.caption)
            }
            if mode == .compare {
                Text(tr("Left: predicted print without correction. Right: with correction. Drag to move the divider."))
                    .font(.caption)
            }
            if let preview {
                if preview.outOfGamutFraction > 0.005 {
                    Text(trf("About %.0f%% of pixels have printable colours outside the monitor's gamut: they are clipped in the preview.", preview.outOfGamutFraction * 100))
                        .font(.caption)
                }
                if preview.usedSRGBFallback {
                    Text(tr("Monitor profile unusable: the preview uses sRGB."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Text(tr("Simulation computed from the printer profile: it is not a proof and has not been validated with physical prints."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func render() async {
        guard let photo = currentPhoto, settings.profileBookmark != nil else {
            preview = nil
            return
        }
        isRendering = true
        defer { isRendering = false }
        do {
            guard let profileURL = try settings.resolveProfileURL() else { return }
            let hasAccess = profileURL.startAccessingSecurityScopedResource()
            defer { if hasAccess { profileURL.stopAccessingSecurityScopedResource() } }
            let printerICC = try Data(contentsOf: profileURL)
            let display = PreviewService.Display.current()
            var options = PreviewService.Options(
                intent: settings.renderingIntent,
                blackPointCompensation: settings.blackPointCompensation
            )
            options.simulatePaperWhite = simulatePaperWhite
            options.previewBlackPointCompensation = previewBlackPointCompensation
            let session = session
            let result = try await Task.detached(priority: .userInitiated) {
                try session.makePreview(sourceURL: photo, printerICC: printerICC, display: display, options: options)
            }.value
            if Task.isCancelled { return }
            preview = result
            errorMessage = nil
        } catch {
            if Task.isCancelled { return }
            preview = nil
            errorMessage = trf("Preview unavailable: %@", error.localizedDescription)
        }
    }
}

/// An image scaled to fit, keeping its aspect ratio. The image carries its own colour space,
/// so the system shows it correctly on the display.
private struct ImageFit: View {
    let image: CGImage

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}

/// Two renderings of the same photo with a draggable divider: `before` on the left,
/// `after` on the right.
private struct ComparisonSlider: View {
    let before: CGImage
    let after: CGImage
    @Binding var fraction: Double

    var body: some View {
        let aspect = CGFloat(before.width) / CGFloat(max(1, before.height))
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                ImageFit(image: before)
                ImageFit(image: after)
                    .mask(alignment: .trailing) {
                        Rectangle().frame(width: width * (1 - fraction))
                    }
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .shadow(radius: 1)
                    .offset(x: width * fraction - 1)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    fraction = min(1, max(0, Double(value.location.x / max(1, width))))
                }
            )
        }
        .aspectRatio(aspect, contentMode: .fit)
    }
}


/// Collapsible explanation of the three views and the per-photo checks. Everything here is a
/// model estimate from the printer profile, to be confirmed with a print.
private struct ColorDetails: View {
    let preview: PreviewService.Preview
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(tr("Colour details"), isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    row(tr("Original"), trf("sRGB numbers of the photo (%@).", preview.sourceDescription))
                    row(tr("Without correction"), trf("the same numbers sent to the printer, shown with the profile's model and converted to the monitor profile (%@).", preview.displayName))
                    row(tr("With correction"), tr("the numbers corrected by the profile, shown the same way. The exported file tags them sRGB."))
                }
                Divider()
                checks
                Text(tr("Estimates from the profile's model, measured against the photo read as sRGB: to be confirmed with a print."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .font(.callout)
    }

    private func row(_ title: String, _ text: String) -> some View {
        (Text(title + ": ").bold() + Text(text)).font(.caption)
    }

    @ViewBuilder
    private var checks: some View {
        let stats = preview.stats
        VStack(alignment: .leading, spacing: 3) {
            Text(trf("Predicted deviation from the original: mean %.1f, 95th percentile %.1f (ΔE00).", stats.meanDeltaE, stats.p95DeltaE))
            Text(trf("Non-reproducible colours (ΔE00 above 3): %.0f%% of pixels.", stats.shareNotReproducible * 100))
            Text(trf("Shadows darker than the darkest reproduced tone (L* %.0f): %.0f%% of pixels — they are merged or compressed.", stats.darkestToneL, stats.shareBelowDarkestTone * 100))
            if stats.isBlackAndWhite {
                if let chroma = stats.neutralP95Chroma {
                    Text(trf("Black-and-white photo: predicted residual tint in reproducible tones C* %.1f (0 = neutral).", chroma))
                } else {
                    Text(tr("Black-and-white photo: no reproducible neutral tone to evaluate."))
                }
            }
        }
        .font(.caption)
    }
}
