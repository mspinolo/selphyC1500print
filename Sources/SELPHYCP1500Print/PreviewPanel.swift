import SwiftUI
import AppKit

/// Soft-proof preview of the selected photo: original, expected print without correction and
/// expected print with correction, a before/after slider and analysis overlays (deviation map
/// with an adjustable scale, shadows the printer cannot reproduce, colours outside its gamut,
/// Postcard layout). A model-based simulation from the printer profile, not a print proof.
struct PreviewPanel: View {
    @EnvironmentObject private var settings: AppSettings
    let photo: URL?
    let hasPhotos: Bool

    enum Mode: String, CaseIterable, Identifiable {
        case original, uncorrected, corrected, compare, heatMap, shadows, gamut, layout

        var id: String { rawValue }

        var title: String {
            switch self {
            case .original: tr("Original")
            case .uncorrected: tr("Without correction")
            case .corrected: tr("With correction")
            case .compare: tr("Compare")
            case .heatMap: tr("ΔE map")
            case .shadows: tr("Dark zones")
            case .gamut: tr("Out of gamut")
            case .layout: tr("Postcard layout")
            }
        }
    }

    enum Zoom: String, CaseIterable, Identifiable {
        case fit, x100, x200, x400

        var id: String { rawValue }

        var title: String {
            switch self {
            case .fit: tr("Fit")
            case .x100: "100%"
            case .x200: "200%"
            case .x400: "400%"
            }
        }

        /// Points per preview pixel; nil = fit the area.
        var factor: Double? {
            switch self {
            case .fit: nil
            case .x100: 1
            case .x200: 2
            case .x400: 4
            }
        }
    }

    @State private var mode: Mode = .compare
    @State private var zoom: Zoom = .fit
    @State private var simulatePaperWhite = false
    @State private var previewBlackPointCompensation = false
    @State private var preview: PreviewService.Preview?
    @State private var errorMessage: String?
    @State private var isRendering = false
    @State private var sliderFraction = 0.5
    @State private var deltaEScale = DeltaEScale.standard
    @State private var shadowMargin = 0.0
    @State private var gamutLoss = 8.0
    @State private var overlay: CGImage?
    /// Share of highlighted pixels in the Dark zones / Out of gamut views, computed with the overlay.
    @State private var overlayShare: Double?
    @State private var generation = 0
    /// The pointer readout lives in its own object, held without observing it: pointer moves then
    /// redraw only the readout line, not the whole panel (images, overlays, controls).
    @State private var pointer = PointerReadout()
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

    /// Everything that changes the overlay image.
    private struct OverlayKey: Equatable {
        var mode: Mode
        var scale: DeltaEScale
        var margin: Double
        var gamutLoss: Double
        var generation: Int
    }

    private var currentPhoto: URL? { photo }

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

    private var overlayKey: OverlayKey {
        OverlayKey(mode: mode, scale: deltaEScale, margin: shadowMargin, gamutLoss: gamutLoss, generation: generation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !hasPhotos {
                placeholder(tr("Add a photo to see the preview."), symbol: "photo.on.rectangle.angled")
            } else if settings.profileBookmark == nil {
                placeholder(tr("Choose the ICC profile to see the preview."), symbol: "doc.badge.gearshape")
            } else {
                controls
                previewArea
                readout
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        notes
                        if let preview {
                            ColorDetails(preview: preview)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
        }
        .task(id: renderKey) { await render() }
        .onChange(of: overlayKey) { recomputeOverlay() }
        .onChange(of: photo) { pointer.reading = nil }
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker(tr("View"), selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 280)
                Picker(tr("Zoom"), selection: $zoom) {
                    ForEach(Zoom.allCases) { zoom in
                        Text(zoom.title).tag(zoom)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
                .disabled(mode == .layout)
                .help(tr("Zoom of the preview image (100% = one preview pixel per point). Scroll to move around."))
                Spacer()
                Menu {
                    Toggle(tr("Simulate paper white"), isOn: $simulatePaperWhite)
                    Toggle(tr("Monitor black instead of printed black"), isOn: $previewBlackPointCompensation)
                        .disabled(simulatePaperWhite)
                } label: {
                    Label(tr("Preview options"), systemImage: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            modeControls
        }
    }

    @ViewBuilder
    private var modeControls: some View {
        switch mode {
        case .heatMap:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(tr("ΔE scale: from")).font(.caption)
                    Slider(value: Binding(
                        get: { Double(deltaEScale.low) },
                        set: { deltaEScale.low = Float($0); deltaEScale = deltaEScale.clamped() }
                    ), in: 0...20, step: 0.5)
                    .frame(maxWidth: 180)
                    Text(String(format: "%.1f", deltaEScale.low)).font(.caption.monospacedDigit())
                    Text(tr("to")).font(.caption)
                    Slider(value: Binding(
                        get: { Double(deltaEScale.high) },
                        set: { deltaEScale.high = Float($0); deltaEScale = deltaEScale.clamped() }
                    ), in: 1...30, step: 0.5)
                    .frame(maxWidth: 180)
                    Text(String(format: "%.1f", deltaEScale.high)).font(.caption.monospacedDigit())
                    Button(tr("Reset")) { deltaEScale = .standard }
                        .controlSize(.small)
                        .disabled(deltaEScale == .standard)
                }
                HStack(spacing: 8) {
                    Text(String(format: "%.1f", deltaEScale.low)).font(.caption2.monospacedDigit())
                    HeatLegend(scale: deltaEScale)
                        .frame(width: 200, height: 10)
                    Text(String(format: "%.1f", deltaEScale.high)).font(.caption2.monospacedDigit())
                    Text(tr("ΔE00: transparent below the first value, red from the second."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .shadows:
            if let preview {
                let darkest = preview.stats.darkestToneL
                let share = overlayShare ?? 0
                HStack(spacing: 10) {
                    Text(tr("Margin above the darkest tone")).font(.caption)
                    Slider(value: $shadowMargin, in: 0...15, step: 0.5)
                        .frame(maxWidth: 180)
                    Text(String(format: "%.1f L*", shadowMargin)).font(.caption.monospacedDigit())
                    Text(trf("Highlighted: darker than L* %.0f, the darkest tone the printer reproduces: %.0f%% of pixels.", darkest + shadowMargin, share * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .gamut:
            if preview != nil {
                let share = overlayShare ?? 0
                HStack(spacing: 10) {
                    Text(tr("Chroma lost above")).font(.caption)
                    Slider(value: $gamutLoss, in: 2...30, step: 1)
                        .frame(maxWidth: 180)
                    Text(String(format: "C* %.0f", gamutLoss)).font(.caption.monospacedDigit())
                    Text(trf("Highlighted: colours the print makes duller by more than this: %.0f%% of pixels.", share * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .layout:
            HStack(spacing: 10) {
                Picker(tr("Image placement"), selection: $settings.printFit) {
                    ForEach(PrintFit.allCases) { fit in
                        Text(fit.title).tag(fit)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380)
                Text(tr("Shows the sheet as the print dialog would place the image; the dimmed part is cut off."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    // MARK: Image area

    @ViewBuilder
    private var previewArea: some View {
        ZStack {
            if let preview {
                if mode == .layout {
                    PostcardLayoutView(image: preview.corrected, fit: settings.printFit)
                } else {
                    ZoomContainer(
                        imageSize: CGSize(width: preview.original.width, height: preview.original.height),
                        factor: zoom.factor,
                        onHover: { point in updateReading(point, preview: preview) }
                    ) {
                        imageContent(for: preview)
                    }
                }
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
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        // Behind the photo: the window colour, or middle grey (L* 50) in the neutral grey theme.
        .background(settings.theme.palette.imageSurround)
    }

    @ViewBuilder
    private func imageContent(for preview: PreviewService.Preview) -> some View {
        switch mode {
        case .original:
            ImageFit(image: preview.original)
        case .uncorrected:
            ImageFit(image: preview.uncorrected)
        case .corrected, .layout:
            ImageFit(image: preview.corrected)
        case .heatMap, .shadows, .gamut:
            ZStack {
                ImageFit(image: preview.original).opacity(mode == .heatMap ? 0.45 : 0.6)
                if let overlay {
                    ImageFit(image: overlay)
                }
            }
        case .compare:
            ComparisonSlider(
                before: preview.uncorrected,
                after: preview.corrected,
                fraction: $sliderFraction
            )
        }
    }

    private func updateReading(_ point: CGPoint?, preview: PreviewService.Preview) {
        let next = point.flatMap { PreviewGeometry.reading(maps: preview.maps, u: Double($0.x), v: Double($0.y)) }
        if next != pointer.reading { pointer.reading = next }
    }

    private var readout: some View { ReadoutLine(pointer: pointer) }

    @ViewBuilder
    private var notes: some View {
        VStack(alignment: .leading, spacing: 3) {
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

    private func recomputeOverlay() {
        guard let preview else { overlay = nil; overlayShare = nil; return }
        switch mode {
        case .heatMap:
            overlay = Overlays.heatMap(preview.maps, scale: deltaEScale)
            overlayShare = nil
        case .shadows:
            let darkest = preview.stats.darkestToneL
            overlay = Overlays.shadowMask(preview.maps, darkestL: darkest, margin: shadowMargin)
            overlayShare = Overlays.shadowShare(preview.maps, darkestL: darkest, margin: shadowMargin)
        case .gamut:
            overlay = Overlays.gamutMask(preview.maps, minimumLoss: Float(gamutLoss))
            overlayShare = Overlays.gamutShare(preview.maps, minimumLoss: Float(gamutLoss))
        default:
            overlay = nil
            overlayShare = nil
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
            generation += 1
            errorMessage = nil
        } catch {
            if Task.isCancelled { return }
            preview = nil
            overlay = nil
            overlayShare = nil
            errorMessage = trf("Preview unavailable: %@", error.localizedDescription)
        }
    }
}

/// Scrollable, zoomable area. The content has the image's aspect ratio; `onHover` receives the
/// pointer position as fractions (0...1) of the image, or nil when it leaves.
private struct ZoomContainer<Content: View>: View {
    let imageSize: CGSize
    let factor: Double?
    let onHover: (CGPoint?) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let side = PreviewGeometry.contentSize(imageSize: imageSize, available: geometry.size, factor: factor)
            ScrollView([.horizontal, .vertical]) {
                content()
                    .frame(width: side.width, height: side.height)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            onHover(CGPoint(x: point.x / max(1, side.width), y: point.y / max(1, side.height)))
                        case .ended:
                            onHover(nil)
                        }
                    }
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
        }
    }
}

/// The Postcard sheet with the image placed as the print dialog would place it.
private struct PostcardLayoutView: View {
    let image: CGImage
    let fit: PrintFit

    var body: some View {
        GeometryReader { geometry in
            let landscape = image.width > image.height
            let aspect = landscape ? 148.0 / 100.0 : 100.0 / 148.0    // sheet width / height
            let available = CGSize(width: max(1, geometry.size.width - 24), height: max(1, geometry.size.height - 40))
            let sheetWidth = min(available.width, available.height * aspect)
            let sheet = CGRect(
                x: (geometry.size.width - sheetWidth) / 2,
                y: (geometry.size.height - 16 - sheetWidth / aspect) / 2,
                width: sheetWidth, height: sheetWidth / aspect
            )
            let rect = PrintLayout.imageRect(
                imageSize: CGSize(width: image.width, height: image.height), in: sheet, fit: fit)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .opacity(0.3)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: sheet.width, height: sheet.height)
                    .position(x: sheet.midX, y: sheet.midY)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX - sheet.minX, y: rect.midY - sheet.minY)
                }
                .frame(width: sheet.width, height: sheet.height)
                .clipped()
                .position(x: sheet.midX, y: sheet.midY)
                Rectangle()
                    .stroke(Color.secondary, lineWidth: 1)
                    .frame(width: sheet.width, height: sheet.height)
                    .position(x: sheet.midX, y: sheet.midY)
                Text(tr("Postcard 100 × 148 mm"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .position(x: geometry.size.width / 2, y: geometry.size.height - 8)
            }
        }
    }
}

/// Colour bar of the deviation map for the chosen scale.
private struct HeatLegend: View {
    let scale: DeltaEScale

    var body: some View {
        let stops = (0...10).map { step -> Gradient.Stop in
            let t = Float(step) / 10
            let (green, alpha) = Overlays.ramp(t)
            return Gradient.Stop(
                color: Color(red: 1, green: Double(green) / 255, blue: 0).opacity(Double(alpha) / 255),
                location: Double(t))
        }
        return RoundedRectangle(cornerRadius: 3)
            .fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.5), lineWidth: 0.5))
            .accessibilityLabel(trf("Colour scale from ΔE00 %.1f to %.1f", Double(scale.low), Double(scale.high)))
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

/// What is under the pointer, kept apart from the panel's state (see `PreviewPanel.pointer`).
@MainActor
final class PointerReadout: ObservableObject {
    @Published var reading: PixelReading?
}

/// The colour under the pointer: what the photo should look like and what the model predicts in print.
private struct ReadoutLine: View {
    @ObservedObject var pointer: PointerReadout

    var body: some View {
        Group {
            if let reading = pointer.reading {
                Text(trf("Original L* %.1f a* %.1f b* %.1f  →  print L* %.1f a* %.1f b* %.1f  ·  ΔE00 %.1f",
                         reading.intended.l, reading.intended.a, reading.intended.b,
                         reading.predicted.l, reading.predicted.a, reading.predicted.b, reading.deltaE))
            } else {
                Text(tr("Move the pointer over the photo to read the colour of a point."))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
