#if os(macOS)
import Observation

/// The Lecture menu's Ask… (⌘K) and Highlight (⇧⌘E) of a notes view drawn in a side pane, for the
/// screen to publish. The menu reads focused values from the screen's own SwiftUI tree, and a pane
/// is another hosting view: there a notes view given a relay publishes nothing itself, and the
/// screen publishes `ask` and `highlight` (Review's Summary tab, `ReviewActionsPublisher`). Read in
/// a body, they follow the notes' focus and selection.
@MainActor
@Observable
public final class LectureNotesCommandRelay {
    /// The notes view whose commands are relayed (the one on screen), held weakly through its
    /// reader: the view and its controller may go first.
    private var source: Source?

    private struct Source {
        let id: ObjectIdentifier
        let read: @MainActor () -> (ask: LectureNotesCommand?, highlight: LectureNotesCommand?)
    }

    public init() {}

    /// Ask… while the notes have focus (nil otherwise: the key is free elsewhere).
    public var ask: LectureNotesCommand? { source?.read().ask }
    /// Highlight / Remove Highlight while the notes have focus.
    public var highlight: LectureNotesCommand? { source?.read().highlight }

    func attach(_ controller: LectureNotesController) {
        source = Source(id: ObjectIdentifier(controller)) { [weak controller] in
            (controller?.askCommand, controller?.highlightCommand)
        }
    }

    /// Only the view that attached last lets go (another tab's notes may have taken over).
    func detach(_ controller: LectureNotesController) {
        guard source?.id == ObjectIdentifier(controller) else { return }
        source = nil
    }
}
#endif
