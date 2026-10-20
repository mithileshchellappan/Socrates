import Foundation
import StudyCore

enum CoursesLog {
    static let schedule = Log.logger(category: "courses")
}

/// The fields a new course starts with (the New Course sheet, and any other place that creates
/// a course). Everything else is set up later in Course Settings.
public struct CourseDraft: Hashable, Sendable {
    public var name: String
    /// Lecturers as typed: one per line, or separated by ";" or ",".
    public var lecturers: String
    /// BCP 47 teaching language.
    public var language: String
    /// BCP 47 language of admin talk and mail.
    public var adminLanguage: String
    /// "#rrggbb"; nil picks the next palette colour.
    public var colorHex: String?
    /// Nil = the current semester.
    public var semesterID: Semester.ID?
    /// Recording consent ("Record this course").
    public var records: Bool
    public var rules: [CourseRule]
    /// The course's short name, its token ("DC"); nil = the initials of the name.
    public var shortName: String?
    /// Mirror its sessions to the "Study Portal" calendar.
    public var showsInCalendar: Bool
    /// Credit points (ECTS / LP), when known.
    public var credits: Double?

    public init(
        name: String = "",
        lecturers: String = "",
        language: String = "en",
        adminLanguage: String = "de",
        colorHex: String? = nil,
        semesterID: Semester.ID? = nil,
        records: Bool = false,
        rules: [CourseRule] = [],
        shortName: String? = nil,
        showsInCalendar: Bool = true,
        credits: Double? = nil
    ) {
        self.name = name
        self.lecturers = lecturers
        self.language = language
        self.adminLanguage = adminLanguage
        self.colorHex = colorHex
        self.semesterID = semesterID
        self.records = records
        self.rules = rules
        self.shortName = shortName
        self.showsInCalendar = showsInCalendar
        self.credits = credits
    }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var isValid: Bool { !trimmedName.isEmpty }

    /// `lecturers` split into names.
    public var professors: [String] { Self.names(from: lecturers) }

    /// Course colours: the mockups' three, then system colours. Orange (the professor) and red
    /// (recording) are left out.
    public static let palette = ["#0a84ff", "#2fae55", "#e0457b", "#5e5ce6", "#30b0c7", "#bf5af2", "#a2845e", "#00c7be"]

    /// Teaching and admin languages offered in pickers.
    public static let languages: [(code: String, name: String)] = [("en", "English"), ("de", "German")]

    public static func languageName(_ code: String) -> String {
        languages.first { $0.code == code }?.name
            ?? Locale(identifier: "en").localizedString(forLanguageCode: code)
            ?? code
    }

    /// Names typed into one field: lines, ";" or "," separate them.
    public static func names(from text: String) -> [String] {
        text.split(whereSeparator: { $0.isNewline || $0 == ";" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The mail rules a new course starts with: "Sender is" each lecturer's name (without
    /// academic titles) and "LMS course is" "<name> (<semester>)", as LMS writes the course
    /// path ("Data Centers (WS 2026/27)").
    public static func mailRules(for course: Course, semester: Semester?) -> [MailRule] {
        var rules: [MailRule] = []
        for name in course.professors.map(plainName) where !name.isEmpty {
            guard !rules.contains(where: { $0.pattern.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            rules.append(MailRule(courseID: course.id, kind: .sender, pattern: name, sortOrder: rules.count, createdAt: course.createdAt))
        }
        let semesterName = semester?.name.trimmingCharacters(in: .whitespaces) ?? ""
        let lms = semesterName.isEmpty ? course.name : "\(course.name) (\(semesterName))"
        rules.append(MailRule(courseID: course.id, kind: .platformCourse, pattern: lms, sortOrder: rules.count, createdAt: course.createdAt))
        return rules
    }

    /// "Prof. Dr. Ada Example" → "Ada Example": a name without academic titles.
    public static func plainName(_ name: String) -> String {
        let titles: Set<String> = [
            "prof", "prof.", "dr", "dr.", "dr.-ing.", "dr.-ing", "dr.rer.nat.", "dr.phil.", "dipl.-inf.", "dipl.-ing.",
            "pd", "apl.", "jun.-prof.", "juniorprof.", "m.sc.", "b.sc.", "msc", "bsc", "mr", "mr.", "ms", "ms.", "mrs", "mrs.",
            "habil.", "h.c.", "em.",
        ]
        let words = name.split(whereSeparator: \.isWhitespace).map(String.init)
        let kept = words.drop { titles.contains($0.lowercased()) }
        return kept.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }

    /// "Computational Linguistics" → "CL": the initials of the capitalised words.
    public static func shortName(for name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "/" })
        let initials = words.compactMap { word -> Character? in
            guard let first = word.first, first.isUppercase || first.isNumber else { return nil }
            return first
        }
        return initials.count >= 2 ? String(initials) : String(name.prefix(3))
    }
}

/// Creates and updates courses. Creating goes through the same path for the New Course sheet,
/// the capture sheet and tests.
public struct CourseLibrary: Sendable {
    public let services: StudyServices
    private let store: RecordStore

    public init(services: StudyServices) {
        self.services = services
        store = services.records
    }

    public init(services: StudyServices, store: RecordStore) {
        self.services = services
        self.store = store
    }

    /// Saves a new course from `draft` (in the draft's semester, else the current one; next
    /// palette colour unless one is set; consent stamped `now` when `records`), in one
    /// transaction.
    @discardableResult
    public func create(_ draft: CourseDraft, now: Date = Date()) async throws -> Course {
        guard draft.isValid else { throw CourseLibraryError.missingName }
        let store = store
        return try await services.database.write { db in
            try Self.insert(draft, now: now, consentAt: now, store: store, db: db)
        }
    }

    /// Saves a new course from `draft` inside the caller's transaction (`create`, AppAgent's
    /// change log for `add_course`): the same semester, colour, order and mail rules as the New
    /// Course sheet.
    public static func insert(_ draft: CourseDraft, now: Date, consentAt: Date, store: RecordStore, db: Database) throws -> Course {
        let courses = try Course.all.fetchAll(db)
        let semester: Semester
        if let id = draft.semesterID, let chosen = try Semester.find(id).fetchOne(db) {
            semester = chosen
        } else {
            semester = SemesterChoice.pick(from: try Semester.all.fetchAll(db), on: now)
        }
        let used = Set(courses.map { $0.colorHex.lowercased() })
        let color = draft.colorHex
            ?? CourseDraft.palette.first { !used.contains($0) }
            ?? CourseDraft.palette[courses.count % CourseDraft.palette.count]
        let short = draft.shortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let course = store.stamp(Course(
            name: draft.trimmedName,
            shortName: short.isEmpty ? CourseDraft.shortName(for: draft.trimmedName) : short,
            professors: draft.professors,
            language: draft.language,
            adminLanguage: draft.adminLanguage,
            colorHex: color,
            recordingConsentAt: draft.records ? consentAt : nil,
            sortOrder: (courses.map(\.sortOrder).max() ?? -1) + 1,
            semesterID: semester.id,
            rules: draft.rules,
            showsInCalendar: draft.showsInCalendar,
            createdAt: now,
            credits: draft.credits
        ))
        try Course.upsert { course }.execute(db)
        for rule in CourseDraft.mailRules(for: course, semester: semester) {
            let stamped = store.stamp(rule)
            try MailRule.upsert { stamped }.execute(db)
        }
        return course
    }

    /// Saves a changed course. When its semester changed, its sessions are replanned in the same
    /// transaction.
    @discardableResult
    public func save(_ course: Course, now: Date = Date()) async throws -> Course {
        let store = store
        return try await services.database.write { db in
            let previous = try Course.find(course.id).fetchOne(db)
            let stamped = store.stamp(course)
            try Course.upsert { stamped }.execute(db)
            if previous?.semesterID != course.semesterID {
                try CourseSchedule.replan(courseID: course.id, now: now, planner: SessionPlanner(), store: store, db: db)
            }
            return stamped
        }
    }

    /// Records or withdraws recording consent.
    @discardableResult
    public func setRecordingConsent(_ granted: Bool, courseID: Course.ID, now: Date = Date()) async throws -> Course? {
        guard var course = try await store.fetch(Course.self, id: courseID) else { return nil }
        guard course.recordsLectures != granted else { return course }
        course.recordingConsentAt = granted ? now : nil
        return try await store.save(course)
    }
}

public enum CourseLibraryError: Error, Equatable {
    case missingName
}

extension CourseLibraryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingName: String(localized: "A course needs a name.")
        }
    }
}

/// Matches a recording to the session it was made in (smart import, live capture).
public enum SessionMatch {
    /// A recording may start this long before a session, or after its start.
    public static let tolerance: TimeInterval = 30 * 60

    /// The non-cancelled session whose start is within ±30 min of `start` (or which was running
    /// at `start`), nearest start first.
    public static func session(forRecordingAt start: Date, in sessions: [LectureSession], tolerance: TimeInterval = tolerance) -> LectureSession? {
        sessions
            .filter { session in
                guard !session.isCancelled else { return false }
                let distance = abs(start.timeIntervalSince(session.startsAt))
                return distance <= tolerance || (session.startsAt <= start && start < session.endsAt)
            }
            .min { lhs, rhs in
                let lhsDistance = abs(start.timeIntervalSince(lhs.startsAt))
                let rhsDistance = abs(start.timeIntervalSince(rhs.startsAt))
                return lhsDistance == rhsDistance ? lhs.id.uuidString < rhs.id.uuidString : lhsDistance < rhsDistance
            }
    }
}
