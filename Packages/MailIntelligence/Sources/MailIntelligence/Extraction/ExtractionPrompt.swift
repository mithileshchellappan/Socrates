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

    /// The answer for one mail of the batch.
    struct MailAnswer: Decodable, Sendable {
        /// The envelope's id ("m1").
        var id: String
        /// The mail directly asks this student for an answer or a decision.
        var needsReply: Bool
        var items: [Item]

        enum CodingKeys: String, CodingKey {
            case id, items
            case needsReply = "needs_reply"
        }
    }

    struct Answer: Decodable, Sendable {
        var mails: [MailAnswer]
    }

    static let kinds = ["deadline", "exercise", "exam", "event", "room_change", "cancellation", "announcement", "task"]
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
        - room_change: a lecture, exercise or tutorial session takes place in another room; put the new room in "room".
        - cancellation: a session is cancelled.
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
