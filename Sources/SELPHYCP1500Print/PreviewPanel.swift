import SwiftUI
import AppKit

/// Soft-proof preview of the selected photo: original, expected print without correction and
/// expected print with correction, plus a before/after slider. A model-based simulation from
/// the printer profile, not a print proof.
struct PreviewPanel: View {
    @EnvironmentObject private var settings: AppSettings
    let photos: [URL]

    enum Mode: String, CaseIterable, Identifiable {
        case original = "Originale"
        case uncorrected = "Senza correzione"
        case corrected = "Con correzione"
        case compare = "Confronto"
        case heatMap = "Mappa ΔE"

        var id: String { rawValue }
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
        GroupBox("Anteprima di stampa (simulazione)") {
            VStack(alignment: .leading, spacing: 8) {
                if photos.isEmpty {
                    Text("Aggiungi una fotografia per vedere l'anteprima.")
                        .foregroundStyle(.secondary)
                } else if settings.profileBookmark == nil {
                    Text("Scegli il profilo ICC per vedere l'anteprima.")
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
                Picker("Vista", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 560)
            }
            HStack(spacing: 16) {
                Toggle("Simula il bianco della carta", isOn: $simulatePaperWhite)
                Toggle("Nero del monitor al posto del nero stampato", isOn: $previewBlackPointCompensation)
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
                Text("Trasparente: la stampa prevista è vicina all'originale (ΔE00 sotto 1). Giallo: circa 3. Rosso: 6 o più.")
                    .font(.caption)
            }
            if mode == .compare {
                Text("A sinistra: stampa prevista senza correzione. A destra: con correzione. Trascina per spostare il divisore.")
                    .font(.caption)
            }
            if let preview {
                if preview.outOfGamutFraction > 0.005 {
                    Text(String(format: "Circa il %.0f%% dei pixel ha colori stampabili fuori dalla gamma del monitor: nell'anteprima sono troncati.", preview.outOfGamutFraction * 100))
                        .font(.caption)
                }
                if preview.usedSRGBFallback {
                    Text("Profilo del monitor non utilizzabile: l'anteprima usa sRGB.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Text("Simulazione calcolata dal profilo della stampante: non è una prova di stampa e non è stata validata con stampe fisiche.")
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
            errorMessage = "Anteprima non disponibile: \(error.localizedDescription)"
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
        DisclosureGroup("Dettagli colore", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    row("Originale", "numeri sRGB della foto (\(preview.sourceDescription)).")
                    row("Senza correzione", "gli stessi numeri inviati alla stampante, mostrati col modello del profilo e convertiti nel profilo del monitor (\(preview.displayName)).")
                    row("Con correzione", "i numeri corretti dal profilo, mostrati allo stesso modo. Il file esportato li etichetta sRGB.")
                }
                Divider()
                checks
                Text("Stime dal modello del profilo, misurate rispetto alla foto letta come sRGB: da confermare con una stampa.")
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
            Text(String(format: "Scostamento previsto dall'originale: medio %.1f, 95° percentile %.1f (ΔE00).", stats.meanDeltaE, stats.p95DeltaE))
            Text(String(format: "Colori non riproducibili (ΔE00 sopra 3): %.0f%% dei pixel.", stats.shareNotReproducible * 100))
            Text(String(format: "Ombre più scure del tono più scuro riprodotto (L* %.0f): %.0f%% dei pixel — vengono unite o compresse.", stats.darkestToneL, stats.shareBelowDarkestTone * 100))
            if stats.isBlackAndWhite {
                if let chroma = stats.neutralP95Chroma {
                    Text(String(format: "Foto in bianco e nero: tinta residua prevista nei toni riproducibili C* %.1f (0 = neutro).", chroma))
                } else {
                    Text("Foto in bianco e nero: nessun tono neutro riproducibile da valutare.")
                }
            }
        }
        .font(.caption)
    }
}
