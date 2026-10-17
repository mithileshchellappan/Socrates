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
