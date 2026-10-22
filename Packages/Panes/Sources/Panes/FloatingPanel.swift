#if os(macOS)
import StudyUI
import SwiftUI

extension View {
    /// Floats `content` over the window's content area under the toolbar, at `frame` (its offset
    /// from the bottom-trailing corner and its size): the agent's small chat. The panel is an
    /// AppKit view of its own size (plus a 6 pt resize band) that SwiftUI places; during a drag on
    /// its title row (`\.floatingPanelMover`) AppKit moves only its layer (no layout, no body),
    /// and when the drag ends `frame` is written once and SwiftUI takes the new place in the same
    /// frame. Its edges and corners resize it with the system's resize pointers (the chat reflows
    /// live, `\.isLiveResizing` holds tables and code). It stays inside the content area with
    /// 12 pt margins. Until the student resizes it (`frame.height` nil) it is as tall as its
    /// content, up to half the window, anchored at its bottom edge. Outside its rectangle the
    /// window is untouched (clicks, scrolls, hovers and drops reach what is under it).
    ///
    /// The content gets this place's environment plus `\.floatingPanelMover`,
    /// `\.floatingPanelFrame` and `\.isLiveResizing`.
    public func floatingPanel<Content: View>(
        isPresented: Bool,
        frame: Binding<FloatingPanelFrame>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(FloatingPanelModifier(isPresented: isPresented, frame: frame, panel: content))
    }
}

/// Contracts stub: the panel in a SwiftUI overlay at its stored place, not movable. Workstream A
/// replaces it with the AppKit layer (docs/plan-panes.md, "Workstream A", the floating panel).
private struct FloatingPanelModifier<Panel: View>: ViewModifier {
    let isPresented: Bool
    @Binding var frame: FloatingPanelFrame
    let panel: () -> Panel

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if isPresented {
                    panel()
                        .environment(\.floatingPanelFrame, frame)
                        .frame(width: CGFloat(frame.width), height: frame.height.map { CGFloat($0) })
                        .padding(.trailing, frame.dx)
                        .padding(.bottom, frame.dy)
                }
            }
    }
}
#endif
