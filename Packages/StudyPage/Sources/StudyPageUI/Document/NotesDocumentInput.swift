import Foundation
import StudyCore

/// Where a chip in the notes points (a slide or a moment of a lecture).
public enum NotesChipTarget: Hashable, Sendable {
    case slide(lecture: Lecture.ID, page: Int)
    case moment(lecture: Lecture.ID, recording: Recording.ID?, seconds: Double)

    public var lectureID: Lecture.ID {
        switch self {
        case .slide(let lecture, _), .moment(let lecture, _, _): lecture
        }
    }
}

/// Everything the notes document is drawn from: the current version, the student's marks and
/// notes, the professor's rows, the lecture's slides and recordings, and the view's own state
/// (folded sections, open answers). Equal inputs draw the same document.
struct NotesDocumentInput: Equatable {
    struct LectureRef: Equatable {
        var id: Lecture.ID
        var number: Int?
    }

    var lectureID: Lecture.ID
    var style: LectureNotesStyle
    /// The appearance the inks and formula images are drawn for.
    var isDark = false
    var notes: LectureNotes?
    var marks: [LectureNotesMark] = []
    /// The lecture's notes (live: a note written later in Review shows in place).
    var studentNotes: [Note] = []
    /// The lecture's exam hints and highlights (the professor's words for `quote` fences).
    var quotes: [Annotation] = []
    /// Lecture keys (`ChatCitation.key`) of the course's lectures.
    var lectures: [String: LectureRef] = [:]
    /// Recording keys of this lecture.
    var recordings: [String: Recording.ID] = [:]
    var hasRecording = false
    /// The lecture's slides.
    var deck: Deck?
    var pages: ClosedRange<Int>?
    var professor: String?
    var folded: Set<String> = []
    /// Check yourself blocks whose Answers are open ("<section>#<n>").
    var answersOpen: Set<String> = []
    /// Claude Code is not available: the readable sentence (nil: available or unknown).
    var unavailable: String?
    /// A new version could be written now (`LectureNotesRepository.source`): the failure line's
    /// Write Again… is off without it.
    var canWriteAgain = true

    var outline: [LectureNotesSection] { notes?.sections ?? [] }

    var chips: NotesChipResolver {
        NotesChipResolver(lectureID: lectureID, lectures: lectures, recordings: recordings)
    }
}

/// Citations to chips: a lecture key of the course (`ChatCitation.key`) to its lecture, a
/// recording key of this lecture to its recording.
struct NotesChipResolver: Equatable, Sendable {
    var lectureID: Lecture.ID
    var lectures: [String: NotesDocumentInput.LectureRef]
    var recordings: [String: Recording.ID]

    func target(_ citation: ChatCitation) -> NotesChipTarget? {
        switch citation {
        case .slide(let key, let page):
            guard let lecture = lectures[key] else { return nil }
            return .slide(lecture: lecture.id, page: page)
        case .moment(let key, let recording, let seconds):
            guard let lecture = lectures[key] else { return nil }
            return .moment(lecture: lecture.id, recording: recording.flatMap { recordings[$0] }, seconds: Double(seconds))
        case .web, .change, .document:
            return nil
        }
    }

    /// "L2" for another lecture of the course; nil for this one.
    func prefix(_ lecture: Lecture.ID) -> String? {
        guard lecture != lectureID else { return nil }
        return lectures.values.first { $0.id == lecture }?.number.map { "L\($0)" }
    }
}
