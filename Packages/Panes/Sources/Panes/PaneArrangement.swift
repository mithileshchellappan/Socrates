#if os(macOS)
import CoreGraphics
import StudyUI

/// The columns the strip lays out now: the open panes that fit, in the order of the kind's layout,
/// at the student's widths and stack shares. Derived from the layout by the room rules
/// (`PaneHostModel`), never stored.
struct PaneArrangement: Equatable {
    struct Column: Equatable {
        /// The shown panes, top to bottom.
        var panes: [PaneID]
        /// The student's width, within `minimum...maximum`.
        var width: CGFloat
        /// The widest minimum and the narrowest maximum of its panes.
        var minimum: CGFloat
        var maximum: CGFloat
        /// Each shown pane's share of the column's height (summing to 1).
        var fractions: [CGFloat]
    }

    var columns: [Column] = []

    var panes: [PaneID] { columns.flatMap(\.panes) }

    /// The strip at the student's widths: the columns and a divider before each (the first one
    /// is the screen's edge).
    var wantedWidth: CGFloat {
        columns.reduce(0) { $0 + $1.width + PaneHostModel.dividerThickness }
    }

    /// The strip at the columns' minimums (`placedNeed`).
    var minimumWidth: CGFloat {
        columns.reduce(0) { $0 + $1.minimum + PaneHostModel.dividerThickness }
    }

    func column(containing id: PaneID) -> Column? {
        columns.first { $0.panes.contains(id) }
    }

    /// The columns of `layout` holding the panes of `shown`, in the layout's order.
    init(layout: PaneLayout, specs: [PaneID: PaneSpec], shown: Set<PaneID>) {
        columns = layout.columns.compactMap { stored in
            var panes: [PaneID] = []
            var shares: [Double] = []
            for (index, id) in stored.panes.enumerated() where shown.contains(id) {
                panes.append(id)
                shares.append(index < stored.heights.count ? stored.heights[index] : 1)
            }
            guard !panes.isEmpty else { return nil }
            let minimum = panes.compactMap { specs[$0]?.minWidth }.max() ?? PaneSpec.minimumWidth
            let maximum = max(minimum, panes.compactMap { specs[$0]?.maxWidth }.min() ?? PaneSpec.maximumWidth)
            let total = shares.reduce(0, +)
            return Column(
                panes: panes,
                width: min(max(CGFloat(stored.width), minimum), maximum),
                minimum: minimum,
                maximum: maximum,
                fractions: shares.map { CGFloat(total > 0 ? $0 / total : 1 / Double(shares.count)) }
            )
        }
    }

    init() {}

    /// The room rules' fit: the panes of `order` (the oldest opened first) are taken in turn, each
    /// kept when the columns with it still hold their minimums in `available`. The others fold:
    /// the most recently opened give way first.
    static func fitting(_ order: [PaneID], layout: PaneLayout, specs: [PaneID: PaneSpec], available: CGFloat) -> PaneArrangement {
        var placed = Set<PaneID>()
        for id in order {
            var trial = placed
            trial.insert(id)
            if PaneArrangement(layout: layout, specs: specs, shown: trial).minimumWidth <= available + 0.5 {
                placed = trial
            }
        }
        return PaneArrangement(layout: layout, specs: specs, shown: placed)
    }

    /// The columns' widths in a strip `width` wide: the student's widths, the widest giving way
    /// first toward its minimum, then the next widest.
    func fittedWidths(in width: CGFloat) -> [CGFloat] {
        var widths = columns.map(\.width)
        var excess = wantedWidth - width
        for index in widths.indices.sorted(by: { widths[$0] > widths[$1] }) where excess > 0 {
            let cut = min(excess, widths[index] - columns[index].minimum)
            widths[index] -= cut
            excess -= cut
        }
        return widths
    }
}
#endif
