import Foundation

// The university profile (docs/research/study-coach.md §5): the light layer of local facts the
// universal coach reads as data. One per university; the example university is the only one
// (`UniversityProfiles.swift` holds its JSON). Screens use generic labels (Exam, Second date, Exam admission, Registration,
// Practice exam); `localTerms` are for source popovers only.

/// What one university's rules give the coach: hours per credit, exam periods and registration
/// windows per term, attempts. Lecture periods and breaks stay in the `semester` row (editable in
/// Settings); a term here is matched to it by name ("WS 2026/27").
public struct UniversityProfile: Hashable, Sendable, Codable {
    /// "example"
    public var id: String
    /// "Example University"
    public var name: String
    /// "ECTS"
    public var creditSystem: String
    /// Hours of total work per credit (the module handbook: 30).
    public var hoursPerCredit: Double
    /// Credits assumed for a course whose credits nobody told the agent yet (the agent asks).
    public var defaultCredits: Double
    /// Exam sittings per module per term (e.g. 2).
    public var sittingsPerTerm: Int
    /// Attempts per module in all (e.g. 3, i.e. 2 retakes); `freeAttempt`, `gradeImprovement`.
    public var attempts: Int
    public var freeAttempt: Bool
    public var gradeImprovement: Bool
    /// "1.0–5.0, 4.0 passes" (popover text only; no grade is ever estimated).
    public var gradeScale: String
    /// The withdraw rule as one line (popover).
    public var withdrawRule: String
    /// Where old exams come from (popover): "past papers in the library".
    public var practiceExamSources: [String]
    /// Generic label → the local term and rule, for source popovers only: "admission" →
    /// "Exam admission", "second_date" → "Second date", "registration" → "Registration (exam portal)".
    public var localTerms: [String: String]
    /// The handbook's exam length range for a written exam when none is announced (60…120 min;
    /// the practice exam sheet defaults to `defaultExamMinutes`).
    public var writtenExamMinutes: ClosedRange<Int>
    public var defaultExamMinutes: Int
    public var terms: [UniversityTerm]

    public init(
        id: String,
        name: String,
        creditSystem: String,
        hoursPerCredit: Double,
        defaultCredits: Double,
        sittingsPerTerm: Int,
        attempts: Int,
        freeAttempt: Bool,
        gradeImprovement: Bool,
        gradeScale: String,
        withdrawRule: String,
        practiceExamSources: [String],
        localTerms: [String: String],
        writtenExamMinutes: ClosedRange<Int>,
        defaultExamMinutes: Int,
        terms: [UniversityTerm]
    ) {
        self.id = id
        self.name = name
        self.creditSystem = creditSystem
        self.hoursPerCredit = hoursPerCredit
        self.defaultCredits = defaultCredits
        self.sittingsPerTerm = sittingsPerTerm
        self.attempts = attempts
        self.freeAttempt = freeAttempt
        self.gradeImprovement = gradeImprovement
        self.gradeScale = gradeScale
        self.withdrawRule = withdrawRule
        self.practiceExamSources = practiceExamSources
        self.localTerms = localTerms
        self.writtenExamMinutes = writtenExamMinutes
        self.defaultExamMinutes = defaultExamMinutes
        self.terms = terms
    }

    /// The term of a semester (matched by name), if the profile knows it.
    public func term(named name: String) -> UniversityTerm? {
        terms.first { $0.name == name }
    }

    /// The profile the app uses (one student, one university).
    public static let current: UniversityProfile = .exampleUniversity
}

/// One term's exam periods and registration windows (inclusive days, the university's time zone).
public struct UniversityTerm: Hashable, Sendable, Codable {
    /// Matches `semester.name`: "WS 2026/27".
    public var name: String
    public var examPeriods: [ExamPeriod]
    public var registrations: [RegistrationWindow]

    public init(name: String, examPeriods: [ExamPeriod], registrations: [RegistrationWindow]) {
        self.name = name
        self.examPeriods = examPeriods
        self.registrations = registrations
    }
}

/// An exam period ("1st period", 1–20 Feb 2027).
public struct ExamPeriod: Hashable, Sendable, Codable {
    /// 1 = the first sitting, 2 = the second date.
    public var sitting: Int
    public var first: CalendarDay
    public var last: CalendarDay

    public init(sitting: Int, first: CalendarDay, last: CalendarDay) {
        self.sitting = sitting
        self.first = first
        self.last = last
    }
}

/// A registration window ("Register for exams", Mon 14 Dec 2026 – Fri 8 Jan 2027, "Exam portal").
public struct RegistrationWindow: Hashable, Sendable, Codable {
    /// The sitting it registers for (1: the first exam period; 2: the second).
    public var sitting: Int
    public var first: CalendarDay
    public var last: CalendarDay
    /// Where: "Exam portal".
    public var system: String
    /// The profile's own line, used as the item's source quote: "Registration for the first exam
    /// period: Mon 14 Dec 2026 – Fri 8 Jan 2027 in the exam portal."
    public var rule: String

    public init(sitting: Int, first: CalendarDay, last: CalendarDay, system: String, rule: String) {
        self.sitting = sitting
        self.first = first
        self.last = last
        self.system = system
        self.rule = rule
    }
}
