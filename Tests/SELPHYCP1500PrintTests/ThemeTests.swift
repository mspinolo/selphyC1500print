import AppKit
import SwiftUI
import SELPHYColorCore
import XCTest
@testable import SELPHYCP1500Print

@MainActor
final class ThemeTests: XCTestCase {
    private func grey(_ color: Color) throws -> (r: Int, g: Int, b: Int) {
        let ns = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        return (Int((ns.redComponent * 255).rounded()), Int((ns.greenComponent * 255).rounded()), Int((ns.blueComponent * 255).rounded()))
    }

    func testThemeIsRememberedAndFollowsTheSystemByDefault() throws {
        let suite = "selphy-theme-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppSettings(defaults: defaults).theme, .system)
        AppSettings(defaults: defaults).theme = .neutralGrey
        XCTAssertEqual(AppSettings(defaults: defaults).theme, .neutralGrey)
    }

    func testAppearanceOfEachTheme() {
        XCTAssertNil(AppTheme.system.appearanceName)
        XCTAssertEqual(AppTheme.light.appearanceName, .aqua)
        XCTAssertEqual(AppTheme.dark.appearanceName, .darkAqua)
        XCTAssertEqual(AppTheme.neutralGrey.appearanceName, .darkAqua, "light text on grey, as in darktable")
        XCTAssertFalse(AppTheme.system.palette.paintsBackgrounds)
        XCTAssertTrue(AppTheme.neutralGrey.palette.paintsBackgrounds)
        XCTAssertNil(AppTheme.dark.palette.tint)
    }

    /// The values of darktable 5.6's grey theme, and a really neutral middle grey behind the photo.
    func testNeutralGreyMatchesDarktableAndIsMiddleGrey() throws {
        let palette = AppTheme.neutralGrey.palette
        let surround = try grey(palette.imageSurround)
        XCTAssertEqual(surround.r, 0x77)
        XCTAssertEqual(surround.g, 0x77)
        XCTAssertEqual(surround.b, 0x77)
        XCTAssertEqual(try grey(palette.windowBackground).r, 0x6A)
        XCTAssertEqual(try grey(palette.panelBackground).r, 0x6A)
        XCTAssertEqual(try grey(palette.selection).r, 0x84)
        for color in [palette.windowBackground, palette.panelBackground, palette.imageSurround, palette.selection, palette.highlight] {
            let c = try grey(color)
            XCTAssertTrue(c.r == c.g && c.g == c.b, "not neutral: \(c)")
        }
        if let tint = palette.tint {
            let c = try grey(tint)
            XCTAssertTrue(c.r == c.g && c.g == c.b, "tint not neutral: \(c)")
        } else {
            XCTFail("the grey theme must not use the accent colour")
        }

        var rgb: [UInt16] = [0x77 * 257, 0x77 * 257, 0x77 * 257]
        var lab: [Double] = [0, 0, 0]
        XCTAssertEqual(selphy_source_to_lab(nil, 0, &rgb, &lab, 1), SELPHY_OK)
        XCTAssertEqual(lab[0], 50, accuracy: 0.5, "surround L*")
        XCTAssertEqual(hypot(lab[1], lab[2]), 0, accuracy: 0.5, "surround chroma")
    }
}
