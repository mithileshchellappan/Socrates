import StudyUI
import SwiftUI

/// The panel's controls (DESIGN 8.11, the Live Activity's row): 34 pt capsules, 13 pt semibold.
/// A button whose command waits for the phone's answer stays pressed in (`isHeld`: the darker
/// fill, its label secondary), never a spinner; a disabled one is the quiet fill with a tertiary
/// label.
struct RemoteButtonStyle: ButtonStyle {
    enum Kind {
        /// Pause: the quiet fill.
        case quiet
        /// Resume: the accent on its tint.
        case resume
        /// Next Slide: the accent, filled.
        case prominent
        /// Stop…: red on red soft.
        case stop
    }

    let kind: Kind
    let isHeld: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(height: 34)
            .background(background, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed && !isHeld ? 0.8 : 1)
    }

    private var foreground: AnyShapeStyle {
        if isHeld { return AnyShapeStyle(.secondary) }
        guard isEnabled else { return AnyShapeStyle(.tertiary) }
        switch kind {
        case .quiet: return AnyShapeStyle(.primary)
        case .resume: return AnyShapeStyle(Color.accentColor)
        case .prominent: return AnyShapeStyle(Color.white)
        case .stop: return AnyShapeStyle(Color.red)
        }
    }

    private var background: AnyShapeStyle {
        let isDark = colorScheme == .dark
        if isHeld {
            // `--fill3`, pressed in.
            return AnyShapeStyle(
                Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255)
                    .opacity(isDark ? 0.42 : 0.26)
                    .shadow(.inner(color: .black.opacity(0.18), radius: 1, y: 1))
            )
        }
        guard isEnabled else { return AnyShapeStyle(QuietFill()) }
        switch kind {
        case .quiet: return AnyShapeStyle(QuietFill())
        case .resume: return AnyShapeStyle(Color.accentColor.opacity(isDark ? 0.24 : 0.14))
        case .prominent: return AnyShapeStyle(Color.accentColor)
        case .stop: return AnyShapeStyle(Color.red.opacity(isDark ? 0.20 : 0.12))
        }
    }
}
