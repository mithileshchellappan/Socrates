import CoreGraphics
import Foundation

/// How the student laid out the review screen: how tall the slide is over the transcript (the
/// divider between them), and whether the thumbnails or the transcript are collapsed. One
/// `@AppStorage` value under `storageKey`, so every lecture opens the same way.
///
/// A drag collapses a pane once it is pulled past half its minimum (NSSplitView's rule) and brings
/// it back the same way. Collapsing keeps the slide's share, so the transcript comes back at the
/// height it had.
struct ReviewLayout: Equatable, Sendable {
    static let storageKey = "review.layout"

    /// The slide's share of the content's height (to the window's bottom edge, the player's room
    /// included): half, as in mockup 03.
    static let defaultSlideShare = 0.5
    static let minSlideHeight: CGFloat = 160
    static let minTranscriptHeight: CGFloat = 120
    /// The room between the slide and the transcript, which is the divider.
    static let dividerHeight: CGFloat = 6
    /// The room between the thumbnails and the slide, which is the rail's edge.
    static let railEdgeWidth: CGFloat = 10

    var slideShare = defaultSlideShare
    var isTranscriptCollapsed = false
    var isRailCollapsed = false

    /// The column the slide and the transcript share.
    struct Column: Equatable {
        /// Above the player's room.
        var size: CGSize
        /// From the column's bottom to the window's bottom edge (the player's room).
        var below: CGFloat
        /// The slide's width over its height.
        var aspect: CGFloat

        fileprivate var fullHeight: CGFloat { size.height + below }
        /// The slide at the column's full width.
        fileprivate var naturalSlideHeight: CGFloat { aspect > 0 ? size.width / aspect : 0 }
        /// The slide's height while the transcript is collapsed: everything above the divider.
        fileprivate var collapsedSlideHeight: CGFloat { max(0, size.height - ReviewLayout.dividerHeight) }
    }

    /// The slide's height over the transcript: its share, at least `minSlideHeight`, at most its
    /// full-width height and what leaves the transcript `minTranscriptHeight`. A small window
    /// squeezes the transcript before the slide.
    func slideHeight(in column: Column) -> CGFloat {
        guard column.size.width > 0, column.size.height > 0, column.aspect > 0 else { return 0 }
        let natural = column.naturalSlideHeight
        let lower = min(Self.minSlideHeight, natural)
        let upper = max(lower, min(natural, column.size.height - Self.dividerHeight - Self.minTranscriptHeight))
        return min(max(column.fullHeight * slideShare, lower), upper)
    }

    /// The layout while the divider is dragged `translation` points down from where it was when the
    /// drag began (`self`). Pulled to within half the transcript's minimum of the bottom, the
    /// transcript collapses; from collapsed, pulled up as far, it comes back.
    func draggingDivider(by translation: CGFloat, in column: Column) -> ReviewLayout {
        var layout = self
        guard column.size.height > 0, column.fullHeight > 0 else { return layout }
        let start = isTranscriptCollapsed ? column.collapsedSlideHeight : slideHeight(in: column)
        let proposed = start + translation
        if column.size.height - Self.dividerHeight - proposed < Self.minTranscriptHeight / 2 {
            layout.isTranscriptCollapsed = true
            return layout
        }
        layout.isTranscriptCollapsed = false
        layout.slideShare = Double(proposed / column.fullHeight)
        layout.slideShare = Double(layout.slideHeight(in: column) / column.fullHeight)
        return layout
    }

    /// The layout while the rail's edge is dragged `translation` points right from where it was
    /// when the drag began (`self`): the rail has one width, so it only collapses or comes back,
    /// once pulled past half of it.
    func draggingRailEdge(by translation: CGFloat, railWidth: CGFloat) -> ReviewLayout {
        var layout = self
        if isRailCollapsed, translation > railWidth / 2 {
            layout.isRailCollapsed = false
        } else if !isRailCollapsed, translation < -railWidth / 2 {
            layout.isRailCollapsed = true
        }
        return layout
    }
}

/// Stored as "share,transcript,rail" ("0.5,0,0"); anything unreadable is the default layout.
extension ReviewLayout: RawRepresentable {
    init?(rawValue: String) {
        let parts = rawValue.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 3, let share = Double(parts[0]), share.isFinite,
              let transcript = Self.flag(parts[1]), let rail = Self.flag(parts[2])
        else { return nil }
        slideShare = min(max(share, 0.05), 0.95)
        isTranscriptCollapsed = transcript
        isRailCollapsed = rail
    }

    var rawValue: String {
        "\(slideShare),\(isTranscriptCollapsed ? 1 : 0),\(isRailCollapsed ? 1 : 0)"
    }

    private static func flag(_ text: Substring) -> Bool? {
        switch text {
        case "0": false
        case "1": true
        default: nil
        }
    }
}
