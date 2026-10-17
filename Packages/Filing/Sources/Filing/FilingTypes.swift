import Foundation
import Processing
import StudyCore

/// Where the user sent a file: a course (smart import picks the lecture), a lecture, or a
/// session (its lecture, created when there is none).
public enum FilingDestination: Hashable, Sendable {
    case course(Course.ID)
    case lecture(Lecture.ID)
    case session(LectureSession.ID)
}

/// A lecture a file can go to, ready to show: "● Data Centers / Lecture 3 · Wed 21 Oct".
public struct FilingPlace: Sendable, Hashable {
    public var course: Course
    /// The existing lecture, if any.
    public var lectureID: Lecture.ID?
    /// The session the lecture is (or will be) filed to.
    public var sessionID: LectureSession.ID?
    /// The session's kind (lecture, exercise, …), when there is a session.
    public var sessionKind: SessionKind?
    /// "Lecture 3"; nil when unknown.
    public var number: Int?
    /// When it is (was) held: the session start, the lecture's date, or the date found.
    public var date: Date?
    /// True when `date` is a day without a time of day.
    public var isWholeDay: Bool
    public var title: String
    /// No lecture exists yet; filing creates it.
    public var isNewLecture: Bool
    /// Only the course is known (asking for a course).
    public var isCourseOnly: Bool
    /// Filing here explicitly (drop on this place, or pick it in the change sheet).
    public var destination: FilingDestination
    /// 0…1
    public var confidence: Double

    public init(
        course: Course, lectureID: Lecture.ID? = nil, sessionID: LectureSession.ID? = nil, sessionKind: SessionKind? = nil, number: Int? = nil,
        date: Date? = nil, isWholeDay: Bool = false, title: String = "", isNewLecture: Bool = false,
        isCourseOnly: Bool = false, destination: FilingDestination, confidence: Double = 1
    ) {
        self.course = course
        self.lectureID = lectureID
        self.sessionID = sessionID
        self.sessionKind = sessionKind
        self.number = number
        self.date = date
        self.isWholeDay = isWholeDay
        self.title = title
        self.isNewLecture = isNewLecture
        self.isCourseOnly = isCourseOnly
        self.destination = destination
        self.confidence = confidence
    }

    /// Whether the sidebar row of `row` stands for this place: its own destination's row, its
    /// lecture's row once the lecture exists, or its session's row while it has none.
    public func isShown(byRowOf row: FilingDestination) -> Bool {
        if row == destination { return true }
        switch row {
        case .lecture(let id): return lectureID == id
        case .session(let id): return lectureID == nil && sessionID == id
        case .course: return false
        }
    }
}

/// One destination smart import considered for a file, with the evidence for it.
public struct FilingChoice: Sendable, Hashable {
    public var place: FilingPlace
    /// How the importer reaches it.
    public var target: LectureTarget
    /// Evidence for the course and the lecture.
    public var signals: [FilingSignal]
    /// Course score × lecture fit, 0…1.
    public var confidence: Double { place.confidence }
    /// How well the course alone fits, 0…1.
    public var courseScore: Double
}

/// Smart import's verdict for one file.
public struct FilingDecision: Sendable, Hashable {
    public enum Verdict: Sendable, Hashable {
        /// Confident: file it and show the toast.
        case file
        /// A course fits, the lecture or the course is not certain: file to the best guess and
        /// mark it for review.
        case review
        /// Two destinations fit about equally well: the HUD shows both; a plain drop files the
        /// best guess for review.
        case ask
        /// No course fits: ask for one (the file is stored unfiled).
        case needsCourse
    }

    public var verdict: Verdict
    /// The chosen destination; nil when no course fits.
    public var best: FilingChoice?
    /// Runner-ups, best first (for `.needsCourse`, the courses).
    public var alternatives: [FilingChoice]

    /// Destinations to show: the best one, plus the runner-up when asking, or the courses when
    /// no course fits.
    public var places: [FilingPlace] {
        switch verdict {
        case .file, .review: best.map { [$0.place] } ?? []
        case .ask: ([best].compactMap(\.self) + alternatives.prefix(1)).map(\.place)
        case .needsCourse: alternatives.prefix(3).map(\.place)
        }
    }
}

/// The result of filing one file.
public struct FilingOutcome: Sendable, Hashable, Identifiable {
    public enum Status: Sendable, Hashable {
        /// Filed with confidence, or where the user said.
        case filed
        /// Filed to the best guess; the alternatives are one click away.
        case review
        /// Stored, but no course fits: choose one.
        case needsCourse
        /// The same file was filed before; nothing was created.
        case known
        /// Not a deck, recording or capture, or it could not be read.
        case failed(String)
    }

    public let id: UUID
    public var url: URL
    public var fileName: String
    public var kind: FilingKind?
    public var status: Status
    /// The row describing the filing (nil only when it failed).
    public var filing: Filing?
    /// Where it went.
    public var place: FilingPlace?
    /// Other destinations worth one click (review), or the courses (needs course).
    public var alternatives: [FilingPlace]
    public var pageCount: Int?
    /// Seconds.
    public var duration: Double?

    public init(
        id: UUID = UUID(), url: URL, fileName: String, kind: FilingKind?, status: Status, filing: Filing? = nil,
        place: FilingPlace? = nil, alternatives: [FilingPlace] = [], pageCount: Int? = nil, duration: Double? = nil
    ) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.kind = kind
        self.status = status
        self.filing = filing
        self.place = place
        self.alternatives = alternatives
        self.pageCount = pageCount
        self.duration = duration
    }
}

/// What dropping a file would do, computed while it is dragged (nothing is written).
public struct FilingPrediction: Sendable, Hashable, Identifiable {
    public var id: URL { url }
    public var url: URL
    public var fileName: String
    public var kind: FilingKind
    public var verdict: FilingDecision.Verdict
    /// Best first; two when asking; the courses when no course fits.
    public var places: [FilingPlace]
    /// The file was filed before (`places` shows where).
    public var isKnown: Bool
    public var pageCount: Int?
    public var duration: Double?

    public init(
        url: URL, fileName: String, kind: FilingKind, verdict: FilingDecision.Verdict, places: [FilingPlace],
        isKnown: Bool = false, pageCount: Int? = nil, duration: Double? = nil
    ) {
        self.url = url
        self.fileName = fileName
        self.kind = kind
        self.verdict = verdict
        self.places = places
        self.isKnown = isKnown
        self.pageCount = pageCount
        self.duration = duration
    }
}

extension FilingSignal.Kind {
    /// Course glossary terms appear in the slides.
    public static let glossary: Self = "glossary"
    /// The number on the title slide or in the footer ("2 Virtualization Basics", "I: Introduction").
    public static let slideNumber: Self = "slide_number"
    /// The date on the title slide ("13-Oct-26").
    public static let titleDate: Self = "title_date"
    /// A lecture of the course is dated the recording's day.
    public static let sameDay: Self = "same_day"
    /// The course chosen when the lecture was captured.
    public static let capturedCourse: Self = "captured_course"
}

extension Filing {
    /// Filed automatically below the confidence threshold, or with a runner-up about as likely:
    /// worth a second look.
    public var needsReview: Bool {
        guard source == .auto else { return false }
        let tie = candidates.first.map { confidence - $0.confidence < FilingMatcher.tieMargin } ?? false
        return courseID == nil || confidence < FilingMatcher.fileThreshold || tie
    }

    /// The file's contents were in the library before this filing; Undo never removes them.
    public var reusedExistingFile: Bool {
        signals.contains { $0.kind == .knownFile }
    }
}
