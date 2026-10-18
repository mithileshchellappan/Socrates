import StudyCore
import SwiftUI

/// A pin that marks who speaks for a spot on a slide or in a line (docs/DESIGN.md §5.1, mockup
/// 03): you (accent, `person`), the professor (amber, `graduationcap.fill`) or AI (purple,
/// `sparkle`). Its card (`PinCard`) opens while the pointer rests on the pin or the card (macOS),
/// or on tap (iPad, iPhone).
///
/// `.slide` pins are 20 pt with a soft shadow and a 2 pt ring in the slide's white, drawn in an
/// overlay over the slide bitmap; `.inline` pins are the 16 pt marker inside text rows.
public struct AnnotationPin<Card: View>: View {
    public typealias Style = AnnotationPinStyle

    private let layer: AnnotationLayer
    private let style: Style
    private let presented: Binding<Bool>?
    private let keepsOpen: Bool
    private let card: Card
    @State private var ownPresented = false
    @State private var overPin = false
    @State private var overCard = false
    @State private var pending: Task<Void, Never>?

    /// - Parameters:
    ///   - isPresented: the card's state when the caller drives it (a pin just added opens for
    ///     typing); nil keeps it inside the pin.
    ///   - keepsOpen: the card stays when the pointer leaves (its text is being edited).
    ///   - card: the card's content, usually a `PinCard`.
    public init(
        _ layer: AnnotationLayer,
        style: Style = .slide,
        isPresented: Binding<Bool>? = nil,
        keepsOpen: Bool = false,
        @ViewBuilder card: () -> Card
    ) {
        self.layer = layer
        self.style = style
        presented = isPresented
        self.keepsOpen = keepsOpen
        self.card = card()
    }

    public var body: some View {
        AnnotationPinMark(layer, style: style)
            .contentShape(Circle())
            .onTapGesture { isPresented.wrappedValue.toggle() }
            #if os(macOS)
            .onHover { inside in
                overPin = inside
                settle()
            }
            #endif
            .popover(isPresented: isPresented, arrowEdge: .bottom) {
                card
                    #if os(macOS)
                    .onHover { inside in
                        overCard = inside
                        settle()
                    }
                    #endif
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isPresented.wrappedValue.toggle() }
    }

    private var isPresented: Binding<Bool> {
        presented ?? $ownPresented
    }

    /// Opens after a short rest on the pin, closes a moment after the pointer left both (not
    /// while the card is being edited).
    private func settle() {
        pending?.cancel()
        let wanted = overPin || overCard
        guard wanted != isPresented.wrappedValue, wanted || !keepsOpen else { return }
        pending = Task { @MainActor in
            try? await Task.sleep(for: wanted ? .milliseconds(350) : .milliseconds(250))
            guard !Task.isCancelled else { return }
            isPresented.wrappedValue = wanted
        }
    }
}

/// How big a pin is and where it sits: on a slide (20 pt, shadow, white ring) or inline in text
/// (16 pt).
public enum AnnotationPinStyle: Hashable, Sendable {
    case slide
    case inline
}

/// The bare marker of an `AnnotationPin`: a white glyph on the voice's colour; on a slide 20 pt
/// with a shadow and a 2 pt white ring (slides stay white in dark mode), inline 16 pt.
public struct AnnotationPinMark: View {
    private let layer: AnnotationLayer
    private let style: AnnotationPinStyle

    public init(_ layer: AnnotationLayer, style: AnnotationPinStyle = .slide) {
        self.layer = layer
        self.style = style
    }

    public var body: some View {
        switch style {
        case .inline:
            ProvenancePin(layer, inline: true)
        case .slide:
            ProvenancePin(layer, inline: false)
                .background(Circle().fill(.white).padding(-2))
                .compositingGroup()
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        }
    }
}
