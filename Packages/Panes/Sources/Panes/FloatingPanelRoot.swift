#if os(macOS)
import StudyUI
import SwiftUI

/// The floating panel's SwiftUI root: the host's environment, then the mover, the frame and
/// `\.isLiveResizing`.
struct FloatingPanelRoot: View {
    let state: FloatingPanelState

    var body: some View {
        FloatingPanelContent(state: state)
            .environment(\.isLiveResizing, state.isLiveResizing)
            .environment(\.floatingPanelFrame, state.frame)
            .environment(\.floatingPanelMover, state.mover)
            .environment(\.self, state.environment)
    }
}

/// The content at the bottom of the panel. While the panel hugs, the content is offered the
/// cap's height and reports the height it takes, which becomes the panel's (the part above the
/// panel's top is clipped for the frame that takes); else it fills the panel.
private struct FloatingPanelContent: View {
    let state: FloatingPanelState

    var body: some View {
        let state = state
        ZStack(alignment: .bottom) {
            if let content = state.content {
                content
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { height in
            if state.hugs, height > 0 { state.onHug(height) }
        }
        .frame(height: state.hugs ? state.cap : nil, alignment: .bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
#endif
