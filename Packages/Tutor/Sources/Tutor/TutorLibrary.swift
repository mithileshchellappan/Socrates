import Agent
import ClaudeKit
import Deadlines
import Foundation
import os
import StudyCore

/// The lectures as the tutor's tools and context blocks name them: "DC L2", the lecture's key
/// (`ChatCitation.key`, the first 8 hex of its id), its recordings (oldest first: a moment marker
/// without a recording key is on the first) and its deck. Read once per tool call (a few dozen
/// rows).
struct TutorLibrary: Sendable {
    let courses: CourseList
    /// In course order, then by number.
    let lectures: [Lecture]
    let recordings: [Lecture.ID: [Recording]]
    /// The lecture's deck: the newest coarse span's (as Review opens it).
    let decks: [Lecture.ID: Deck]

    static func load(_ database: any DatabaseReader) async throws -> TutorLibrary {
        let courses = try await CourseList.load(database)
        let rows = try await database.read { db in
            (
                lectures: try Lecture.all.fetchAll(db),
                recordings: try Recording.where { $0.lectureID.isNot(nil) }.order(by: \.startedAt).fetchAll(db),
                spans: try LectureDeckSpan.where { $0.startTime.is(nil) }.order(by: \.updatedAt).fetchAll(db),
                decks: try Deck.all.fetchAll(db)
            )
        }
        let order = Dictionary(courses.courses.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let lectures = rows.lectures.sorted { lhs, rhs in
            let left = order[lhs.courseID] ?? Int.max
            let right = order[rhs.courseID] ?? Int.max
            if left != right { return left < right }
            if lhs.number != rhs.number { return (lhs.number ?? Int.max) < (rhs.number ?? Int.max) }
            return (lhs.heldAt ?? .distantFuture) < (rhs.heldAt ?? .distantFuture)
        }
        var recordings: [Lecture.ID: [Recording]] = [:]
        for recording in rows.recordings {
            if let lectureID = recording.lectureID { recordings[lectureID, default: []].append(recording) }
        }
        let deckByID = Dictionary(rows.decks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var decks: [Lecture.ID: Deck] = [:]
        for span in rows.spans {
            if let deck = deckByID[span.deckID] { decks[span.lectureID] = deck }
        }
        return TutorLibrary(courses: courses, lectures: lectures, recordings: recordings, decks: decks)
    }

    func lecture(id: Lecture.ID?) -> Lecture? {
        guard let id else { return nil }
        return lectures.first { $0.id == id }
    }

    /// A lecture and, when the reference names one, a recording of it.
    struct Reference: Sendable {
        var lecture: Lecture
        var recording: Recording?
    }

    /// The lecture a reference names: its key ("9a7d94d1", or "9a7d94d1/b680d175" with a recording
    /// key), a cite marker, course token + number ("DC 2", "DC L2") or its id.
    func lecture(_ reference: String?) -> Reference? {
        guard var text = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("[["), text.hasSuffix("]]") {
            text = String(text.dropFirst(2).dropLast(2).split(separator: " ").first ?? "")
        }
        if let id = UUID(uuidString: text), let lecture = lecture(id: id) { return Reference(lecture: lecture) }
        let ids = text.lowercased().split(separator: "/", omittingEmptySubsequences: false)
        if (1...2).contains(ids.count), ids.allSatisfy({ $0.count == 8 && $0.allSatisfy(\.isHexDigit) }) {
            let matches = lectures.filter { ChatCitation.key($0.id) == ids[0] }
            guard matches.count == 1, let lecture = matches.first else { return nil }
            guard ids.count == 2 else { return Reference(lecture: lecture) }
            let recordings = (recordings[lecture.id] ?? []).filter { ChatCitation.key($0.id) == ids[1] }
            guard recordings.count == 1 else { return nil }
            return Reference(lecture: lecture, recording: recordings.first)
        }
        // Course token + number: "DC 2", "DC L2", "CC2", "DC Lecture 2".
        let digits = String(text.reversed().prefix { $0.isASCII && $0.isNumber }.reversed())
        guard let number = Int(digits) else { return nil }
        var head = text.dropLast(digits.count).trimmingCharacters(in: .whitespaces)
        if courses.course(head) == nil {
            for suffix in ["lecture", "l"] where head.lowercased().hasSuffix(suffix) {
                head = String(head.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard let course = courses.course(head) else { return nil }
        let matches = lectures.filter { $0.courseID == course.id && $0.number == number }
        guard matches.count == 1, let lecture = matches.first else { return nil }
        return Reference(lecture: lecture)
    }

    /// "DC L2" ("DC" alone for a lecture without a number).
    func name(_ lecture: Lecture) -> String {
        let token = courses.token(for: lecture.courseID) ?? "?"
        return lecture.number.map { "\(token) L\($0)" } ?? token
    }

    func firstRecording(_ lectureID: Lecture.ID) -> Recording? {
        recordings[lectureID]?.first
    }

    // MARK: Cites

    /// `[[9a7d94d1 S13]]`.
    func slideCite(_ lectureID: Lecture.ID, page: Int) -> String {
        ChatCitation.slide(lectureID, page: page).marker
    }

    /// `[[9a7d94d1 37:59]]`, or `[[9a7d94d1/b680d175 37:59]]` on a recording other than the
    /// lecture's first.
    func momentCite(_ lectureID: Lecture.ID, recording: Recording.ID?, seconds: Double) -> String {
        let other = recording.flatMap { $0 == firstRecording(lectureID)?.id ? nil : $0 }
        return ChatCitation.moment(lectureID, recording: other, seconds: seconds).marker
    }

    /// "YYYY-MM-DD" in Exampleton.
    static func day(_ date: Date?) -> String? {
        date.map { CalendarDay($0, in: DeadlinesModule.timeZone).rawValue }
    }
}

/// Tool results: compact JSON, at most `limit` characters.
enum TutorJSON {
    static let limit = 4_000

    /// `base` with `rows` under `key`, as many as fit in `limit` characters (then `"more": n`, the
    /// number left out).
    static func fitted(_ base: JSONObject, key: String, rows: [JSONValue]) -> ToolOutput {
        var count = rows.count
        while true {
            var object = base
            object[key] = .array(Array(rows.prefix(count)))
            if count < rows.count { object["more"] = .int(rows.count - count) }
            let text = (try? JSONValue.object(object).serializedString()) ?? "{}"
            if text.count <= limit { return .text(text) }
            guard count > 0 else { return .error("The result is too long; ask for less.") }
            // Drop about as many rows as the excess needs, at least one.
            let average = max(1, text.count / max(count, 1))
            count = max(0, count - max(1, (text.count - limit) / average))
        }
    }

    /// One object, its fields already clipped.
    static func object(_ object: JSONObject) -> ToolOutput {
        let text = (try? JSONValue.object(object).serializedString()) ?? "{}"
        return text.count <= limit ? .text(text) : .error("The result is too long; ask for less.")
    }

    /// At most `count` characters, "…" when cut; whitespace runs as one space.
    static func clip(_ text: String, _ count: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > count else { return flat }
        return String(flat.prefix(max(0, count - 1))) + "…"
    }

    static func string(_ value: String?) -> JSONValue {
        value.map(JSONValue.string) ?? .null
    }

    /// A closed object schema with every property required (optional values are nullable), as
    /// strict tool inputs want.
    static func schema(_ properties: JSONObject) -> JSONValue {
        [
            "type": "object",
            "additionalProperties": false,
            "required": .array(properties.keys.sorted().map(JSONValue.string)),
            "properties": .object(properties),
        ]
    }

    static func nullable(_ schema: JSONValue) -> JSONValue {
        ["anyOf": [schema, ["type": "null"]]]
    }
}

extension ToolUseBlock {
    /// A trimmed, non-empty string input.
    func text(_ key: String) -> String? {
        guard let value = input[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// An integer input (a whole double too).
    func integer(_ key: String) -> Int? {
        if let value = input[key]?.intValue { return value }
        if let value = input[key]?.doubleValue, value.rounded() == value { return Int(value) }
        return nil
    }
}

enum TutorLog {
    /// Never logs the student's words, slide or transcript text at `.public`.
    static let tutor = Log.logger(category: "tutor")
}
