import AppKit
import ImageIO

/// How the image is placed on the sheet.
enum PrintFit: String, CaseIterable, Identifiable, Sendable {
    case fit    // the whole image, possibly with white margins
    case fill   // covers the whole sheet, the overflow is cropped

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: tr("Fit the whole image")
        case .fill: tr("Fill the paper (crops the edges)")
        }
    }
}

enum PrintLayout {
    /// The rectangle, inside `bounds`, the image is drawn into (it may overflow for `.fill`).
    static func imageRect(imageSize: CGSize, in bounds: CGRect, fit: PrintFit) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scaleX = bounds.width / imageSize.width
        let scaleY = bounds.height / imageSize.height
        let scale = fit == .fit ? min(scaleX, scaleY) : max(scaleX, scaleY)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    static func orientation(for imageSize: CGSize) -> NSPrintInfo.PaperOrientation {
        imageSize.width > imageSize.height ? .landscape : .portrait
    }
}

/// Draws one image on one page. The image is drawn untouched: no resampling to a fixed size, no
/// colour adjustment. Colour matching to the printer is whatever the system print path does with
/// an sRGB-tagged image; this is what the physical validation (route equivalence) checks.
final class PrintImageView: NSView {
    let image: CGImage
    let fit: PrintFit

    init(image: CGImage, fit: PrintFit, size: CGSize) {
        self.image = image
        self.fit = fit
        super.init(frame: CGRect(origin: .zero, size: size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: bounds)
        context.interpolationQuality = .high
        let rect = PrintLayout.imageRect(
            imageSize: CGSize(width: image.width, height: image.height), in: bounds, fit: fit)
        context.draw(image, in: rect)
        context.restoreGState()
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: 1)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect { bounds }

    /// The paper and orientation are chosen in the print panel: size the page after the choice.
    override func beginDocument() {
        if let info = NSPrintOperation.current?.printInfo {
            setFrameSize(info.imageablePageBounds.size)
        }
        super.beginDocument()
    }
}

@MainActor
final class PrintService: ObservableObject {
    enum PrintError: LocalizedError {
        case unreadable(URL)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url): return trf("Cannot open %@ for printing.", url.lastPathComponent)
            }
        }
    }

    enum Outcome {
        case sent(Int)
        case cancelled(sentBefore: Int)
        case failed(Error)
    }

    /// Settings chosen in the panel are kept for the following sheets and the next print.
    private var printInfo = PrintService.defaultPrintInfo()
    private var runDelegate: RunDelegate?

    static func defaultPrintInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.scalingFactor = 1
        return info
    }

    static func loadImage(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PrintError.unreadable(url)
        }
        return image
    }

    static func makeOperation(for url: URL, fit: PrintFit, printInfo: NSPrintInfo, showsPanel: Bool) throws -> NSPrintOperation {
        let image = try loadImage(from: url)
        let info = (printInfo.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.orientation = PrintLayout.orientation(for: CGSize(width: image.width, height: image.height))
        let view = PrintImageView(image: image, fit: fit, size: info.imageablePageBounds.size)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = url.deletingPathExtension().lastPathComponent
        operation.showsPrintPanel = showsPanel
        operation.showsProgressPanel = true
        return operation
    }

    /// Prints the files one after the other. The panel is shown for the first sheet only; the
    /// paper size and options chosen there are reused for the others.
    func print(files: [URL], fit: PrintFit, in window: NSWindow?) async -> Outcome {
        var sent = 0
        for (index, url) in files.enumerated() {
            let operation: NSPrintOperation
            do {
                operation = try Self.makeOperation(for: url, fit: fit, printInfo: printInfo, showsPanel: index == 0)
            } catch {
                return .failed(error)
            }
            let succeeded = await run(operation, in: window)
            guard succeeded else { return .cancelled(sentBefore: sent) }
            printInfo = operation.printInfo
            sent += 1
        }
        return .sent(sent)
    }

    private func run(_ operation: NSPrintOperation, in window: NSWindow?) async -> Bool {
        guard let window else { return operation.run() }
        return await withCheckedContinuation { continuation in
            let delegate = RunDelegate { success in continuation.resume(returning: success) }
            runDelegate = delegate
            operation.runModal(
                for: window, delegate: delegate,
                didRun: #selector(RunDelegate.printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil)
        }
    }

    @MainActor
    final class RunDelegate: NSObject {
        private let completion: (Bool) -> Void

        init(completion: @escaping (Bool) -> Void) {
            self.completion = completion
        }

        @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            completion(success)
        }
    }
}
