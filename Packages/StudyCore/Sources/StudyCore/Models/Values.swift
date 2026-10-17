import Foundation
import SQLiteData

// Value types stored in record columns.
//
// Closed sets are enums. Open sets that other modules may extend (job stages, annotation
// kinds, ...) are string-backed structs, so a module can add
// `extension JobStage { public static let align = JobStage("align") }` without a schema change,
// and rows written by a newer build still decode in an older one.

/// A string-backed, extensible identifier stored as TEXT.
public protocol StringKind: RawRepresentable, Hashable, Sendable, Codable, QueryBindable,
    ExpressibleByStringLiteral, CustomStringConvertible where RawValue == String {
    init(rawValue: String)
}

extension StringKind {
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
    public init(stringLiteral value: String) { self.init(rawValue: value) }
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Closed sets

/// How a lecture <-> deck span (or a slide boundary) was established.
public enum SpanSource: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// Automatic alignment (transcript <-> slide text).
    case auto
    /// A slide stamp taken live while recording.
    case stamp
    /// The user said "slide starts here".
    case manual
}

/// Who an annotation speaks for. Drives provenance typography in the UI.
public enum AnnotationLayer: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    case user
    case professor
    case ai
}

public enum JobState: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled

    public var isFinished: Bool { self == .succeeded || self == .failed || self == .cancelled }
}

public enum TrackedItemStatus: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    case open
    case done
    case dismissed
}

public enum RecordingState: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    case recording
    case finished
    case failed
}

/// Who created a row: the user directly, or the agent/pipeline on their behalf.
public enum Author: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    case user
    case agent
}

// MARK: - Open sets

/// Kind of a weekly slot or calendar session.
public struct SessionKind: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let lecture: Self = "lecture"
    public static let exercise: Self = "exercise"
    public static let seminar: Self = "seminar"
    public static let tutorial: Self = "tutorial"
}

/// Kind of a live event on the recording clock.
public struct SlideEventKind: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The professor moved to `pageNumber` (←/→/Space in live mode).
    public static let show: Self = "show"
    /// The student flagged this moment (F).
    public static let flag: Self = "flag"
    /// "Slide starts here" set by hand in review: `pageNumber` starts at `sampleTime`, or an
    /// off-slide stretch starts there when `pageNumber` is nil. Used as given by the aligner.
    public static let manual: Self = "manual"
}

/// Where a recording came from.
public struct RecordingSource: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let mac: Self = "mac"
    public static let iPhone: Self = "iphone"
    public static let iPad: Self = "ipad"
    /// An imported audio/video file.
    public static let file: Self = "file"
}

public struct AnnotationKind: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let comment: Self = "comment"
    public static let examHint: Self = "exam_hint"
    public static let notOnSlides: Self = "not_on_slides"
    public static let summary: Self = "summary"
    public static let furtherReading: Self = "further_reading"
    public static let correction: Self = "correction"
    public static let ink: Self = "ink"
}

public struct TrackedItemKind: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let deadline: Self = "deadline"
    public static let exercise: Self = "exercise"
    public static let exam: Self = "exam"
    public static let announcement: Self = "announcement"
}

/// A processing stage. Modules add their own stages in extensions.
public struct JobStage: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let transcribe: Self = "transcribe"
    public static let align: Self = "align"
    public static let correct: Self = "correct"
    public static let studyPass: Self = "study_pass"
}

/// What a running job is doing before (or besides) its stage's own work. `progress` is the
/// fraction of this phase. A nil phase is the stage itself.
public struct JobPhase: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let downloadingModel: Self = "downloading_model"
    public static let loadingModel: Self = "loading_model"
}

// MARK: - JSON values

/// A pointer to where a fact came from. Stored as JSON in `annotation.citations` and
/// `tracked_item.source_refs`. All fields except `kind` are optional; set what applies.
public struct SourceRef: Hashable, Sendable, Codable {
    public struct Kind: StringKind {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let slide: Self = "slide"
        public static let transcript: Self = "transcript"
        public static let mail: Self = "mail"
        public static let web: Self = "web"
        public static let chat: Self = "chat"
        public static let note: Self = "note"
        /// A timetable file the student dropped (a campus system `.ics`): exam dates.
        public static let timetable: Self = "timetable"
    }

    public var kind: Kind
    public var lectureID: UUID?
    public var deckID: UUID?
    public var pageNumber: Int?
    public var recordingID: UUID?
    /// Seconds on the recording clock.
    public var time: Double?
    /// RFC 5322 Message-ID for mail sources.
    public var mailMessageID: String?
    public var url: URL?
    public var title: String?
    /// Short exact quote from the source.
    public var quote: String?

    public init(
        kind: Kind,
        lectureID: UUID? = nil,
        deckID: UUID? = nil,
        pageNumber: Int? = nil,
        recordingID: UUID? = nil,
        time: Double? = nil,
        mailMessageID: String? = nil,
        url: URL? = nil,
        title: String? = nil,
        quote: String? = nil
    ) {
        self.kind = kind
        self.lectureID = lectureID
        self.deckID = deckID
        self.pageNumber = pageNumber
        self.recordingID = recordingID
        self.time = time
        self.mailMessageID = mailMessageID
        self.url = url
        self.title = title
        self.quote = quote
    }
}

/// A rule that routes mail to a course. Stored as JSON in `course.mail_rules`.
public struct MailRoutingRule: Hashable, Sendable, Codable {
    public struct Field: StringKind {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let from: Self = "from"
        public static let subject: Self = "subject"
        public static let listID: Self = "list_id"
    }

    public var field: Field
    /// Case-insensitive substring match.
    public var contains: String

    public init(field: Field, contains: String) {
        self.field = field
        self.contains = contains
    }
}

/// Word-level timing inside a transcript segment. Stored as JSON in `transcript_segment.words`.
public struct TranscriptWord: Hashable, Sendable, Codable {
    public var text: String
    /// Seconds on the recording clock.
    public var start: Double
    public var end: Double
    public var confidence: Double?

    public init(text: String, start: Double, end: Double, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

// MARK: - M1: courses, semester, filing, search

/// Whose voices a course's recordings may keep (course setup, "Recording" section).
public struct RecordingScope: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Only the lecturer: other voices are kept out of stored audio where possible.
    public static let lecturer: Self = "lecturer"
    /// The whole room.
    public static let room: Self = "room"
}

/// A rule of a course: exam admission, bonus points, exam form, … Stored as JSON in
/// `course.rules`.
public struct CourseRule: Hashable, Sendable, Codable, Identifiable {
    public struct Kind: StringKind {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let examAdmission: Self = "exam_admission"
        public static let examForm: Self = "exam_form"
        public static let bonus: Self = "bonus"
        public static let exercise: Self = "exercise"
        public static let attendance: Self = "attendance"
        public static let other: Self = "other"
    }

    public var id: UUID
    public var kind: Kind
    /// Short label, e.g. "Exam admission".
    public var title: String
    /// The rule itself, e.g. "Take part in the online quizzes." Empty = not announced yet.
    public var text: String
    /// Who it speaks for (provenance typography): the user typed it, the professor said or wrote
    /// it, or the agent read it from a source and it waits for Confirm.
    public var provenance: AnnotationLayer
    /// Where it was said or written (lecture + time, mail).
    public var source: SourceRef?
    /// When the user confirmed an agent-proposed rule; nil while it waits.
    public var confirmedAt: Date?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        text: String = "",
        provenance: AnnotationLayer = .user,
        source: SourceRef? = nil,
        confirmedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.provenance = provenance
        self.source = source
        self.confirmedAt = confirmedAt
    }

    /// User and professor rules stand; agent rules count once confirmed.
    public var isConfirmed: Bool { provenance != .ai || confirmedAt != nil }
}

/// A stretch without classes inside a semester's lecture period (inclusive days). Stored as JSON
/// in `semester.breaks`.
public struct SemesterBreak: Hashable, Sendable, Codable {
    public var name: String
    public var first: CalendarDay
    public var last: CalendarDay

    public init(name: String, first: CalendarDay, last: CalendarDay) {
        self.name = name
        self.first = first
        self.last = last
    }

    public func contains(_ day: CalendarDay) -> Bool { first <= day && day <= last }
}

/// How a file was filed to its course and lecture.
public enum FilingSource: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// Smart import decided.
    case auto
    /// The user chose (drop on a lecture, Change…, a picked course).
    case manual
}

/// What kind of file a filing is about.
public struct FilingKind: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// A slide PDF.
    public static let deck: Self = "deck"
    /// An audio or video file.
    public static let recording: Self = "recording"
    /// A `.lecture` package from live capture.
    public static let capture: Self = "capture"
}

/// One piece of evidence behind a filing decision. Stored as JSON in `filing.signals`.
public struct FilingSignal: Hashable, Sendable, Codable {
    public struct Kind: StringKind {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// Deck footer text names the course or a lecturer.
        public static let deckFooter: Self = "deck_footer"
        /// Deck title / first-slide title / PDF title or author metadata.
        public static let deckTitle: Self = "deck_title"
        /// Numbering in the file name ("03_Cloud_Storage" → lecture 3).
        public static let fileNumber: Self = "file_number"
        /// A weekly slot / lecture session of the course fits the date.
        public static let weeklySlot: Self = "weekly_slot"
        /// The recording's start time falls in a session.
        public static let recordingStart: Self = "recording_start"
        /// The file came from the course's slides folder.
        public static let slidesFolder: Self = "slides_folder"
        /// A matching course mail (M2).
        public static let mail: Self = "mail"
        /// Same file contents were filed before.
        public static let knownFile: Self = "known_file"
        /// The user chose the destination.
        public static let user: Self = "user"
    }

    public var kind: Kind
    /// What was observed, e.g. "03", "Data Centers by Ada Example", "Tue 13 Oct 16:27".
    public var evidence: String
    /// Contribution to the decision's confidence, 0…1.
    public var weight: Double

    public init(kind: Kind, evidence: String, weight: Double) {
        self.kind = kind
        self.evidence = evidence
        self.weight = weight
    }
}

/// A destination smart import considered. Stored as JSON in `filing.candidates` (runner-ups,
/// shown to drop on when two fit about equally well).
public struct FilingCandidate: Hashable, Sendable, Codable {
    public var courseID: UUID
    public var lectureID: UUID?
    public var lectureSessionID: UUID?
    /// 0…1
    public var confidence: Double

    public init(courseID: UUID, lectureID: UUID? = nil, lectureSessionID: UUID? = nil, confidence: Double) {
        self.courseID = courseID
        self.lectureID = lectureID
        self.lectureSessionID = lectureSessionID
        self.confidence = confidence
    }
}

/// What a search chunk was cut from.
public struct SearchChunkKind: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Transcript lines of one recording (`recording_id`, `start_time`/`end_time`, `lecture_id`).
    public static let transcript: Self = "transcript"
    /// Text of one deck page (`deck_id`, `page_number`).
    public static let slide: Self = "slide"
    /// A note (`note_id`, plus its lecture/slide anchors).
    public static let note: Self = "note"
}
