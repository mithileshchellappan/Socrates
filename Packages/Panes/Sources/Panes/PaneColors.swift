#if os(macOS)
import AppKit
import StudyUI

/// The panes' AppKit colours (docs/DESIGN.md 3.1), light and dark: the headers, dividers and the
/// floating panel here draw with AppKit.
enum PaneColors {
    /// The panel surface: StudyUI's `PanelSurface` (which the chat's SwiftUI views fill with) for
    /// AppKit drawing, in the appearance it is drawn in.
    static let surface = NSColor(name: nil) { appearance in
        let rgb = PanelSurface.rgb(isDark: isDark(appearance))
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
    /// Fill 2 (`--fill2`): the header buttons' hover.
    static let hoverFill = dynamic(light: NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.17),
                                   dark: NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.30))
    /// Accent soft: the lit drop target.
    static let accentSoft = NSColor(name: "Socrates.panes.accentSoft") { appearance in
        NSColor.controlAccentColor.withAlphaComponent(isDark(appearance) ? 0.24 : 0.12)
    }
    /// The floating panel's 0.5 pt ring: black 12 % / white 14 %.
    static let panelRing = dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.14))
    /// The floating panel's shadow (`--panel-shadow`).
    static let panelShadow = dynamic(light: NSColor(srgbRed: 20 / 255, green: 30 / 255, blue: 50 / 255, alpha: 0.38),
                                     dark: NSColor(white: 0, alpha: 0.7))

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// `color` as a CGColor in `appearance` (layers do not resolve dynamic colours themselves).
    static func cgColor(_ color: NSColor, in appearance: NSAppearance) -> CGColor {
        var resolved = color.cgColor
        appearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { isDark($0) ? dark : light }
    }
}
#endif
