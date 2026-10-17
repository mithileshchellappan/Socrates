import SwiftUI

/// The small buttons of the drop HUD and the toasts (mockup 10's `.btn.sm`): a 12 pt medium label,
/// 9 pt side padding, 22 pt high, on the quiet fill with 6 pt corners. One style for the toast's
/// Undo and Change… and the HUD's Change…, so they cannot drift apart.
struct FilingSmallButtonStyle: ButtonStyle {
    var isHighlighted = false

    func makeBody(configuration: Configuration) -> some View {
        FilingSmallButtonBody(configuration: configuration, isHighlighted: isHighlighted)
    }
}

private struct FilingSmallButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isHighlighted: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .filingSmallButtonChrome(isHighlighted: isHighlighted)
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.4))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

extension View {
    /// The small button's look on any label: the HUD's Change… is a place to drop on, not a
    /// button, and wears it too. Highlighted: the accent at 22 % (a drop target under the cursor).
    func filingSmallButtonChrome(isHighlighted: Bool = false) -> some View {
        font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(
                isHighlighted ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.fill),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .fixedSize()
    }
}

/// "↶ Undo": a 10 pt semibold arrow 4 pt before the word (mockup 10).
struct UndoLabel: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            Text("Undo")
        }
    }
}

/// SF Mono inside a 12 pt line ("Recording 6.m4a · 44:34"): 11 pt, as the mockup's `.mono`
/// at .93 em, so the digits are no heavier than the name beside them.
enum FilingFont {
    static let inlineMono = Font.system(size: 11, design: .monospaced)
}
