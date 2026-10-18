import ClaudeKit
import Foundation
import StudyCore

/// The Haiku triage request (M3.5): up to six mails per call, one `<mail id="m1">` envelope each;
/// per mail whether it needs a reply from the student and its items, each with an exact quote.
enum ExtractionPrompt {
    static let model: ClaudeModel = .haiku55
    static let effort: Effort = .medium
    /// Output cap per call (covers adaptive thinking and up to six mails' items).
    static let maxTokens = 16_000
    /// Mails per call.
    static let batchSize = 6
    /// Characters of envelopes per call.
    static let batchCharacters = 24_000
    /// Items the model is less sure of are dropped.
    static let minimumConfidence = 0.5

    struct Item: Decodable, Sendable {
        var kind: String
        var title: String
        var course: String?
        var due: String?
        var allDay: Bool
        var room: String?
        /// M3: at most 12 words on why it matters, or "".
        var details: String?
        /// M3: "exam_admission", "bonus" or null.
        var relevance: String?
        var quote: String
        var confidence: Double

        enum CodingKeys: String, CodingKey {
            case kind, title, course, due, room, details, relevance, quote, confidence
            case allDay = "all_day"
        }
    }

    /// ma: a change of one class session the mail states (applied on its own with Undo by the
    /// app agent's change log; replaces M2's room change / cancellation proposals).
    struct SessionChange: Decodable, Sendable {
        /// room, time, cancel, restore, extra.
        var change: String
        var course: String?
        /// The session as it was planned: "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM".
        var sessionDay: String?
        var sessionKind: String?
        /// The new start and end (time changes, extra sessions).
        var startsAt: String?
        var endsAt: String?
        var room: String?
        var quote: String
        var confidence: Double

        enum CodingKeys: String, CodingKey {
            case change, course, room, quote, confidence
            case sessionDay = "session_day"
            case sessionKind = "session_kind"
            case startsAt = "starts_at"
            case endsAt = "ends_at"
        }
    }

    /// ma: a fact about a course the mail states (lecturers, exam admission, exam form, bonus,
    /// exercise rules, attendance).
    struct CourseFact: Decodable, Sendable {
        var course: String?
        var fact: String
        var text: String
        var quote: String
        var confidence: Double
    }

    /// The answer for one mail of the batch.
    struct MailAnswer: Decodable, Sendable {
        /// The envelope's id ("m1").
        var id: String
        /// The mail directly asks this student for an answer or a decision.
        var needsReply: Bool
        var items: [Item]
        /// ma: session changes, course facts, and whether a bigger model must decide.
        var sessions: [SessionChange]
        var facts: [CourseFact]
        var escalate: Bool
        var reason: String

        enum CodingKeys: String, CodingKey {
            case id, items, sessions, facts, escalate, reason
            case needsReply = "needs_reply"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            needsReply = try container.decode(Bool.self, forKey: .needsReply)
            items = try container.decode([Item].self, forKey: .items)
            sessions = try container.decodeIfPresent([SessionChange].self, forKey: .sessions) ?? []
            facts = try container.decodeIfPresent([CourseFact].self, forKey: .facts) ?? []
            escalate = try container.decodeIfPresent(Bool.self, forKey: .escalate) ?? false
            reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        }
    }

    struct Answer: Decodable, Sendable {
        var mails: [MailAnswer]
    }

    /// ma: room changes and cancellations are `sessions` now (applied with Undo, no proposals).
    static let kinds = ["deadline", "exercise", "exam", "event", "announcement", "task"]
    static let sessionChanges = ["room", "time", "cancel", "restore", "extra"]
    static let sessionKinds = ["lecture", "exercise", "tutorial", "seminar"]
    static let facts = ["lecturers", "exam_admission", "exam_form", "bonus", "exercise", "attendance", "other"]
    static let relevances = [ItemRelevance.examAdmission.rawValue, ItemRelevance.bonus.rawValue]

    /// The model's details, at most 12 words.
    static func details(_ text: String?) -> String {
        let words = (text ?? "").split(whereSeparator: \.isWhitespace)
        return words.prefix(12).joined(separator: " ")
    }

    static func relevance(_ text: String?) -> ItemRelevance? {
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(), relevances.contains(text) else { return nil }
        return ItemRelevance(rawValue: text)
    }

    static var schema: JSONValue {
        Schemas.object([
            "mails": [
                "type": "array",
                "items": Schemas.object([
                    "id": ["type": "string"],
                    "needs_reply": ["type": "boolean"],
                    "items": [
                        "type": "array",
                        "items": Schemas.object([
                            "kind": Schemas.stringEnum(kinds),
                            "title": ["type": "string"],
                            "course": Schemas.nullable(["type": "string"]),
                            "due": Schemas.nullable(["type": "string"]),
                            "all_day": ["type": "boolean"],
                            "room": Schemas.nullable(["type": "string"]),
                            "details": ["type": "string"],
                            "relevance": Schemas.nullable(Schemas.stringEnum(relevances)),
                            "quote": ["type": "string"],
                            "confidence": ["type": "number"],
                        ]),
                    ],
                    "sessions": [
                        "type": "array",
                        "items": Schemas.object([
                            "change": Schemas.stringEnum(sessionChanges),
                            "course": Schemas.nullable(["type": "string"]),
                            "session_day": Schemas.nullable(["type": "string"]),
                            "session_kind": Schemas.nullable(Schemas.stringEnum(sessionKinds)),
                            "starts_at": Schemas.nullable(["type": "string"]),
                            "ends_at": Schemas.nullable(["type": "string"]),
                            "room": Schemas.nullable(["type": "string"]),
                            "quote": ["type": "string"],
                            "confidence": ["type": "number"],
                        ]),
                    ],
                    "facts": [
                        "type": "array",
                        "items": Schemas.object([
                            "course": Schemas.nullable(["type": "string"]),
                            "fact": Schemas.stringEnum(facts),
                            "text": ["type": "string"],
                            "quote": ["type": "string"],
                            "confidence": ["type": "number"],
                        ]),
                    ],
                    "escalate": ["type": "boolean"],
                    "reason": ["type": "string"],
                ]),
            ]
        ])
    }

    static func system(courses: CourseDirectory) -> String {
        """
        You read university mails of a university student at Example University. \
        For each mail you decide whether it needs a reply from the student, and you list what the student \
        must not miss.

        needs_reply: true only when the mail directly asks this student, personally, for an answer or a \
        decision: a question to them, a request to confirm, choose, or send something back by mail. false for \
        mail to many recipients (mailing lists, course announcements, circulars), newsletters, automatic \
        notifications, mail that only informs, and closing lines such as "write if you have questions".

        Item kinds:
        - deadline: something to submit, fill in, register for or do by a date (quiz, survey, form, registration).
        - exercise: an exercise sheet or assignment with a due date.
        - exam: an exam date, or the period to register for an exam.
        - event: a dated meeting that is not due work (first tutorial, info session, a talk).
        - task: something the student must do that has no date to do it by (register in a system, fill in a \
        form, bring a laptop, read a text before class). With a date it is a deadline.
        - announcement: something else the student needs to know from this mail that has no date to act on. \
        List it only when it matters (rules, requirements, changes); not greetings, signatures or ads.

        For every item:
        - quote: copy, character for character, the shortest sentence or phrase of the mail that states the \
        item and its date and time (at most 300 characters; no paraphrase, no ellipsis, no added words).
        - due: the date in the university's time zone (Europe/Lisbon) as "YYYY-MM-DDTHH:MM", or "YYYY-MM-DD" with all_day \
        true when the mail gives no time; for room changes and cancellations the session's date. Resolve \
        relative dates ("next Friday", "morgen", "bis Mittwoch") against the date of the mail. null when the \
        item has no date.
        - title: a short English title (at most 8 words), e.g. "Online quiz 1", "CL exercise sheet 1", \
        "Register in the exam portal".
        - course: the token of the course it is about (list below), else null.
        - details: at most 12 words on why it matters or what to do beyond the title, taken from the mail \
        ("Weekly from then on", "Required for exam admission"), else "".
        - relevance: "exam_admission" when the mail says it counts towards admission to the exam, "bonus" \
        when it earns bonus points, else null.
        - confidence: how sure you are that the item is real and correct, from 0 to 1.
        List each thing once. Never list anything a mail does not state. No items: an empty list.

        sessions: changes to the course's class sessions the mail states (they are applied to the student's \
        timetable, so only what the mail clearly says):
        - change: room (another room; the new room in "room"), time (another time or day; the new start and end in \
        starts_at and ends_at as "YYYY-MM-DDTHH:MM"), cancel (it does not take place), restore (a cancelled session \
        takes place after all), extra (an additional session: starts_at, ends_at, room).
        - session_day: the day of the session as it was planned, "YYYY-MM-DDTHH:MM" when the mail gives its time, \
        else "YYYY-MM-DD"; null when the mail names only a week ("next week's lecture") or for an extra session.
        - session_kind: lecture, exercise, tutorial or seminar when the mail says which; course: its token.
        - quote: the mail's exact words that state the change and its day (as for items).

        facts: rules of a course the mail states: lecturers (text: the names, separated by ";"), exam_admission \
        (what admits to the exam), exam_form (written, oral, project, its length), bonus, exercise (how sheets are \
        handed in or graded), attendance, other. text: the rule in at most 20 words; quote: the mail's exact words.

        escalate: true when the mail changes an exam date, cancels an exam, contradicts what the student already \
        has, or is too ambiguous to apply safely (then say why in reason, one short sentence); else false and \
        reason "".

        Answer once for every mail, with its id attribute as id.

        The student's courses (token: course; lecturers; languages; mail already known to belong to it):
        \(courses.promptLines)

        \(MailEnvelope.dataRule)
        """
    }

    /// One mail's envelope in a batch, with the course it is routed to.
    static func envelope(_ message: MailMessage, id: String, courses: CourseDirectory) -> String {
        var attributes: KeyValuePairs<String, String> = [:]
        if let token = courses.token(for: message.courseID) {
            attributes = ["course": token]
        }
        return MailEnvelope.render(message, id: id, budget: MailEnvelope.Budget.extraction, extraAttributes: attributes)
    }

    /// The request for one batch: `envelopes` in order, ids "m1", "m2", ….
    static func request(envelopes: [String], courses: CourseDirectory, now: Date) -> MessageRequest {
        let text = "Today is \(MailEnvelope.dateText(now)). Triage these mails.\n\n" + envelopes.joined(separator: "\n\n")
        return MessageRequest(
            model: model, maxTokens: maxTokens, effort: effort,
            messages: [.user(text)],
            system: MessageRequest.systemPrompt(system(courses: courses)),
            outputFormat: .jsonSchema(schema)
        )
    }
}
