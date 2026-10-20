import Foundation
import GRDB
import StudyCore

/// The student's courses as short tokens ("c1", "c2", …) for prompts: the model answers with a
/// token, and only a token in this directory becomes a course (anything else is "other").
struct CourseDirectory: Sendable {
    struct Entry: Sendable {
        var token: String
        var course: Course
        var rules: [MailRule]
    }

    var entries: [Entry]

    init(courses: [Course], rules: [MailRule]) {
        entries = courses.enumerated().map { index, course in
            Entry(token: "c\(index + 1)", course: course, rules: rules.filter { $0.courseID == course.id })
        }
    }

    static func load(_ db: Database) throws -> CourseDirectory {
        let courses = try Course.order { ($0.sortOrder, $0.name) }.fetchAll(db)
        let rules = try MailRule.where { $0.origin.eq(MailRuleOrigin.user) }.fetchAll(db)
        return CourseDirectory(courses: courses, rules: rules)
    }

    static func load(_ database: any DatabaseReader) async throws -> CourseDirectory {
        try await database.read { db in try load(db) }
    }

    func course(token: String?) -> Course? {
        guard let token = token?.trimmingCharacters(in: .whitespaces).lowercased(), !token.isEmpty else { return nil }
        return entries.first { $0.token == token }?.course
    }

    func token(for courseID: Course.ID?) -> String? {
        guard let courseID else { return nil }
        return entries.first { $0.course.id == courseID }?.token
    }

    func course(_ id: Course.ID?) -> Course? {
        guard let id else { return nil }
        return entries.first { $0.course.id == id }?.course
    }

    /// One line per course for a system prompt.
    var promptLines: String {
        guard !entries.isEmpty else { return "(no courses yet)" }
        return entries.map { entry in
            let course = entry.course
            var parts = ["\(entry.token): \(course.name)"]
            if !course.shortName.isEmpty { parts[0] += " (\(course.shortName))" }
            if !course.professors.isEmpty { parts.append("lecturers: \(course.professors.joined(separator: ", "))") }
            parts.append("teaching language: \(course.language), admin language: \(course.adminLanguage)")
            let rules = entry.rules.prefix(6).map(Self.describe)
            if !rules.isEmpty { parts.append("known mail: \(rules.joined(separator: "; "))") }
            return "- " + parts.joined(separator: "; ")
        }
        .joined(separator: "\n")
    }

    static func describe(_ rule: MailRule) -> String {
        switch rule.kind {
        case .sender: "sender contains \"\(rule.pattern)\""
        case .listID: "mailing list \"\(rule.pattern)\""
        case .subject: "subject contains \"\(rule.pattern)\""
        case .platformCourse: "\(UniversityProfile.current.platformName) course \"\(rule.pattern)\""
        default: "\(rule.kind.rawValue) \"\(rule.pattern)\""
        }
    }
}
