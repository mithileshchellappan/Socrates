#if os(macOS)
import SwiftUI

/// The maximize slot's place over the pane host (present only while a pane is maximized, and
/// while a restore fades out).
struct PaneMaximizeSlot: NSViewRepresentable {
    let stage: PaneStage

    func makeNSView(context: Context) -> PaneSlotView {
        let slot = PaneSlotView(frame: .zero)
        slot.stage = stage
        stage.attach(slot)
        return slot
    }

    func updateNSView(_ slot: PaneSlotView, context: Context) {}

    static func dismantleNSView(_ slot: PaneSlotView, coordinator: ()) {
        slot.stage?.detach(slot)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PaneSlotView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}
#endif
