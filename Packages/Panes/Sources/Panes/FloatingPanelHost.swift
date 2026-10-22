#if os(macOS)
import StudyUI
import SwiftUI

/// The floating panel's AppKit view in SwiftUI: SwiftUI sizes and places it; it gets the
/// environment here, the stored frame, the content while presented, and writes the frame back.
struct FloatingPanelHost<Panel: View>: NSViewRepresentable {
    let isPresented: Bool
    let frame: FloatingPanelFrame
    let write: (FloatingPanelFrame) -> Void
    let onHug: (CGFloat) -> Void
    let panel: () -> Panel

    func makeNSView(context: Context) -> FloatingPanelView {
        FloatingPanelView(frame: .zero)
    }

    func updateNSView(_ view: FloatingPanelView, context: Context) {
        view.onPlace = write
        view.state.onHug = onHug
        view.update(frame: frame, environment: context.environment, content: isPresented ? AnyView(panel()) : nil)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FloatingPanelView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}
#endif
