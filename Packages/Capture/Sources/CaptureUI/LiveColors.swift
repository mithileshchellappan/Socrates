import SwiftUI

/// The accent at 12 % (light) or 24 % (dark), as the mockups' accent-soft: the highlighted
/// caption and stamp rows and the time chips. A fixed 12 % nearly disappears in dark mode.
struct AccentSoftStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        Color.accentColor.opacity(environment.colorScheme == .dark ? 0.24 : 0.12)
    }
}

extension ShapeStyle where Self == AccentSoftStyle {
    static var accentSoft: AccentSoftStyle { AccentSoftStyle() }
}

extension Color {
    /// Caption text still settling, and the dotted underline of unsure words: lighter than
    /// secondary.
    static var tertiaryLabel: Color {
        #if os(macOS)
        Color(nsColor: .tertiaryLabelColor)
        #else
        Color(uiColor: .tertiaryLabel)
        #endif
    }

    /// The window's content colour (white; near black in dark mode). The filmstrip uses it, so
    /// it sits lighter than the canvas in light mode and darker in dark mode.
    static var contentBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// The live inspector: a flat, opaque panel a shade off the window background, like the
    /// canvas beside it (the mockups' inspector colour, #f8f8fa and #222225 in dark mode). The
    /// system's own inspector is glass, which shows the main column through it and tints in dark
    /// mode; `.background` inside an inspector resolves to an elevated grey (#4b4a4a dark).
    static let inspectorBackground: Color = {
        let light = (red: 0xf8, green: 0xf8, blue: 0xfa)
        let dark = (red: 0x22, green: 0x22, blue: 0x25)
        #if os(macOS)
        return Color(nsColor: NSColor(name: "StudyPortal.liveInspector") { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
        })
        #else
        return Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
        })
        #endif
    }()
}
