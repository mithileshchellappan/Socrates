import Foundation

/// Something the student added to the library and can remove again (Delete… with Undo): a slide
/// deck, a lecture with what it holds, or a recording.
public enum LibraryItem: Hashable, Sendable {
    case deck(Deck.ID)
    case lecture(Lecture.ID)
    case recording(Recording.ID)
}

/// What deleting a `LibraryItem` takes with it, for the confirmation ("Delete “Lecture 3 ·
/// Virtualization”? Its 42 slides, 1 recording and 3 notes go with it.").
public struct DeletionSummary: Sendable, Hashable {
    /// The item's name: the deck's title, "Lecture 3 · Virtualization", the recording's start.
    public var title: String
    /// Pages of the decks that go.
    public var slides: Int
    public var recordings: Int
    /// The student's notes that go (on the lecture, or pinned to the deck's pages).
    public var notes: Int
    /// Slide pages with the student's ink that go.
    public var inkPages: Int
    /// Practice questions that go with an answer history (FSRS) of the student's.
    public var practisedQuestions: Int

    public init(title: String, slides: Int = 0, recordings: Int = 0, notes: Int = 0, inkPages: Int = 0, practisedQuestions: Int = 0) {
        self.title = title
        self.slides = slides
        self.recordings = recordings
        self.notes = notes
        self.inkPages = inkPages
        self.practisedQuestions = practisedQuestions
    }

    /// True when the student's own work (notes, ink, practice history) goes too: the confirmation
    /// must say so.
    public var removesStudentWork: Bool { notes + inkPages + practisedQuestions > 0 }
}
