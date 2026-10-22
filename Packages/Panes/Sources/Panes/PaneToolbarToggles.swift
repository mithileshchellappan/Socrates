#if os(macOS)
import StudyUI
import SwiftUI

/// The toggles at the toolbar's trailing end (DESIGN 6.3): one glass group, one toggle per offered
/// pane in toolbar order (the agent last), lit while its pane is on screen (the system draws a
/// toggled toolbar button accent soft with an accent glyph); help "Notes ⌥⌘1". A folded pane's
/// toggle shows unlit. Reads only which panes are offered and open, so no drag re-renders the
/// toolbar. The app puts it last among its trailing items.
public struct PaneToolbarToggles: ToolbarContent {
    private let model: PaneHostModel

    public init(model: PaneHostModel) {
        self.model = model
    }

    public var body: some ToolbarContent {
        if !model.specs.isEmpty {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(model.specs) { spec in
                    PaneToggle(model: model, spec: spec)
                }
            }
        }
    }
}

/// One pane's toggle: a toolbar toggle (the window draws its lit state); toggling while another
/// pane is maximized restores the layout first.
private struct PaneToggle: View {
    let model: PaneHostModel
    let spec: PaneSpec

    var body: some View {
        Toggle(spec.menuTitle, systemImage: spec.systemImage, isOn: isOpen)
            .imageScale(.small)
            .help(help)
    }

    private var isOpen: Binding<Bool> {
        let model = model
        let id = spec.id
        return Binding(get: { model.isOpen(id) }, set: { _ in model.toggle(id) })
    }

    private var help: String {
        guard let number = model.shortcutNumber(of: spec.id) else { return spec.menuTitle }
        return "\(spec.menuTitle) ⌥⌘\(number)"
    }
}
#endif
