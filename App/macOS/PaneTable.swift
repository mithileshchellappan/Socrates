import Panes
import StudyUI

/// Which side panes each kind of main-window screen offers, in toolbar order (DESIGN 6.4): the
/// table lives here, so the toggles, the View menu and the room a pane needs exist in the same
/// update as the screen; the screen's own `.pane(…)` offer only brings the content.
///
/// | Kind | Screens | Panes |
/// |---|---|---|
/// | review | a lecture's review | Notes, then Agent |
/// | lectureNotes | a lecture's notes page | Your notes, then Agent |
/// | calendar | Calendar | Deadlines, then Agent |
/// | general | every other screen | Agent |
///
/// A practice exam being written offers nothing (the agent is withheld with everything else).
enum PaneTable {
    static func kind(_ selection: SidebarItem?) -> PaneScreenKind {
        switch selection ?? .today {
        case .lecture: .review
        case .lectureNotes: .lectureNotes
        case .calendar: .calendar
        default: .general
        }
    }

    /// The panes a screen of `kind` offers; `agent` while the window's chat is offered (Claude Code
    /// is available and no practice exam is being written).
    static func specs(_ kind: PaneScreenKind, agent: Bool) -> [PaneSpec] {
        var specs: [PaneSpec] = switch kind {
        case .review: [notes]
        case .lectureNotes: [yourNotes]
        case .calendar: [deadlines]
        default: []
        }
        if agent { specs.append(Self.agent) }
        return specs
    }

    /// Review's notes: the header holds the tab picker (This slide | Whole lecture | Summary) in
    /// place of a title; 300 pt keeps its three segments and both buttons.
    static let notes = PaneSpec(
        id: .notes, title: String(localized: "Notes"), systemImage: "doc.text",
        minWidth: 300, idealWidth: 336, opensByDefault: true, showsTitle: false
    )

    /// The lecture notes page's own notes: the lecture's note, then the notes by slide.
    static let yourNotes = PaneSpec(
        id: .yourNotes, title: String(localized: "Your notes"), menuTitle: String(localized: "Your Notes"),
        systemImage: "doc.text", minWidth: 260, idealWidth: 336, opensByDefault: true
    )

    /// Calendar's deadlines and the selection's detail.
    static let deadlines = PaneSpec(
        id: .deadlines, title: String(localized: "Deadlines"), systemImage: "calendar.badge.clock",
        minWidth: 260, idealWidth: 336, opensByDefault: true
    )

    /// The window's chat: open or closed for the whole window (one conversation across screens),
    /// its column and width kept per kind.
    static let agent = PaneSpec(
        id: .agent, title: String(localized: "Agent"), systemImage: "bubble.left",
        minWidth: 300, idealWidth: 344, opensPerWindow: true
    )
}
