import SwiftUI

extension EnvironmentValues {
    /// Off-screen snapshots cannot draw Liquid Glass (the window server composites it), so tests
    /// switch this on to see the cards' extent and text colours. Never set by the app.
    @Entry var filingDrawsOpaqueGlass = false
}

extension View {
    /// The system Liquid Glass card the HUD and the toasts sit on.
    func filingGlass(cornerRadius: CGFloat = 16) -> some View {
        modifier(FilingGlass(cornerRadius: cornerRadius))
    }
}

struct FilingGlass: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.filingDrawsOpaqueGlass) private var opaque

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if opaque {
            content
                .background(.background.opacity(0.94), in: shape)
                .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 16, y: 10)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}
