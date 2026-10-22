#if os(macOS)
import StudyUI

/// Where a pane's header is dropped: a new column beside another column (its outer 24 pt band),
/// or stacked under another pane (that pane's lower half).
enum PaneDrop: Equatable {
    /// A column of its own, before or after the column holding `anchor`.
    case column(beside: PaneID, after: Bool)
    /// Under `anchor`, in its column; the two share what `anchor` had of its height.
    case stack(under: PaneID)
}
#endif
