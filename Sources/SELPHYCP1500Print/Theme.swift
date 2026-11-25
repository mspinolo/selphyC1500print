import AppKit
import SwiftUI

/// The interface theme. `neutralGrey` follows darktable's "elegant grey" theme (darktable 5.6,
/// data/themes/darktable-elegant-grey.css and darktable.css): mid-grey panels with light text and
/// a middle grey behind the image, so that the eye adapts to a neutral surround (L* 50) and the
/// colours and brightness of the photo are judged without the bias of a white or black frame.
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark, neutralGrey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: tr("Follow the system")
        case .light: tr("Light")
        case .dark: tr("Dark")
        case .neutralGrey: tr("Neutral grey (for judging colours)")
        }
    }

    var explanation: String {
        switch self {
        case .neutralGrey:
            tr("Mid-grey interface with a middle grey (L* 50) around the photo, as in darktable's grey theme: a neutral surround makes colours and brightness easier to judge. Controls are grey too, without the accent colour.")
        default:
            tr("For judging the colours of the photos, the neutral grey theme is more reliable than a light or dark interface.")
        }
    }

    /// The AppKit appearance of the whole app (windows, dialogs, print and save panels); nil =
    /// follow the system. The grey theme has light text, so it is built on the dark appearance.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark, .neutralGrey: .darkAqua
        }
    }

    var palette: ThemePalette {
        self == .neutralGrey ? .neutralGrey : .system
    }

    @MainActor
    static func apply(_ theme: AppTheme) {
        NSApp.appearance = theme.appearanceName.flatMap { NSAppearance(named: $0) }
    }
}

/// The colours the app paints itself (everything else comes from the system appearance).
struct ThemePalette: Sendable {
    /// Window and panes.
    var windowBackground: Color
    /// The photo list.
    var panelBackground: Color
    /// Behind the photo in the preview.
    var imageSurround: Color
    /// Selected row in the photo list.
    var selection: Color
    /// Outline of the drop target.
    var highlight: Color
    /// Tint of the controls; nil = the system accent colour.
    var tint: Color?
    /// Whether the app paints its own backgrounds over the system ones (forms, toolbar).
    var paintsBackgrounds: Bool

    /// The system look (light, dark or following macOS), as before themes existed.
    static let system = ThemePalette(
        windowBackground: Color(nsColor: .windowBackgroundColor),
        panelBackground: Color(nsColor: .controlBackgroundColor),
        imageSurround: Color(nsColor: .windowBackgroundColor),
        selection: Color.accentColor.opacity(0.18),
        highlight: Color.accentColor,
        tint: nil,
        paintsBackgrounds: false
    )

    /// darktable's grey scale (darktable.css): grey_NN in sRGB.
    static func darktableGrey(_ value: Int) -> Color {
        let v = Double(value) / 255
        return Color(.sRGB, red: v, green: v, blue: v, opacity: 1)
    }

    static let neutralGrey = ThemePalette(
        windowBackground: darktableGrey(0x6A),   // grey_45: bg_color, the general background
        panelBackground: darktableGrey(0x6A),    // grey_45
        imageSurround: darktableGrey(0x77),      // grey_50: darkroom_bg_color, "middle grey"
        selection: darktableGrey(0x84),          // grey_55: selected_bg_color
        highlight: darktableGrey(0xF1),          // grey_95: fg_color
        tint: darktableGrey(0x3B),               // grey_25: neutral, keeps white text readable
        paintsBackgrounds: true
    )
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = ThemePalette.system
}

extension EnvironmentValues {
    /// The palette of the current theme (set by the window roots).
    var palette: ThemePalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension View {
    /// Palette and control tint of `theme`, plus its toolbar background, for a window's root view.
    func themed(_ theme: AppTheme) -> some View {
        let palette = theme.palette
        return self
            .environment(\.palette, palette)
            .tint(palette.tint)
            .toolbarBackground(palette.windowBackground, for: .windowToolbar)
            .toolbarBackground(palette.paintsBackgrounds ? .visible : .automatic, for: .windowToolbar)
    }
}
