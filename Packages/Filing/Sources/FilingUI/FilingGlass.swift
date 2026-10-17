import SwiftUI

extension EnvironmentValues {
    /// Off-screen snapshots cannot draw Liquid Glass (the window server composites it), so tests
    /// switch this on to see the cards' extent and text colours. Never set by the app.
    @Entry var filingDrawsOpaqueGlass = false
}

extension View {
    /// The lifted glass card the HUD and the toasts sit on.
    func filingGlass(cornerRadius: CGFloat = 16) -> some View {
        modifier(FilingGlass(cornerRadius: cornerRadius))
    }
}

/// Liquid Glass with body and lift (mockup 10): a frost over the glass so the page below does not
/// read through the text (white; in dark a grey lighter than the window), a hairline edge lit
/// along the top, and a pop shadow outside the card. The card's content sits on top of the glass,
/// not in it, so its text and button fills keep their own colours (no vibrancy).
struct FilingGlass: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.filingDrawsOpaqueGlass) private var opaque
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    /// The frost over the glass: mockup 10's glass colour, a little denser in light, where the
    /// glass itself greys the page.
    private var frost: Color {
        if isDark { return Color(red: 58 / 255, green: 58 / 255, blue: 62 / 255).opacity(opaque ? 1 : 0.62) }
        return Color.white.opacity(opaque ? 1 : 0.85)
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    PopShadow(shape: shape, isDark: isDark)
                    if !opaque {
                        shape.fill(.clear).glassEffect(.regular, in: shape)
                    }
                    shape.fill(frost)
                }
            }
            .overlay {
                // Hairline edge, lit along the top.
                shape.strokeBorder(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.1), lineWidth: 0.5)
                shape
                    .inset(by: 0.5)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(isDark ? 0.14 : 0.9), .white.opacity(0)],
                            startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.12)
                        ),
                        lineWidth: 1
                    )
            }
    }
}

/// The card's shadow, drawn only outside it (under the translucent card it would grey the frost):
/// 12 pt down, soft, a little narrower than the card.
private struct PopShadow<S: InsettableShape>: View {
    let shape: S
    let isDark: Bool

    var body: some View {
        shape
            .inset(by: 6)
            .fill(.black)
            .shadow(color: .black.opacity(isDark ? 0.6 : 0.3), radius: 16, y: 12)
            .mask {
                ZStack {
                    Rectangle().padding(-64)
                    shape.blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
