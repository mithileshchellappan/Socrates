#if os(macOS)
/// What a drag in flight resizes (`PaneHostModel.liveResize`): every pane gets `\.isLiveResizing`
/// for either; the screen only for `.screen`, so a drag between panes never makes it hold and
/// draw again (Review's slide, its figures).
enum PaneLiveResize: Sendable {
    /// A divider between columns or in a stack: only panes change size.
    case panes
    /// The window's edge or the screen's edge: the screen changes size too.
    case screen
}
#endif
