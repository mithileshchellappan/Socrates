import SwiftUI

/// The panel surface (the mockups' `--inspector`: #f8f8fa; #222225 in dark mode), opaque: the
/// agent's chat and the Mac's side panes, whose answers are content, never glass (docs/DESIGN.md
/// §3.1). AppKit drawing (the panes' headers, the floating panel) makes the same colour from
/// `rgb(isDark:)` in the platform UI package (Panes' `PaneColors.surface`). CaptureUI's live
/// inspector keeps its own copy (it does not depend on StudyUI).
public struct PanelSurface: ShapeStyle {
    static let light = CourseColor.RGB(0xf8f8fa)
    static let dark = CourseColor.RGB(0x222225)

    public init() {}

    /// The surface's sRGB components (0–1) in light or dark appearance.
    public static func rgb(isDark: Bool) -> (red: Double, green: Double, blue: Double) {
        let rgb = isDark ? dark : light
        return (rgb.red, rgb.green, rgb.blue)
    }

    public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        let rgb = environment.colorScheme == .dark ? Self.dark : Self.light
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue).resolve(in: environment)
    }
}
