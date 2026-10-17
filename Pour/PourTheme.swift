import SwiftUI
import AppKit

/// Design tokens. Deliberately small: the system supplies type, spacing and
/// most colors, so the only thing Pour needs to own is its accent, the warm
/// glow the bar is drawn in, and the few surfaces the window is built from.
enum PourTheme {
    /// The single brand color. Used for the mark, the live audio meter, and
    /// tinting controls — never for body text or status.
    static let accent = Color(red: 0xE8 / 255, green: 0xA3 / 255, blue: 0x3D / 255)

    /// The foam above the liquid. A lighter amber rather than a transparent
    /// one — at 35% opacity the foam turned muddy brown against dark surfaces.
    static let foam = Color(red: 0xF6 / 255, green: 0xD3 / 255, blue: 0x9C / 255)

    /// The bar's glow runs through these, warm to warmer. All of them sit
    /// next to amber on the wheel so the bar reads as Pour, not as Siri.
    static let ember = Color(red: 0xE4 / 255, green: 0x6A / 255, blue: 0x3A / 255)
    static let rose = Color(red: 0xEC / 255, green: 0x8B / 255, blue: 0x78 / 255)
    static let honey = Color(red: 0xF4 / 255, green: 0xC4 / 255, blue: 0x4E / 255)

    static let glow: [Color] = [accent, ember, rose, honey, foam, accent]

    // MARK: - Window surfaces

    /// Behind the sidebar, and the frame the content panel sits in.
    static let sidebar = dynamic(light: (0.953, 0.945, 0.929), dark: (0.098, 0.098, 0.102))
    /// The content panel.
    static let canvas = dynamic(light: (0.988, 0.984, 0.976), dark: (0.141, 0.141, 0.149))
    /// Grouped rows on the canvas.
    static let card = dynamic(light: (0.945, 0.937, 0.918), dark: (0.192, 0.192, 0.2))
    /// Buttons and keycaps sitting on a card.
    static let control = dynamic(light: (1, 1, 1), dark: (0.255, 0.255, 0.263))
    static let hairline = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.08)
                          : NSColor.black.withAlphaComponent(0.07)
    })

    private static func dynamic(light: (CGFloat, CGFloat, CGFloat),
                                dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
