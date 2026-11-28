import AppKit
import ImageIO
import SwiftUI

// Full-screen view: the photo at full resolution on darktable's middle grey, opened on request
// (toolbar button, View menu, Shift-Cmd-F) and closed with Esc. Nothing is computed until it is
// opened, and its full-resolution buffers are freed when it closes.

/// Pixel size of a photo file with its EXIF orientation applied, read from the header only.
enum ImageInfo {
    static func orientedPixelSize(of url: URL) -> CGSize? {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }
}

/// Zoom and pan arithmetic, in points; scales are points per image pixel.
enum FullScreenGeometry {
    static func fitScale(image: CGSize, in area: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, area.width > 0, area.height > 0 else { return 1 }
        return min(area.width / image.width, area.height / image.height)
    }

    /// The scale at which one image pixel covers one physical pixel of the screen (100%).
    static func actualPixelsScale(backingScale: CGFloat) -> CGFloat {
        1 / max(1, backingScale)
    }

    /// Keeps the image over the area: no offset on an axis where it fits, otherwise at most half
    /// the overflow (the image edge stops at the area edge).
    static func clampedOffset(_ offset: CGSize, display: CGSize, area: CGSize) -> CGSize {
        let limitX = max(0, (display.width - area.width) / 2)
        let limitY = max(0, (display.height - area.height) / 2)
        return CGSize(width: min(limitX, max(-limitX, offset.width)),
                      height: min(limitY, max(-limitY, offset.height)))
    }
}

@MainActor
@Observable
final class FullScreenModel {
    enum Mode: Int, CaseIterable, Identifiable {
        case original = 1, uncorrected, corrected, compare
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .original: tr("Original")
            case .uncorrected: tr("Without correction")
            case .corrected: tr("With correction")
            case .compare: tr("Compare")
            }
        }
    }

    enum Command: Equatable {
        case mode(Mode), toggleSideBySide, toggleActualPixels, zoomIn, zoomOut, previous, next, toggleHUD, close
    }

    private(set) var photos: [URL]
    private(set) var index: Int
    var mode: Mode = .compare
    var sideBySide = false
    /// Points per image pixel; nil = fit the screen.
    private(set) var zoom: CGFloat?
    private(set) var offset: CGSize = .zero
    var divider = 0.5
    private(set) var hudVisible = true
    private(set) var hudEnabled = true
    /// The reduced preview, shown at once.
    private(set) var preview: PreviewService.Preview?
    /// Full-resolution layers, arriving one by one (the one on screen first).
    private(set) var fullLayers: [PreviewSession.FullLayer: CGImage] = [:]
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// Full pixel size of the photo (oriented): the reduced preview shown first is drawn at this size.
    private(set) var imageSize: CGSize = .zero
    /// The size of the view, set by the view.
    var area: CGSize = .zero {
        didSet { offset = clamped(offset) }
    }

    @ObservationIgnored var backingScale: CGFloat = 2
    @ObservationIgnored var screen: NSScreen?
    @ObservationIgnored var pointerOnHUD = false
    /// Off in the snapshots, so that the indications stay visible.
    @ObservationIgnored var autoHidesHUD = true
    @ObservationIgnored var onClose: (() -> Void)?

    private let settings: AppSettings
    @ObservationIgnored private weak var selection: PhotoSelection?
    /// Full-resolution stages: the last two photos only (each can take hundreds of MB).
    private let fullSession = PreviewSession(corrections: 2, transforms: 2, renders: 2)
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var hudTask: Task<Void, Never>?
    @ObservationIgnored private var lastActivity = Date()

    init(photos: [URL], current: URL?, settings: AppSettings, selection: PhotoSelection?) {
        self.photos = photos
        self.index = current.flatMap { photos.firstIndex(of: $0) } ?? 0
        self.settings = settings
        self.selection = selection
    }

    var currentPhoto: URL? { photos.indices.contains(index) ? photos[index] : nil }

    /// The layers the current view shows.
    var neededLayers: [PreviewSession.FullLayer] {
        switch mode {
        case .original: [.original]
        case .uncorrected: [.uncorrected]
        case .corrected: [.corrected]
        case .compare: [.corrected, .uncorrected]
        }
    }

    /// The full-resolution layer when ready, else the reduced preview's.
    func image(_ layer: PreviewSession.FullLayer) -> CGImage? {
        if let full = fullLayers[layer] { return full }
        guard let preview else { return nil }
        switch layer {
        case .original: return preview.original
        case .uncorrected: return preview.uncorrected
        case .corrected: return preview.corrected
        }
    }

    var hasImage: Bool { neededLayers.allSatisfy { image($0) != nil } }
    var isFullResolution: Bool { neededLayers.allSatisfy { fullLayers[$0] != nil } }

    // MARK: Geometry

    var paneArea: CGSize {
        mode == .compare && sideBySide ? CGSize(width: area.width / 2, height: area.height) : area
    }

    var effectiveImageSize: CGSize {
        if imageSize.width > 0, imageSize.height > 0 { return imageSize }
        if let preview { return CGSize(width: preview.original.width, height: preview.original.height) }
        return .zero
    }

    var fitScale: CGFloat { FullScreenGeometry.fitScale(image: effectiveImageSize, in: paneArea) }
    var actualPixels: CGFloat { FullScreenGeometry.actualPixelsScale(backingScale: backingScale) }
    var scale: CGFloat { zoom ?? fitScale }

    var displaySize: CGSize {
        CGSize(width: effectiveImageSize.width * scale, height: effectiveImageSize.height * scale)
    }

    /// Zoom in percent of the image's own pixels (100 = one image pixel per screen pixel).
    var zoomPercent: Int { Int((scale / actualPixels * 100).rounded()) }

    private func clamped(_ value: CGSize) -> CGSize {
        FullScreenGeometry.clampedOffset(value, display: displaySize, area: paneArea)
    }

    /// Sets the zoom. With `snapToFit`, a value close to the fitted size returns to "fit".
    func setScale(_ value: CGFloat, snapToFit: Bool = false) {
        let upper = actualPixels * 8
        let lower = min(fitScale, actualPixels)
        let next = min(upper, max(lower, value))
        if abs(next - fitScale) < fitScale * 0.02, snapToFit || zoom == nil {
            zoom = nil
        } else {
            zoom = next
        }
        offset = clamped(offset)
    }

    func setOffset(_ value: CGSize) { offset = clamped(value) }

    func pan(by delta: CGSize) {
        setOffset(CGSize(width: offset.width + delta.width, height: offset.height + delta.height))
    }

    // MARK: Commands

    /// The command of a key press; nil for keys the view does not use (and for any key with
    /// Command, Control or Option, which are left to the menus).
    static func command(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Command? {
        if !modifiers.intersection([.command, .control, .option]).isEmpty { return nil }
        switch keyCode {
        case 53: return .close          // Esc
        case 123: return .previous      // left arrow
        case 124: return .next          // right arrow
        default: break
        }
        switch characters?.lowercased() {
        case "1": return .mode(.original)
        case "2": return .mode(.uncorrected)
        case "3": return .mode(.corrected)
        case "4": return .mode(.compare)
        case "s": return .toggleSideBySide
        case "z": return .toggleActualPixels
        case "+", "=": return .zoomIn
        case "-": return .zoomOut
        case "i": return .toggleHUD
        default: return nil
        }
    }

    func handle(_ command: Command) {
        switch command {
        case .mode(let next):
            mode = next
        case .toggleSideBySide:
            if mode == .compare { sideBySide.toggle() } else { mode = .compare; sideBySide = true }
        case .toggleActualPixels:
            if zoom == nil { setScale(actualPixels) } else { zoom = nil }
        case .zoomIn:
            setScale(scale * 1.5)
        case .zoomOut:
            setScale(scale / 1.5, snapToFit: true)
        case .previous:
            select(index - 1)
        case .next:
            select(index + 1)
        case .toggleHUD:
            hudEnabled.toggle()
            hudVisible = hudEnabled
            return
        case .close:
            close()
            return
        }
        offset = clamped(offset)
        activity()
    }

    func select(_ newIndex: Int) {
        guard photos.indices.contains(newIndex), newIndex != index else { return }
        index = newIndex
        load()
    }

    func close() { onClose?() }

    // MARK: Indications

    func activity() {
        lastActivity = Date()
        if hudEnabled, !hudVisible { hudVisible = true }
    }

    private func hideIdleHUD() {
        guard autoHidesHUD, hudVisible, !pointerOnHUD, Date().timeIntervalSince(lastActivity) > 2 else { return }
        hudVisible = false
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    var statusLine: String {
        var parts: [String] = []
        if let url = currentPhoto { parts.append(url.lastPathComponent) }
        parts.append(mode == .compare && sideBySide ? tr("Compare side by side") : mode.title)
        parts.append(zoom == nil ? trf("Fit (%d%%)", zoomPercent) : trf("Zoom %d%%", zoomPercent))
        parts.append(settings.renderingIntent.title)
        if let errorMessage {
            parts.append(errorMessage)
        } else if isFullResolution {
            parts.append(trf("%d × %d px, full resolution", Int(imageSize.width), Int(imageSize.height)))
        } else if isLoading || preview != nil {
            parts.append(tr("Computing the full resolution…"))
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Loading

    func start() {
        load()
        hudTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.hideIdleHUD()
            }
        }
    }

    func stop() {
        cancelFlag?.set()
        loadTask?.cancel()
        hudTask?.cancel()
        fullSession.removeAll()
    }

    private func printerProfile() throws -> Data {
        guard let url = try settings.resolveProfileURL() else {
            throw ColorCorrectionService.CorrectionError.profileLoad(tr("Choose the ICC profile to see the preview."))
        }
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }

    /// Shows the reduced preview at once (usually already computed by the preview panel), then
    /// the full-resolution layers, the one on screen first.
    func load() {
        cancelFlag?.set()
        loadTask?.cancel()
        guard let url = currentPhoto else { return }
        if let selection, selection.selected != url { selection.selected = url }
        preview = nil
        fullLayers = [:]
        errorMessage = nil
        zoom = nil
        offset = .zero
        isLoading = true
        imageSize = ImageInfo.orientedPixelSize(of: url) ?? .zero

        let printerICC: Data
        do {
            printerICC = try printerProfile()
        } catch {
            errorMessage = trf("Unable to access the ICC profile: %@", error.localizedDescription)
            isLoading = false
            return
        }
        let display = PreviewService.Display.current(for: screen ?? NSScreen.main)
        let options: PreviewService.Options = {
            var options = PreviewService.Options(intent: settings.renderingIntent, blackPointCompensation: settings.blackPointCompensation)
            options.simulatePaperWhite = settings.simulatePaperWhite
            options.previewBlackPointCompensation = settings.previewMonitorBlack
            return options
        }()
        let fullSession = fullSession
        let loadID = UUID()
        currentLoad = loadID

        loadTask = Task { [weak self] in
            let quick = try? await Task.detached(priority: .userInitiated) {
                try PreviewSession.shared.makePreview(sourceURL: url, printerICC: printerICC, display: display, options: options)
            }.value
            guard let self, !Task.isCancelled else { return }
            if let quick { self.preview = quick }
            // A short pause: browsing quickly does not start a full-resolution computation per photo.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let order = self.layerOrder()
            let cancelled = CancellationFlag()
            self.cancelFlag = cancelled
            do {
                try await Task.detached(priority: .userInitiated) {
                    try fullSession.fullResolutionLayers(
                        sourceURL: url, printerICC: printerICC, display: display, options: options, order: order,
                        isCancelled: { cancelled.isSet },
                        deliver: { layer, image in
                            Task { @MainActor in
                                guard self.currentLoad == loadID else { return }
                                self.fullLayers[layer] = image
                                self.imageSize = CGSize(width: image.width, height: image.height)
                                self.offset = self.clamped(self.offset)
                            }
                        })
                }.value
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = trf("Full resolution unavailable: %@", error.localizedDescription)
            }
            guard self.currentLoad == loadID else { return }
            self.isLoading = false
        }
    }

    @ObservationIgnored private var currentLoad: UUID?
    @ObservationIgnored private var cancelFlag: CancellationFlag?

    /// The layers on screen first, then the others.
    private func layerOrder() -> [PreviewSession.FullLayer] {
        // The original is cheap (no correction): right after the layers on screen.
        let all: [PreviewSession.FullLayer] = [.original, .corrected, .uncorrected]
        return neededLayers + all.filter { !neededLayers.contains($0) }
    }
}

/// A flag a background computation checks between steps.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// A borderless window that can take the keyboard.
final class FullScreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Opens and closes the full-screen window on the screen of the main window.
@MainActor
final class FullScreenController {
    static let shared = FullScreenController()

    private var window: FullScreenWindow?
    private var model: FullScreenModel?
    private var monitors: [Any] = []
    private var savedPresentation: NSApplication.PresentationOptions = []

    var isOpen: Bool { window != nil }

    func toggle(settings: AppSettings, selection: PhotoSelection) {
        if isOpen { close() } else { open(settings: settings, selection: selection) }
    }

    func open(settings: AppSettings, selection: PhotoSelection) {
        guard window == nil, !selection.photos.isEmpty,
              let screen = NSApp.mainWindow?.screen ?? NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        let model = FullScreenModel(photos: selection.photos, current: selection.selected, settings: settings, selection: selection)
        model.screen = screen
        model.backingScale = screen.backingScaleFactor
        model.onClose = { [weak self] in self?.close() }

        let window = FullScreenWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(srgbRed: 0x77 / 255.0, green: 0x77 / 255.0, blue: 0x77 / 255.0, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.acceptsMouseMovedEvents = true
        window.contentView = NSHostingView(rootView: FullScreenView(model: model).environment(settings))
        window.setFrame(screen.frame, display: true)

        // Hide the menu bar and the Dock, unless a window is already in macOS full screen (there
        // they are hidden anyway, and changing the options is not allowed).
        savedPresentation = NSApp.presentationOptions
        if !NSApp.windows.contains(where: { $0.styleMask.contains(.fullScreen) }) {
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        }
        window.makeKeyAndOrderFront(nil)

        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleScroll(event) ?? false }
            return handled ? nil : event
        }) {
            monitors.append(monitor)
        }

        self.window = window
        self.model = model
        model.start()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, let model,
              let command = FullScreenModel.command(
                characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)) else { return false }
        model.handle(command)
        return true
    }

    /// Scrolling (trackpad or wheel) moves a zoomed photo.
    private func handleScroll(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, let model else { return false }
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        model.pan(by: CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor))
        model.activity()
        return true
    }

    func close() {
        guard let window else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        model?.stop()
        NSApp.presentationOptions = savedPresentation
        window.orderOut(nil)
        window.close()
        self.window = nil
        self.model = nil
    }
}

/// The content of the full-screen window.
struct FullScreenView: View {
    @Bindable var model: FullScreenModel
    @State private var dragBase: CGSize?
    @State private var magnifyBase: CGFloat?

    private static let middleGrey = ThemePalette.darktableGrey(0x77)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Self.middleGrey
                content
                if model.hudVisible {
                    hud.transition(.opacity)
                }
            }
            .onAppear { model.area = geometry.size }
            .onChange(of: geometry.size) { model.area = geometry.size }
        }
        .ignoresSafeArea()
        .onContinuousHover { _ in model.activity() }
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    if magnifyBase == nil { magnifyBase = model.scale }
                    model.setScale((magnifyBase ?? model.scale) * value.magnification, snapToFit: true)
                    model.activity()
                }
                .onEnded { _ in magnifyBase = nil }
        )
        .animation(.easeInOut(duration: 0.2), value: model.hudVisible)
    }

    @ViewBuilder
    private var content: some View {
        if model.hasImage {
            switch model.mode {
            case .original:
                pane { layer(.original) }
            case .uncorrected:
                pane { layer(.uncorrected) }
            case .corrected:
                pane { layer(.corrected) }
            case .compare:
                if model.sideBySide {
                    HStack(spacing: 0) {
                        pane { layer(.uncorrected) }
                            .overlay(alignment: .top) { caption(tr("Without correction")) }
                        pane { layer(.corrected) }
                            .overlay(alignment: .top) { caption(tr("With correction")) }
                    }
                } else if let before = model.image(.uncorrected), let after = model.image(.corrected) {
                    // Dragging moves the divider here; scrolling moves a zoomed photo.
                    pane(pans: false) {
                        ComparisonSlider(before: before, after: after, fraction: $model.divider)
                    }
                }
            }
        } else if let message = model.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.white)
                .padding(12)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        } else {
            ProgressView().controlSize(.large)
        }
    }

    @ViewBuilder
    private func layer(_ layer: PreviewSession.FullLayer) -> some View {
        if let image = model.image(layer) { self.image(image) }
    }

    private func image(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            // From 100% up, show the pixels as they are instead of smoothing them.
            .interpolation(model.scale >= model.actualPixels * 0.999 ? .none : .high)
    }

    private func pane<Content: View>(pans: Bool = true, @ViewBuilder _ content: () -> Content) -> some View {
        let area = model.paneArea
        let size = model.displaySize
        return content()
            .frame(width: max(1, size.width), height: max(1, size.height))
            .offset(model.offset)
            .frame(width: max(1, area.width), height: max(1, area.height))
            .clipped()
            .contentShape(Rectangle())
            .gesture(panGesture, including: pans ? .all : .subviews)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragBase == nil { dragBase = model.offset }
                let base = dragBase ?? .zero
                model.setOffset(CGSize(width: base.width + value.translation.width, height: base.height + value.translation.height))
                model.activity()
            }
            .onEnded { _ in dragBase = nil }
    }

    @ViewBuilder
    private func caption(_ text: String) -> some View {
        if model.hudVisible {
            Text(text)
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(.top, 16)
        }
    }

    private var hud: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { model.close() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 26))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
                .help(tr("Close (Esc)"))
                .padding(18)
            }
            Spacer()
            VStack(spacing: 8) {
                if model.photos.count > 1 { thumbnails }
                HStack(spacing: 8) {
                    if model.isLoading { ProgressView().controlSize(.small) }
                    Text(model.statusLine)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Text(tr("1 Original · 2 Without correction · 3 With correction · 4 Compare · S side by side · Z fit/100% · +/− zoom · ←/→ photos · I hide · Esc close"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(12)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            .onHover { model.pointerOnHUD = $0 }
            .padding(.horizontal, 40)
            .padding(.bottom, 18)
        }
    }

    /// Thumbnails of the photo list: a click shows that photo.
    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(model.photos.enumerated()), id: \.offset) { index, url in
                        ThumbnailView(url: url, side: 60)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(index == model.index ? Color.white : Color.clear, lineWidth: 2)
                            )
                            .opacity(index == model.index ? 1 : 0.7)
                            .contentShape(Rectangle())
                            .onTapGesture { model.select(index) }
                            .help(url.lastPathComponent)
                            .id(index)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .frame(width: min(CGFloat(model.photos.count) * 66 + 8, 900), height: 66)
            .onAppear { proxy.scrollTo(model.index, anchor: .center) }
            .onChange(of: model.index) {
                withAnimation { proxy.scrollTo(model.index, anchor: .center) }
            }
        }
    }
}
