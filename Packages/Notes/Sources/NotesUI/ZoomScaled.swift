import SwiftUI

extension View {
    /// nl (docs/plan-notes-layout.md §11): this view drawn at `zoom` times its size, for content
    /// whose sizes are set elsewhere (StudyUI's chips, pins and further reading rows) inside text
    /// that zooms. It lays out in the room offered ÷ `zoom` and takes `zoom` × the size it chose;
    /// its text baselines line up with the text beside it. At 1 it is the view as it is.
    public func zoomScaled(_ zoom: CGFloat) -> some View {
        let zoom = zoom > 0 ? zoom : 1
        return ZoomScaledLayout(zoom: zoom) {
            scaleEffect(zoom, anchor: .topLeading)
        }
    }
}

/// Lays its one subview out at the proposal ÷ `zoom` and reports `zoom` × its size; the subview,
/// scaled from its top leading corner, fills that room.
private struct ZoomScaledLayout: Layout {
    let zoom: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(inner(proposal))
        return CGSize(width: size.width * zoom, height: size.height * zoom)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: inner(ProposedViewSize(bounds.size)))
    }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGFloat? {
        guard let subview = subviews.first else { return nil }
        return bounds.minY + subview.dimensions(in: inner(ProposedViewSize(bounds.size)))[guide] * zoom
    }

    func explicitAlignment(
        of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGFloat? {
        guard let subview = subviews.first else { return nil }
        return bounds.minX + subview.dimensions(in: inner(ProposedViewSize(bounds.size)))[guide] * zoom
    }

    private func inner(_ proposal: ProposedViewSize) -> ProposedViewSize {
        guard zoom != 1 else { return proposal }
        return ProposedViewSize(width: proposal.width.map { $0 / zoom }, height: proposal.height.map { $0 / zoom })
    }
}
