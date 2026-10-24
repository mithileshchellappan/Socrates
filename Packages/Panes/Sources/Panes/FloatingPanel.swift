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
    /// `\.floatingPanelFrame` and `\.isLiveResizing`. It is installed when the panel is presented,
    /// never again while it shows (it follows its own observed state). Apply at the window's root,
    /// so the panel's corner is the content area's.
    public func floatingPanel<Content: View>(
        isPresented: Bool,
        frame: Binding<FloatingPanelFrame>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(FloatingPanelModifier(isPresented: isPresented, frame: frame, panel: content))
    }
}

/// Places the panel's AppKit view at the stored frame: its size (the content's height while it
/// hugs) plus the resize band, inset from the bottom-trailing corner. It stays in place while
/// hidden, so presenting it never moves anything.
private struct FloatingPanelModifier<Panel: View>: ViewModifier {
    let isPresented: Bool
    @Binding var frame: FloatingPanelFrame
    let panel: () -> Panel

    /// The content's height while the panel hugs it (kept across presentations).
    @State private var hugged: CGFloat = 120

    func body(content: Content) -> some View {
        let band = FloatingPanelView.band
        let binding = $frame
        let hugged = $hugged
        content
            .overlay(alignment: .bottomTrailing) {
                FloatingPanelHost(
                    isPresented: isPresented,
                    frame: frame,
                    write: { binding.wrappedValue = $0 },
                    onHug: { height in if hugged.wrappedValue != height { hugged.wrappedValue = height } },
                    panel: panel
                )
                .frame(width: CGFloat(frame.width) + 2 * band, height: CGFloat(frame.height ?? Double(self.hugged)) + 2 * band)
                .padding(.trailing, max(0, CGFloat(frame.dx) - band))
                .padding(.bottom, max(0, CGFloat(frame.dy) - band))
            }
    }
}
#endif
