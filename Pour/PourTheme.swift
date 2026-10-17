import SwiftUI
import AppKit

/// Design tokens. Deliberately small: the system supplies type, spacing and
/// most colors, so the only thing Pour needs to own is its accent and the two
/// dimensions the floating panel is built around.
enum PourTheme {
    /// The single brand color. Used for the mark, the live audio meter, and
    /// tinting controls — never for body text or status.
    static let accent = Color(red: 0xE8 / 255, green: 0xA3 / 255, blue: 0x3D / 255)

    /// The foam above the liquid. A lighter amber rather than a transparent
    /// one — at 35% opacity the foam turned muddy brown against dark surfaces.
    static let foam = Color(red: 0xF6 / 255, green: 0xD3 / 255, blue: 0x9C / 255)
}
