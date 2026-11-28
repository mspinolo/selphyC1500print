import Foundation

/// The four test pictures that come with the app, one per role of the physical test (skin tones,
/// foliage and sky, dark tones, neutral greys), rendered by `scripts/make-test-photos.py`:
/// synthetic, so free of rights and with every tone known. 1800 x 1200 pixels (6 x 4 in at
/// 300 ppi), sRGB PNG with an embedded profile.
enum BuiltInTestPhotos {
    static func fileName(for role: PhotoRole) -> String {
        switch role {
        case .portrait: "portrait-skin-tones.png"
        case .foliageSky: "foliage-sky.png"
        case .lowKey: "low-key.png"
        case .blackAndWhite: "black-and-white.png"
        }
    }

    /// `Contents/Resources/TestPhotos` in the app; in a build from the sources (`swift run`,
    /// tests) the `Packaging/TestPhotos` folder of the repository.
    static var folder: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("TestPhotos", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent(fileName(for: .portrait)).path) {
            return bundled
        }
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packaging/TestPhotos", isDirectory: true)
        return FileManager.default.fileExists(atPath: sources.appendingPathComponent(fileName(for: .portrait)).path) ? sources : nil
    }

    static func url(for role: PhotoRole) -> URL? {
        folder.map { $0.appendingPathComponent(fileName(for: role)) }
    }

    static var available: Bool { PhotoRole.allCases.allSatisfy { role in url(for: role).map { FileManager.default.fileExists(atPath: $0.path) } ?? false } }
}
