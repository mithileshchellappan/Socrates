#if os(macOS)
import SwiftUI

/// The strip's place in `PaneHost`: its controller, the environment the panes get, and the
/// model's state applied on every update.
struct PaneStrip: NSViewControllerRepresentable {
    let state: PaneStripState
    let model: PaneHostModel
    let stage: PaneStage

    func makeNSViewController(context: Context) -> PaneStripController {
        stage.makeStrip(model: model)
    }

    func updateNSViewController(_ controller: PaneStripController, context: Context) {
        stage.environment.values = context.environment
        stage.apply(state)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: PaneStripController, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}
#endif
