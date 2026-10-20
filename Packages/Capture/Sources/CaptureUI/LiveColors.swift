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

    /// The live window's canvas behind the slide, the filing line and the toolbar (the mockups'
    /// win2, #f6f6f8 and #252528 in dark mode): a shade off the inspector, so the two columns read
    /// as two zones.
    static let liveCanvasBackground = dynamic(light: (0xf6, 0xf6, 0xf8), dark: (0x25, 0x25, 0x28), name: "Socrates.liveCanvas")

    /// The live inspector: a flat, opaque panel a shade off the window background, like the
    /// canvas beside it (the mockups' inspector colour, #f8f8fa and #222225 in dark mode). The
    /// system's own inspector is glass, which shows the main column through it and tints in dark
    /// mode; `.background` inside an inspector resolves to an elevated grey (#4b4a4a dark).
    static let inspectorBackground = dynamic(light: (0xf8, 0xf8, 0xfa), dark: (0x22, 0x22, 0x25), name: "Socrates.liveInspector")

    /// One sRGB colour in light appearance, another in dark.
    private static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int), name: String) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        })
        #else
        return Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        })
        #endif
    }
}

/// A 0.5 pt hairline (one device pixel) in the separator colour: the mockups' section breaks.
/// `Divider` draws a 1 pt line, twice as heavy.
struct Hairline: View {
    @Environment(\.pixelLength) private var pixelLength

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: pixelLength)
            .accessibilityHidden(true)
    }
}
