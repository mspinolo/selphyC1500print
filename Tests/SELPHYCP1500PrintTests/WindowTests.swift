import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import SELPHYCP1500Print

@MainActor
final class WindowTests: XCTestCase {
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    func writeImage(named name: String, in folder: URL, width: Int = 1200, height: Int = 800, hue: CGFloat = 0.55,
                    type: UTType = .png) throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let sky = try XCTUnwrap(CGGradient(colorsSpace: sRGB, colors: [
            NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor,
            NSColor(hue: hue + 0.08, saturation: 0.25, brightness: 1, alpha: 1).cgColor] as CFArray, locations: [0, 1]))
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: height), end: .zero, options: [])
        context.setFillColor(NSColor(hue: 0.33, saturation: 0.6, brightness: 0.5, alpha: 1).cgColor)
        context.move(to: CGPoint(x: 0, y: 0))
        context.addLine(to: CGPoint(x: 0, y: height / 3))
        context.addLine(to: CGPoint(x: width / 3, y: height / 2))
        context.addLine(to: CGPoint(x: width * 2 / 3, y: height / 4))
        context.addLine(to: CGPoint(x: width, y: height / 3))
        context.addLine(to: CGPoint(x: width, y: 0))
        context.fillPath()
        context.setFillColor(NSColor(hue: 0.11, saturation: 0.8, brightness: 1, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: width * 3 / 4, y: height * 3 / 4 - 60, width: 120, height: 120))
        let image = try XCTUnwrap(context.makeImage())
        let url = folder.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selphy-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    // MARK: Photo files and thumbnails

    func testSupportedPhotoFilesAreRecognisedWhateverTheCase() {
        for name in ["a.jpg", "a.JPEG", "a.png", "a.PNG", "a.tif", "a.TIFF", "a.jxl"] {
            XCTAssertTrue(PhotoFiles.isSupported(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["a.gif", "a.pdf", "a.txt", "a", "a.heic.zip"] {
            XCTAssertFalse(PhotoFiles.isSupported(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }

    func testThumbnailIsSmallKeepsTheAspectRatioAndFailsGracefully() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try writeImage(named: "wide.png", in: folder, width: 1200, height: 800)
        let thumbnail = try XCTUnwrap(Thumbnail.make(url: url, maxPixel: 132))
        XCTAssertEqual(max(thumbnail.width, thumbnail.height), 132)
        XCTAssertEqual(Double(thumbnail.width) / Double(thumbnail.height), 1.5, accuracy: 0.05)
        XCTAssertNil(Thumbnail.make(url: folder.appendingPathComponent("missing.png"), maxPixel: 132))
        let notAnImage = folder.appendingPathComponent("x.png")
        try Data("nope".utf8).write(to: notAnImage)
        XCTAssertNil(Thumbnail.make(url: notAnImage, maxPixel: 132))
    }

    func testScaledFallbackKeepsTheAspectRatioAndNeverEnlarges() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try writeImage(named: "big.png", in: folder, width: 1200, height: 800)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let full = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let small = try XCTUnwrap(Thumbnail.scaled(full, maxPixel: 120))
        XCTAssertEqual(small.width, 120)
        XCTAssertEqual(small.height, 80)
        let same = try XCTUnwrap(Thumbnail.scaled(full, maxPixel: 5000))
        XCTAssertEqual(same.width, 1200, "never enlarged")
    }

    func testThumbnailsOfJPEGFilesWithATaggedProfile() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try writeImage(named: "photo.jpg", in: folder, type: .jpeg)
        let thumbnail = try XCTUnwrap(Thumbnail.make(url: url, maxPixel: 132))
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 132)
    }

    func testAccessIsHeldPerPhotoAndReleased() throws {
        let access = PhotoAccess()
        let a = URL(fileURLWithPath: "/tmp/a.jpg"), b = URL(fileURLWithPath: "/tmp/b.jpg")
        access.retain(a); access.retain(a); access.retain(b)
        XCTAssertEqual(access.count, 2, "retaining twice holds one access")
        access.release(a)
        XCTAssertEqual(access.count, 1)
        access.releaseAll()
        XCTAssertEqual(access.count, 0)
    }

    // MARK: Icon

    func testAppIconIsInThePackagingFolderAndNamedInThePlist() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("Packaging/Info.plist")))
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")
        let icns = try Data(contentsOf: root.appendingPathComponent("Packaging/AppIcon.icns"))
        XCTAssertEqual(String(decoding: icns.prefix(4), as: UTF8.self), "icns")
        let image = try XCTUnwrap(NSImage(contentsOf: root.appendingPathComponent("Packaging/AppIcon.icns")))
        XCTAssertGreaterThanOrEqual(image.representations.map(\.pixelsWide).max() ?? 0, 1024)
    }

    // MARK: Snapshots (design review; only when SELPHY_SNAPSHOT_DIR is set, i.e. in CI)

    private func snapshot<V: View>(_ view: V, size: CGSize, name: String, dark: Bool = false, wait: TimeInterval = 4, to folder: URL) throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // ARC owns the window; the default would free it twice
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        let end = Date().addingTimeInterval(wait)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("\(name).png"))
        window.close()
    }

    func testRenderWindowSnapshots() throws {
        guard let path = ProcessInfo.processInfo.environment["SELPHY_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SELPHY_SNAPSHOT_DIR to render the window snapshots")
        }
        let out = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let photos = try makeFolder()
        defer { try? FileManager.default.removeItem(at: photos) }
        let files = try [("IMG_0412.png", 0.55), ("IMG_0413.png", 0.08), ("Venezia-tramonto.png", 0.95), ("Ritratto_Anna.png", 0.75)]
            .map { try writeImage(named: $0.0, in: photos, hue: CGFloat($0.1)) }

        let suite = "selphy-snapshots-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.removeObject(forKey: "sidebarVisible")
            Localizer.shared.language = .english
        }
        let settings = AppSettings(defaults: defaults)
        if let profile = ProcessInfo.processInfo.environment["SELPHY_TEST_PRINTER_PROFILE"],
           FileManager.default.fileExists(atPath: profile) {
            try settings.chooseProfile(at: URL(fileURLWithPath: profile))
        }
        let size = CGSize(width: 980, height: 680)

        UserDefaults.standard.set(true, forKey: "sidebarVisible")
        try snapshot(ContentView().environmentObject(settings), size: size, name: "1-empty-en", wait: 1, to: out)
        try snapshot(ContentView(initialPhotos: files).environmentObject(settings), size: size, name: "2-photos-en", to: out)
        try snapshot(ContentView(initialPhotos: files).environmentObject(settings), size: size, name: "3-photos-en-dark", dark: true, to: out)
        UserDefaults.standard.set(false, forKey: "sidebarVisible")
        try snapshot(ContentView(initialPhotos: files).environmentObject(settings), size: size, name: "4-sidebar-hidden-en", to: out)
        UserDefaults.standard.set(true, forKey: "sidebarVisible")
        settings.language = .italian
        try snapshot(ContentView(initialPhotos: files).environmentObject(settings), size: size, name: "5-photos-it", to: out)
        try snapshot(SettingsView().environmentObject(settings), size: CGSize(width: 540, height: 520), name: "6-settings-it", wait: 1, to: out)
        settings.language = .english
        try snapshot(SettingsView().environmentObject(settings), size: CGSize(width: 540, height: 520), name: "7-settings-en", wait: 1, to: out)

        let written = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(written.count, 7)
    }
}
