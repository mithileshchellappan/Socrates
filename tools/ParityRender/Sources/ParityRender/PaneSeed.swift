import Foundation
import Panes
import StudyUI

/// panes: the side panes a shot opens with, as a student left them: each screen kind's layout
/// (`Socrates.panes.<kind>`) and the panes open for the whole window (`Socrates.panes.windowOpen`,
/// the agent). Put in the registration domain before each shot, so nothing is written to any
/// defaults file; a kind the shot leaves out starts from its first layout.
struct PaneSeed {
    var layouts: [PaneScreenKind: PaneLayout] = [:]
    var windowOpen: Set<PaneID> = []

    /// Every kind's key and the window's, so no shot keeps the one before's layout.
    func register() throws {
        var values: [String: Any] = [PaneLayoutStore.windowOpenKey: windowOpen.map(\.rawValue).sorted()]
        for kind in [PaneScreenKind.review, .lectureNotes, .calendar, .general] {
            let layout = layouts[kind] ?? PaneLayout.initial(for: PaneTable.specs(kind, agent: true))
            values[PaneLayoutStore.keyPrefix + kind.rawValue] = try JSONEncoder().encode(layout)
        }
        UserDefaults.standard.register(defaults: values)
    }
}
