import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The panel surface (the mockups' `--inspector`: #f8f8fa; #222225 in dark mode), opaque: the
/// agent's chat and the Mac's side panes, whose answers are content, never glass (docs/DESIGN.md
/// §3.1). AppKit drawing (the panes' headers, the floating panel) uses `NSColor.panelSurface`, the
/// same colour. CaptureUI's live inspector keeps its own copy (it does not depend on StudyUI).
public struct PanelSurface: ShapeStyle {
    static let light = CourseColor.RGB(0xf8f8fa)
    static let dark = CourseColor.RGB(0x222225)

    public init() {}

    public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        let rgb = environment.colorScheme == .dark ? Self.dark : Self.light
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue).resolve(in: environment)
    }
}

#if canImport(AppKit)
extension NSColor {
    /// `PanelSurface` for AppKit drawing, in the appearance it is drawn in.
    public static let panelSurface = NSColor(name: nil) { appearance in
        let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? PanelSurface.dark : PanelSurface.light
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}
#endif
