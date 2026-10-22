#if os(macOS)
import SwiftUI

/// [screen | strip]: the strip is as wide as its columns want, never narrower than their
/// minimums (`placedNeed`) and, past that, never wider than leaves the screen its minimum; the
/// screen gets the rest. Both start at the top of the host's area (under the toolbar); the screen
/// keeps its own reach under the toolbar.
struct PaneHostLayout: Layout {
    /// The strip's width as the student wants it (0: no columns).
    var stripWidth: CGFloat
    var placedNeed: CGFloat
    var screenMinimum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let screen = subviews.first else { return .zero }
        let strip = width(in: proposal.width)
        let screenSize = screen.sizeThatFits(ProposedViewSize(width: proposal.width.map { max(0, $0 - strip) }, height: proposal.height))
        return CGSize(width: proposal.width ?? (screenSize.width + strip), height: proposal.height ?? screenSize.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let strip = width(in: bounds.width)
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: max(0, bounds.width - strip), height: bounds.height))
        if subviews.count > 1 {
            subviews[1].place(at: CGPoint(x: bounds.maxX - strip, y: bounds.minY), proposal: ProposedViewSize(width: strip, height: bounds.height))
        }
    }

    /// clamp(the wanted width, placedNeed, total − the screen's minimum), the columns' minimums
    /// winning over the screen's (AppKit's split view cannot go under them).
    private func width(in total: CGFloat?) -> CGFloat {
        guard stripWidth > 0 else { return 0 }
        guard let total, total.isFinite else { return stripWidth }
        return max(min(stripWidth, total - screenMinimum), placedNeed).rounded()
    }
}
#endif
