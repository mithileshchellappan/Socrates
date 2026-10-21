#if os(macOS)
import StudyCore
import SwiftUI

/// Renders only (`ParityMode`, tools/ParityRender; mockups 31–32), on a library copy: what an
/// off-screen window cannot be made to show by hand. Nothing is written or sent.
/// - `passage`: its first occurrence in the notes is selected and scrolled into view, and the
///   capsule floats over it (with [Ask]);
/// - with `question` and `answer` too, the Ask popover is drawn in place under the passage (an
///   off-screen window draws no popover), that one exchange finished;
/// - `reveal` alone: that text scrolled into view (a kept answer under its paragraph).
public struct LectureNotesPreview: Equatable, Sendable {
    public var passage: String?
    public var question: String?
    public var answer: String?
    public var reveal: String?

    public init(passage: String? = nil, question: String? = nil, answer: String? = nil, reveal: String? = nil) {
        self.passage = passage
        self.question = question
        self.answer = answer
        self.reveal = reveal
    }
}

extension EnvironmentValues {
    /// Renders only: a selection, a capsule or an Ask popover drawn on the notes
    /// (`LectureNotesPreview`). Nil in the app.
    @Entry public var lectureNotesPreview: LectureNotesPreview?
}

/// The preview's Ask: its one answer, at once (no model).
struct CannedNotesAsker: LectureNotesAsking {
    let answer: String

    func ask(_ request: NotesAskRequest) -> AsyncStream<NotesAskUpdate> {
        let answer = answer
        return AsyncStream { continuation in
            continuation.yield(NotesAskUpdate(text: answer, isFinished: true))
            continuation.finish()
        }
    }
}
#endif
