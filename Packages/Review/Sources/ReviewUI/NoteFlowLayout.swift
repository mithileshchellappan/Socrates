import SwiftUI

// Shared by the transcript's inline pins and the study blocks (This slide and Summary in the
// Notes pane).

/// Words left to right, wrapping at the proposed width; a `LineBreak` view starts a new line.
/// Each line is centred on its tallest item (the chip), lines `lineSpacing` apart.
struct NoteFlowLayout: Layout {
    /// The note text's line pitch (callout with 2 pt line spacing) and a space's width.
    var lineSpacing: CGFloat = 2
    var wordSpacing: CGFloat = 3.3

    struct LineBreak: LayoutValueKey {
        static let defaultValue = false
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in arrangement.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var line: [(index: Int, size: CGSize, x: CGFloat)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var widest: CGFloat = 0
        func closeLine() {
            let height = line.map(\.size.height).max() ?? 0
            for item in line {
                frames[item.index] = CGRect(x: item.x, y: y + (height - item.size.height) / 2, width: item.size.width, height: item.size.height)
            }
            if !line.isEmpty { y += height + lineSpacing }
            line = []
            x = 0
        }
        for (index, subview) in subviews.enumerated() {
            if subview[LineBreak.self] {
                closeLine()
                continue
            }
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { closeLine() }
            line.append((index, size, x))
            x += size.width + wordSpacing
            widest = max(widest, x - wordSpacing)
        }
        closeLine()
        return (frames, CGSize(width: min(widest, width), height: max(0, y - lineSpacing)))
    }
}
