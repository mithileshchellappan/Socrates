import Foundation
import Synchronization

// The university profile (docs/research/study-coach.md §5): the student's university as data, the
// light layer of local facts the universal coach and the prompts read. It is the student's own:
// stored in the library (`university_profile`, one row), set through the agent (`set_profile`),
// never built into the code. A new library has none: `standard` (the system's time zone, plain
// ECTS rules, no university named). Screens use generic labels (Exam, Second date, Exam
// admission, Registration, Practice exam); `localTerms` are for source popovers only.

/// What the student's university is and what its rules give the coach: hours per credit, exam
/// periods and registration windows per term, attempts. Lecture periods and breaks stay in the
/// `semester` row (editable in Settings and through the agent); a term here is matched to it by
/// name ("WS 2026/27").
public struct UniversityProfile: Hashable, Sendable, Codable {
    /// A short key for the profile ("" when the student has not named a university).
    public var id: String
    /// The university's name as the student writes it ("" = not told yet).
    public var name: String
    /// The city the student studies in ("" = not told yet); prompts say "in <city> (<zone>)".
    public var city: String
    /// The degree programme as it reads before "student": "history bachelor's" ("" = not
    /// told yet).
    public var program: String
    /// IANA time zone of the university ("" = the system's): the zone dates are read and written in.
    public var timeZone: String
    /// The learning platform's name as its notification mails write it ("" = none known): mail
    /// from it about a course routes by the course's "<platform> course is" rule.
    public var learningPlatform: String
    /// The university's offices as its mail names them, for mail routing ("" = the generic list,
    /// `officeList`).
    public var offices: String
    /// "ECTS"
    public var creditSystem: String
    /// Hours of total work per credit (ECTS: 25–30).
    public var hoursPerCredit: Double
    /// Credits assumed for a course whose credits nobody told the agent yet (the agent asks).
    public var defaultCredits: Double
    /// Exam sittings per module per term.
    public var sittingsPerTerm: Int
    /// Attempts per module in all; `freeAttempt`, `gradeImprovement`.
    public var attempts: Int
    public var freeAttempt: Bool
    public var gradeImprovement: Bool
    /// The grade scale as one line (popover text only; no grade is ever estimated).
    public var gradeScale: String
    /// The withdraw rule as one line (popover).
    public var withdrawRule: String
    /// Where old exams come from (popover).
    public var practiceExamSources: [String]
    /// Generic label → the local term and rule, for source popovers only ("admission",
    /// "second_date", "registration", …).
    public var localTerms: [String: String]
    /// The exam length range for a written exam when none is announced (the practice exam sheet
    /// defaults to `defaultExamMinutes`).
    public var writtenExamMinutes: ClosedRange<Int>
    public var defaultExamMinutes: Int
    public var terms: [UniversityTerm]

    public init(
        id: String = "",
        name: String = "",
        city: String = "",
        program: String = "",
        timeZone: String = "",
        learningPlatform: String = "",
        offices: String = "",
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
        self.city = city
        self.program = program
        self.timeZone = timeZone
        self.learningPlatform = learningPlatform
        self.offices = offices
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

    /// Every key is optional: a missing one keeps `standard`'s value, so a stored profile from
    /// an older build (or a partial one) still reads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let base = UniversityProfile.standard
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? base.id
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? base.name
        city = try container.decodeIfPresent(String.self, forKey: .city) ?? base.city
        program = try container.decodeIfPresent(String.self, forKey: .program) ?? base.program
        timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone) ?? base.timeZone
        learningPlatform = try container.decodeIfPresent(String.self, forKey: .learningPlatform) ?? base.learningPlatform
        offices = try container.decodeIfPresent(String.self, forKey: .offices) ?? base.offices
        creditSystem = try container.decodeIfPresent(String.self, forKey: .creditSystem) ?? base.creditSystem
        hoursPerCredit = try container.decodeIfPresent(Double.self, forKey: .hoursPerCredit) ?? base.hoursPerCredit
        defaultCredits = try container.decodeIfPresent(Double.self, forKey: .defaultCredits) ?? base.defaultCredits
        sittingsPerTerm = try container.decodeIfPresent(Int.self, forKey: .sittingsPerTerm) ?? base.sittingsPerTerm
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? base.attempts
        freeAttempt = try container.decodeIfPresent(Bool.self, forKey: .freeAttempt) ?? base.freeAttempt
        gradeImprovement = try container.decodeIfPresent(Bool.self, forKey: .gradeImprovement) ?? base.gradeImprovement
        gradeScale = try container.decodeIfPresent(String.self, forKey: .gradeScale) ?? base.gradeScale
        withdrawRule = try container.decodeIfPresent(String.self, forKey: .withdrawRule) ?? base.withdrawRule
        practiceExamSources = try container.decodeIfPresent([String].self, forKey: .practiceExamSources) ?? base.practiceExamSources
        localTerms = try container.decodeIfPresent([String: String].self, forKey: .localTerms) ?? base.localTerms
        writtenExamMinutes = try container.decodeIfPresent(ClosedRange<Int>.self, forKey: .writtenExamMinutes) ?? base.writtenExamMinutes
        defaultExamMinutes = try container.decodeIfPresent(Int.self, forKey: .defaultExamMinutes) ?? base.defaultExamMinutes
        terms = try container.decodeIfPresent([UniversityTerm].self, forKey: .terms) ?? base.terms
    }

    /// The term of a semester (matched by name), if the profile knows it.
    public func term(named name: String) -> UniversityTerm? {
        terms.first { $0.name == name }
    }

    /// The profile of a library whose student has told the app nothing yet: no university named,
    /// the system's time zone, plain ECTS rules (30 h per credit, 6 credits a course, one sitting,
    /// three attempts), no terms.
    public static let standard = UniversityProfile(
        creditSystem: "ECTS", hoursPerCredit: 30, defaultCredits: 6,
        sittingsPerTerm: 1, attempts: 3, freeAttempt: false, gradeImprovement: false,
        gradeScale: "", withdrawRule: "", practiceExamSources: [], localTerms: [:],
        writtenExamMinutes: 60...120, defaultExamMinutes: 90, terms: []
    )
}

// MARK: - Reading it

extension UniversityProfile {
    /// The university's time zone: `timeZone`, else the system's.
    public var zone: TimeZone {
        let identifier = timeZone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return .current }
        return TimeZone(identifier: identifier) ?? .current
    }

    /// Who the student is, for a prompt: "a <programme> student at <university>",
    /// "a university student at <university>", "a university student".
    public var student: String { Self.article(studentNoun) }

    /// `student` without its article: "<programme> student at <university>".
    public var studentNoun: String { kind("student") + atUniversity }

    /// `noun` of the student's programme: "<programme> course", else "university
    /// course".
    public func kind(_ noun: String) -> String {
        let program = program.trimmingCharacters(in: .whitespacesAndNewlines)
        return program.isEmpty ? "university \(noun)" : "\(program) \(noun)"
    }

    /// " at <university>", or "" when no university is named.
    public var atUniversity: String {
        let university = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return university.isEmpty ? "" : " at \(university)"
    }

    /// "a"/"an" before `phrase` ("a university student", "an engineering student").
    public static func article(_ phrase: String) -> String {
        let lowered = phrase.lowercased()
        let vowel = lowered.first.map { "aeiou".contains($0) } == true && !lowered.hasPrefix("uni") && !lowered.hasPrefix("use")
        return (vowel ? "an " : "a ") + phrase
    }

    /// Where dates are read, for a prompt's "Today is … in <place>": "<city> (<zone>)", or the zone
    /// alone ("Europe/Lisbon").
    public var place: String {
        let city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        return city.isEmpty ? zone.identifier : "\(city) (\(zone.identifier))"
    }

    /// What a prompt calls the time dates are written in: "<city> time", else "local time".
    public var localTime: String {
        let city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        return city.isEmpty ? "local time" : "\(city) time"
    }

    /// The university's offices for a prompt: `offices`, else "IT services, the student office, the
    /// exam office, the library".
    public var officeList: String {
        let names = offices.trimmingCharacters(in: .whitespacesAndNewlines)
        return names.isEmpty ? "IT services, the student office, the exam office, the library" : names
    }

    /// Where the student registers for exams (the first registration window's system), if known.
    public var registrationSystem: String? {
        terms.lazy.flatMap(\.registrations).map(\.system).first { !$0.isEmpty }
    }

    /// A prompt's example of the platform's name as speech-to-text writes it: `, "Moodle" for
    /// "MOODLE"`-style when the name is written in capitals, else "".
    public var misheardPlatform: String {
        let name = learningPlatform.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = name.lowercased().capitalized
        return name.isEmpty || heard == name ? "" : ", \"\(heard)\" for \"\(name)\""
    }

    /// The learning platform's name as text: `learningPlatform`, else "the learning platform".
    public var platformName: String {
        let name = learningPlatform.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "the learning platform" : name
    }

    /// The learning platform's name folded for matching mail ("My Campus" → "mycampus": lowercased, no
    /// spaces); "" when none is known (no mail is taken for the platform's).
    public var platformMarker: String {
        learningPlatform
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - The library's profile

extension UniversityProfile {
    private static let installed = Mutex<UniversityProfile>(.standard)

    /// The profile the app uses now (one student, one university): the library's, installed when
    /// the library opens (`StudyDatabase.open`) and again whenever it is saved
    /// (`UniversityProfileRecord.save`); `standard` until then.
    public static var current: UniversityProfile {
        installed.withLock { $0 }
    }

    /// Makes `profile` the current one.
    public static func install(_ profile: UniversityProfile) {
        installed.withLock { $0 = profile }
    }
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

/// An exam period ("1st period", 1–19 Mar 2027).
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

/// A registration window ("Register for exams", Mon 1 – Fri 12 Feb 2027, in the exam office's
/// system).
public struct RegistrationWindow: Hashable, Sendable, Codable {
    /// The sitting it registers for (1: the first exam period; 2: the second).
    public var sitting: Int
    public var first: CalendarDay
    public var last: CalendarDay
    /// Where the student registers (the exam office's online system, by its name).
    public var system: String
    /// The profile's own line, used as the item's source quote: "Registration for the first exam
    /// period closes on 12 Feb."
    public var rule: String

    public init(sitting: Int, first: CalendarDay, last: CalendarDay, system: String, rule: String) {
        self.sitting = sitting
        self.first = first
        self.last = last
        self.system = system
        self.rule = rule
    }
}
