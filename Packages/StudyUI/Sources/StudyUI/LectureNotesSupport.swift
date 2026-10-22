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
