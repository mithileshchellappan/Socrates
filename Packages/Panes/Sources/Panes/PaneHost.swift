#if os(macOS)
import StudyUI
import SwiftUI

/// The screen and its panes: the app puts it in the main window's detail column around the
/// screen's navigation stack (never inside the stack's per-screen identity, so open panes keep
/// their state across screens). The screen stays in the window's own SwiftUI tree, so its toolbar
/// items, title, focus and commands work as before; right of it, an AppKit split view lays out the
/// open panes as columns (stacks in a column), each pane in its own hosting view with a 36 pt
/// header under the toolbar. Dividers, the screen's edge, maximize and the live-resize signal are
/// AppKit's: a drag lays out only the views whose size changes.
///
/// - Parameters:
///   - model: the window's panes.
///   - kind: the screen kind on display (its layout is kept per kind).
///   - specs: the panes this screen offers, in toolbar order (the agent last); the screen's own
///     offers (`.pane(_:identity:…)` in `main`) supply their content.
///   - room: the screen's declared minimum and the sidebar's width while it shows.
///   - main: the screen.
///
/// Sets for the screen: `\.isLiveResizing`, `\.mainIsCovered`, `\.paneControl`. Each pane's root
/// gets this place's environment (the window's values) plus `\.isLiveResizing` and
/// `\.paneIsMaximized`; a screen's own values (its zoom, its chrome) are the offer content's to
/// apply.
public struct PaneHost<Main: View>: View {
    private let model: PaneHostModel
    private let kind: PaneScreenKind
    private let specs: [PaneSpec]
    private let room: PaneRoom
    private let main: Main

    @State private var stage = PaneStage()

    public init(model: PaneHostModel, kind: PaneScreenKind, specs: [PaneSpec], room: PaneRoom, @ViewBuilder main: () -> Main) {
        self.model = model
        self.kind = kind
        self.specs = specs
        self.room = room
        self.main = main()
    }

    public var body: some View {
        let model = model
        let kind = kind
        let specs = specs
        let room = room
        PaneHostLayout(stripWidth: model.stripWidth, placedNeed: model.placedNeed, screenMinimum: room.screenMinimum) {
            main
                .environment(\.isLiveResizing, model.isLiveResizing)
                .environment(\.mainIsCovered, model.maximized != nil)
                .environment(\.paneControl, model.control)
                .onPreferenceChange(PaneOfferKey.self) { offers in
                    MainActor.assumeIsolated { model.receive(offers) }
                }
            PaneStrip(state: PaneStripState(model), model: model, stage: stage)
        }
        .overlay {
            if model.maximized != nil || stage.slotPane != nil {
                PaneMaximizeSlot(stage: stage)
            }
        }
        .onChange(of: Configuration(kind: kind, specs: specs), initial: true) {
            model.configure(kind: kind, specs: specs, room: room)
        }
        .onChange(of: room) { _, room in
            model.update(room: room)
        }
    }

    private struct Configuration: Equatable {
        var kind: PaneScreenKind
        var specs: [PaneSpec]
    }
}
#endif
