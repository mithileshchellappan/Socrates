#if os(macOS)
import CoreGraphics

/// A place a dragged header can go: where the pointer must be (strip coordinates), and the drop.
struct PaneDropTarget: Equatable {
    var area: CGRect
    var drop: PaneDrop
}
#endif
