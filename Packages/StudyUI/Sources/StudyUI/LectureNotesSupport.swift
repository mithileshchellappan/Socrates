import StudyCore
import SwiftUI

// ln: the lecture notes' hooks for screens (docs/plan-lecture-notes.md "Build plan"). The notes
// view (StudyPage) asks through `\.lectureNotesAsker` without depending on StudyPass; the app
// installs StudyPass's `NotesAsker` on the Mac where Claude Code runs.

extension EnvironmentValues {
    /// Answers Ask on a passage of a lecture's notes. Nil (iOS, previews, renders, no Claude Code):
    /// the capsule and the menu offer Highlight only, no Ask.
    @Entry public var lectureNotesAsker: (any LectureNotesAsking)?
}

/// The Your notes column beside a lecture's notes page (nl, docs/plan-notes-layout.md §1, §4):
/// `auto` follows the detail width (open from 1160 pt, closed under 1120, unchanged in between);
/// `shown` and `hidden` are the student's choice once they toggle it, kept per window for every
/// lecture page (`@SceneStorage(YourNotesVisibility.sceneStorageKey)`).
public enum YourNotesVisibility: String, Hashable, Sendable, CaseIterable {
    case auto
    case shown
    case hidden

    public static let sceneStorageKey = "lectureNotes.yourNotes"
}

extension EnvironmentValues {
    /// Renders: the Your notes column's state whatever the window's choice and width (nil: theirs).
    @Entry public var yourNotesVisibilityOverride: YourNotesVisibility?
}
