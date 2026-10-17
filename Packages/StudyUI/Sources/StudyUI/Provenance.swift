import StudyCore
import SwiftUI

// Provenance by typography (PRD UI rules): the user's text is primary, AI text is secondary with
// one sparkle per AI block, the professor is marked in orange (pins, quote bars), never by copy.

extension View {
    /// Text colour for a voice: AI secondary, user and professor primary (the professor is marked
    /// by an orange `ProvenancePin` or bar, not by orange text).
    public func provenance(_ layer: AnnotationLayer) -> some View {
        foregroundStyle(layer == .ai ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }
}

/// The one sparkle that opens an AI block.
public struct AIMark: View {
    public init() {}

    public var body: some View {
        Image(systemName: "sparkle")
            .imageScale(.small)
            .foregroundStyle(Color.ai)
            .accessibilityLabel(Text("AI"))
    }
}

/// A round marker for who a pin or line speaks for: you (accent, person), the professor (orange,
/// mortarboard) or AI (purple, sparkle), as white outline glyphs. `inline` is the small size used
/// inside text rows.
public struct ProvenancePin: View {
    private let layer: AnnotationLayer
    private let size: CGFloat

    public init(_ layer: AnnotationLayer, inline: Bool = true) {
        self.layer = layer
        size = inline ? 16 : 20
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(fill, in: Circle())
            .accessibilityLabel(Text(label))
    }

    private var symbol: String {
        switch layer {
        case .user: "person"
        // The mockups' plain mortarboard: SF's outline cap adds a tassel that blurs at 9 pt.
        case .professor: "graduationcap.fill"
        case .ai: "sparkle"
        }
    }

    private var fill: AnyShapeStyle {
        switch layer {
        case .user: AnyShapeStyle(.tint)
        case .professor: AnyShapeStyle(Color.professor)
        case .ai: AnyShapeStyle(Color.ai)
        }
    }

    private var label: LocalizedStringKey {
        switch layer {
        case .user: "You"
        case .professor: "Professor"
        case .ai: "AI"
        }
    }
}
