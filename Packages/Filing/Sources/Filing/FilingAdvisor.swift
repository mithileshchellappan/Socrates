import Foundation
import StudyCore

/// Decides an uncertain deck filing (or a deck dropped on the agent panel with the student's
/// words) from the deck's first pages and the timetable: which course, which session or lecture
/// number, the title. The app's is a cheap Haiku call (`HaikuFilingAdvisor` in AppAgent). Nil:
/// no advice (Claude Code unavailable or paused, an unusable answer); the heuristic filing stays.
public protocol FilingAdvisor: Sendable {
    func advise(_ request: FilingAdviceRequest) async -> FilingAdvice?
}

/// What the advisor sees (all of it data, never instructions).
public struct FilingAdviceRequest: Sendable, Hashable {
    /// A numbered session of a course's timetable.
    public struct Session: Sendable, Hashable {
        public var id: LectureSession.ID
        public var number: Int?
        public var startsAt: Date
        /// A deck is filed to it already.
        public var hasSlides: Bool
    }

    /// A lecture of a course that has no numbered session (a course without a timetable).
    public struct LectureOption: Sendable, Hashable {
        public var id: Lecture.ID
        public var number: Int?
        public var heldAt: Date?
        public var title: String
        public var hasSlides: Bool
    }

    public struct CourseOption: Sendable, Hashable {
        public var id: Course.ID
        public var name: String
        public var shortName: String
        public var lecturers: [String]
        public var sessions: [Session]
        public var lectures: [LectureOption]
    }

    /// Where the heuristics would file it, best first.
    public struct Candidate: Sendable, Hashable {
        public var courseID: Course.ID
        public var sessionID: LectureSession.ID?
        public var lectureID: Lecture.ID?
        public var number: Int?
        public var confidence: Double
    }

    public var fileName: String
    public var deckTitle: String
    /// The text of the deck's first pages (at most 3, each shortened).
    public var pages: [String]
    /// What the student wrote with the drop (the agent panel), else nil.
    public var studentWords: String?
    public var courses: [CourseOption]
    public var candidates: [Candidate]
    public var now: Date
    public var timeZone: TimeZone
    /// Asked from the panel while the student waits (`.interactive`), else in the background.
    public var interactive: Bool

    /// The deck's first non-empty line (the change's quote).
    public var firstLine: String {
        for page in pages {
            if let line = page.split(whereSeparator: \.isNewline)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty }) {
                return String(line.prefix(200))
            }
        }
        return deckTitle.isEmpty ? fileName : deckTitle
    }

    /// `advice` with its ids checked against this request: an unknown course is no advice; a
    /// session of another course is dropped (its number stays); numbers outside 1…99 are dropped.
    public func validated(_ advice: FilingAdvice) -> FilingAdvice? {
        guard let course = courses.first(where: { $0.id == advice.courseID }) else { return nil }
        var checked = advice
        if let sessionID = advice.sessionID, !course.sessions.contains(where: { $0.id == sessionID }) {
            checked.sessionID = nil
        }
        if let number = advice.lectureNumber, !(1...99).contains(number) { checked.lectureNumber = nil }
        checked.confidence = min(max(advice.confidence, 0), 1)
        checked.title = String(advice.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        checked.reason = String(advice.reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        return checked
    }
}

/// The advisor's answer.
public struct FilingAdvice: Sendable, Hashable {
    /// The file is a lecture's slides (false: something else, e.g. an exercise sheet or a paper:
    /// not filed by advice).
    public var isSlides: Bool
    public var courseID: Course.ID
    /// The timetable session it belongs to, when the advisor named one.
    public var sessionID: LectureSession.ID?
    public var lectureNumber: Int?
    /// The lecture's title ("Virtualization"), empty when unknown.
    public var title: String
    /// 0…1. Applied on its own from `FilingAdvice.applyThreshold`.
    public var confidence: Double
    /// One sentence for the change log ("The title slide says Lecture 3 and the course is Data Centers.").
    public var reason: String
    /// The model that decided (`claude-haiku-5-5`).
    public var model: String
    public var apiCallID: APICall.ID?

    public init(
        isSlides: Bool, courseID: Course.ID, sessionID: LectureSession.ID? = nil, lectureNumber: Int? = nil, title: String = "",
        confidence: Double, reason: String, model: String, apiCallID: APICall.ID? = nil
    ) {
        self.isSlides = isSlides
        self.courseID = courseID
        self.sessionID = sessionID
        self.lectureNumber = lectureNumber
        self.title = title
        self.confidence = confidence
        self.reason = reason
        self.model = model
        self.apiCallID = apiCallID
    }

    /// At or above: the advice is applied without asking (an automatic change with Undo).
    public static let applyThreshold = 0.7
}

/// A deck the advice filed: the outcome (for a toast), the change row (Undo, the panel's
/// `[[change …]]`) and where it went in short ("DC · L3 · Virtualization").
public struct AdvisedFiling: Sendable {
    public var outcome: FilingOutcome
    public var change: AgentChange?
    public var placed: String
}

extension FilingSignal.Kind {
    /// The filing advisor (a Haiku call) decided it.
    public static let advisor: Self = "advisor"
}
