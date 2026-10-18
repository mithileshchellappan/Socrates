import Foundation
import SQLiteData

// Values added with schema v9 (M5: search & tutor). docs/plan-m5.md §3–4, docs/schema.md.

extension ConversationKind {
    /// The tutor (PRD #22): questions about the student's lectures and courses, asked in Review's
    /// Tutor tab, on a course's screen or on Search (about the selected hits). Lecture tools (read),
    /// the agent memory tools (verified write) and Claude Code's WebSearch/WebFetch; never a mail
    /// tool and never mail in its context (PRD trust rule: the web agent never sees mail). Answers
    /// cite slides, moments and web pages with `ChatCitation` markers. Its subject is its
    /// `lecture_id` / `course_id` (`ChatSubject`).
    public static let tutor: Self = "tutor"
}

extension SearchChunkKind {
    /// A further-reading source the study pass verified (annotation ai · `further_reading`, not
    /// hidden): `source_id` = the annotation, its lecture, deck and page; text "title · byline".
    /// Search's Web group and the tutor's material (M5).
    public static let furtherReading: Self = "further_reading"
}

/// What one agent memory is about (v9 `agent_memory.kind`).
public struct AgentMemoryKind: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The student: their programme, background, goals, what they find hard.
    public static let student: Self = "student"
    /// How they want to be answered: language, length, style.
    public static let preference: Self = "preference"
    /// A fact about one course the student told the agent (`course_id` set): "I skip the
    /// exercises", "the exam is open book".
    public static let course: Self = "course"

    /// The memory sheet's order (You, Preferences, then the courses).
    public static let displayOrder: [Self] = [.student, .preference, .course]
}

// MARK: - Chat context

/// What the chat inspector sees beside the student's words, and so which conversation it is:
/// the mail chat on Today and Mail, the tutor on Review, a course's screen and Search.
public enum ChatContext: Hashable, Sendable {
    /// Today: the mail chat, nothing beside the student's words.
    case none
    /// Mail: the mail chat with the open message (each message carries it when it changed).
    case mail(MailMessage.ID)
    /// Review: the tutor about this lecture, at the slide on screen and the playhead (seconds on
    /// the lecture's first recording).
    case lecture(Lecture.ID, page: Int?, time: Double?)
    /// A course's screen: the tutor about the course.
    case course(Course.ID)
    /// Search: the tutor with the query and the hits the student selected (never mail hits).
    case search(query: String, sources: [ChatSource])

    /// The open message, when there is one.
    public var messageID: MailMessage.ID? {
        if case .mail(let id) = self { return id }
        return nil
    }

    /// The conversation kind this context's chat runs: `mail_chat` for none and mail, `tutor`
    /// otherwise.
    public var kind: ConversationKind {
        switch self {
        case .none, .mail: .mailChat
        case .lecture, .course, .search: .tutor
        }
    }

    /// The tutor's subject (which conversations the inspector opens); nil for the mail chat.
    public var subject: ChatSubject? {
        switch self {
        case .none, .mail: nil
        case .lecture(let id, _, _): .lecture(id)
        case .course(let id): .course(id)
        case .search: .search
        }
    }
}

/// What a `tutor` conversation is about, stored in its columns: a lecture (`lecture_id` set, with
/// its `course_id`), a course (`course_id` set, `lecture_id` NULL) or Search (both NULL). The
/// inspector opens the newest tutor conversation of the screen's subject; New Chat starts another.
public enum ChatSubject: Hashable, Sendable {
    case lecture(Lecture.ID)
    case course(Course.ID)
    case search

    public var lectureID: Lecture.ID? {
        if case .lecture(let id) = self { return id }
        return nil
    }

    /// The course of a course subject (a lecture subject's course is the lecture's).
    public var courseID: Course.ID? {
        if case .course(let id) = self { return id }
        return nil
    }

    /// The subject of a stored conversation (`tutor` kind), from its columns.
    public init(lectureID: Lecture.ID?, courseID: Course.ID?) {
        if let lectureID {
            self = .lecture(lectureID)
        } else if let courseID {
            self = .course(courseID)
        } else {
            self = .search
        }
    }
}

/// One search hit the student selected for the tutor (Search's multi-selection). Never a mail.
public struct ChatSource: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case transcript
        case slide
        case note
        case furtherReading = "further_reading"
    }

    public var kind: Kind
    public var courseID: Course.ID?
    public var lectureID: Lecture.ID?
    public var deckID: Deck.ID?
    /// 1-based deck page: the slide itself, the slide on screen for a line, a note's slide.
    public var page: Int?
    public var recordingID: Recording.ID?
    /// Seconds on `recordingID`'s clock (a line's start, a slide's first visit, a note's moment).
    public var time: Double?
    public var noteID: Note.ID?
    /// A further-reading row.
    public var annotationID: Annotation.ID?
    /// The hit's text as plain text (the line, the slide's text, the note, "title · byline"),
    /// at most `textLimit` characters.
    public var text: String

    public static let textLimit = 600

    public init(
        kind: Kind,
        courseID: Course.ID? = nil,
        lectureID: Lecture.ID? = nil,
        deckID: Deck.ID? = nil,
        page: Int? = nil,
        recordingID: Recording.ID? = nil,
        time: Double? = nil,
        noteID: Note.ID? = nil,
        annotationID: Annotation.ID? = nil,
        text: String
    ) {
        self.kind = kind
        self.courseID = courseID
        self.lectureID = lectureID
        self.deckID = deckID
        self.page = page
        self.recordingID = recordingID
        self.time = time
        self.noteID = noteID
        self.annotationID = annotationID
        self.text = String(text.prefix(Self.textLimit))
    }
}
