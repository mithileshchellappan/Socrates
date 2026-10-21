import Foundation
import Observation
import StudyCore

// nl (docs/plan-notes-layout.md §2): moved here unchanged from Review, so the lecture notes page's
// Your notes column (StudyPageUI) edits a slide's notes exactly as Review's This slide does.

/// Where a slide's notes are anchored. `page` nil: the lecture's own notes (and a lecture without
/// a deck).
public struct NoteAnchor: Sendable, Hashable {
    public var courseID: Course.ID?
    public var lectureID: Lecture.ID
    public var deckID: Deck.ID?
    public var page: Int?
    public var recordingID: Recording.ID?

    public init(courseID: Course.ID?, lectureID: Lecture.ID, deckID: Deck.ID?, page: Int?, recordingID: Recording.ID?) {
        self.courseID = courseID
        self.lectureID = lectureID
        self.deckID = deckID
        self.page = page
        self.recordingID = recordingID
    }
}

/// The notes of one slide in Review's inspector (M6: rich notes, `NotesUI.NoteEditor`): every note
/// anchored to (lecture, page), live quick notes included, each its own `NoteSession`; or, for a
/// slide without notes, one empty session that becomes a note on the student's first keystroke,
/// anchored to the recording and the playhead at that moment (decisions: "A slide's notes in
/// review are every note"). Sessions save 500 ms after typing stops and on `flush()` through
/// `NoteRepository.saveOrDeleteIfBlank`, so a note emptied out is deleted; nothing is written on
/// open.
@MainActor
@Observable
public final class SlideNoteEditor {
    public let anchor: NoteAnchor
    public private(set) var sessions: [NoteSession]

    /// `notes`: the slide's notes as fetched; `playhead`: the player's time for a new note.
    public init(
        anchor: NoteAnchor,
        notes: [Note],
        store: RecordStore,
        debounce: Duration = .milliseconds(500),
        now: @escaping @MainActor () -> Date = { Date() },
        playhead: @escaping @MainActor () -> Double?
    ) {
        self.anchor = anchor
        let existing = notes.filter { $0.lectureID == anchor.lectureID && $0.pageNumber == anchor.page }
        if existing.isEmpty {
            sessions = [NoteSession(store: store, debounce: debounce) { id in
                Note(
                    id: id, courseID: anchor.courseID, lectureID: anchor.lectureID, deckID: anchor.deckID,
                    pageNumber: anchor.page, recordingID: anchor.recordingID, audioTime: playhead(), createdAt: now()
                )
            }]
        } else {
            sessions = existing.map { NoteSession(note: $0, store: store, debounce: debounce) }
        }
    }

    /// True when some note of the slide has text or media.
    public var hasNotes: Bool {
        sessions.contains { $0.note.map { !$0.isBlank } ?? false }
    }

    /// Writes every pending edit now (page change, closing the screen).
    public func flush() async {
        for session in sessions {
            await session.flush()
        }
    }
}
