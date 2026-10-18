import SwiftUI

/// The mockups' quiet fill (`--fill`: rgb(120,120,128) at 10 % light, 20 % dark): neutral
/// selection (selected inspector rows, segmented knobs), Calendar's weekend columns. Not
/// `.quaternary`, which is another grey (docs/DESIGN.md §3.1).
public struct QuietFill: ShapeStyle {
    public init() {}

    public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255)
            .opacity(environment.colorScheme == .dark ? 0.20 : 0.10)
            .resolve(in: environment)
    }
}

/// A 0.5 pt separator line inside content (`Divider` is twice as heavy: use it between columns).
public struct Hairline: View {
    @Environment(\.pixelLength) private var pixelLength
    private let axis: Axis

    public init(_ axis: Axis = .horizontal) {
        self.axis = axis
    }

    public var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: axis == .vertical ? max(pixelLength, 0.5) : nil, height: axis == .horizontal ? max(pixelLength, 0.5) : nil)
            .accessibilityHidden(true)
    }
}

extension Color {
    /// The canvas surface (`--win2`: #f6f6f8; #252528 in dark mode): behind a note's sketch (M6).
    /// CaptureUI's live window keeps its own `liveCanvasBackground` (it does not depend on StudyUI).
    public static func canvasBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 0x25 / 255, green: 0x25 / 255, blue: 0x28 / 255)
            : Color(.sRGB, red: 0xf6 / 255, green: 0xf6 / 255, blue: 0xf8 / 255)
    }

    /// The highlighter (`--ink-hl`: yellow at 45 %, 40 % in dark mode): highlights in notes,
    /// search matches, the highlighter's ink.
    public static func highlighter(_ scheme: ColorScheme) -> Color {
        Color(.sRGB, red: 1, green: 214 / 255, blue: 10 / 255, opacity: scheme == .dark ? 0.40 : 0.45)
    }

    /// The window's content surface (`--win`: white; #1e1e20 in dark mode): Calendar's grid and
    /// composer field (course tints are mixed over it so events stay opaque over lines and weekend
    /// fills). CaptureUI keeps its own copy (it does not depend on StudyUI; docs/DESIGN.md §7.4).
    public static var contentBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}
