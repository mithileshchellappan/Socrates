import ClaudeKit
import Foundation
import StudyCore

/// The Haiku extraction request: one message, items with an exact quote each.
enum ExtractionPrompt {
    static let model: ClaudeModel = .haiku55
    static let effort: Effort = .medium
    static let maxTokens = 8_000
    /// Items the model is less sure of are dropped.
    static let minimumConfidence = 0.5

    struct Answer: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            var kind: String
            var title: String
            var course: String?
            var due: String?
            var allDay: Bool
            var room: String?
            var quote: String
            var confidence: Double

            enum CodingKeys: String, CodingKey {
                case kind, title, course, due, room, quote, confidence
                case allDay = "all_day"
            }
        }

        var items: [Item]
    }

    static let kinds = ["deadline", "exercise", "exam", "event", "room_change", "cancellation", "announcement"]

    static var schema: JSONValue {
        Schemas.object([
            "items": [
                "type": "array",
                "items": Schemas.object([
                    "kind": Schemas.stringEnum(kinds),
                    "title": ["type": "string"],
                    "course": Schemas.nullable(["type": "string"]),
                    "due": Schemas.nullable(["type": "string"]),
                    "all_day": ["type": "boolean"],
                    "room": Schemas.nullable(["type": "string"]),
                    "quote": ["type": "string"],
                    "confidence": ["type": "number"],
                ]),
            ]
        ])
    }

    static func system(courses: CourseDirectory) -> String {
        """
        You read one university mail of a university student at Example \
        University and list what the student must not miss. Kinds:
        - deadline: something to submit, fill in, register for or do by a date (quiz, survey, form, registration).
        - exercise: an exercise sheet or assignment with a due date.
        - exam: an exam date, or the period to register for an exam.
        - event: a dated meeting that is not due work (first tutorial, info session, a talk).
        - room_change: a lecture, exercise or tutorial session takes place in another room; put the new room in "room".
        - cancellation: a session is cancelled.
        - announcement: something else the student needs to know from this mail that has no date to act on. \
        List it only when it matters (rules, requirements, changes); not greetings, signatures or ads.

        For every item:
        - quote: copy, character for character, the shortest sentence or phrase of the mail that states the \
        item and its date and time (at most 300 characters; no paraphrase, no ellipsis, no added words).
        - due: the date in the university's time zone (Europe/Lisbon) as "YYYY-MM-DDTHH:MM", or "YYYY-MM-DD" with all_day \
        true when the mail gives no time; for room changes and cancellations the session's date. Resolve \
        relative dates ("next Friday", "morgen", "bis Mittwoch") against the date of the mail. null when the \
        item has no date.
        - title: a short English title (at most 8 words), e.g. "Online quiz 1", "CL exercise sheet 1".
        - course: the token of the course it is about (list below), else null.
        - confidence: how sure you are that the item is real and correct, from 0 to 1.
        List each thing once. Never list anything the mail does not state. No items: an empty list.

        The student's courses (token: course; lecturers; languages; mail already known to belong to it):
        \(courses.promptLines)

        \(MailEnvelope.dataRule)
        """
    }

    static func request(message: MailMessage, courses: CourseDirectory, now: Date) -> MessageRequest {
        var attributes: KeyValuePairs<String, String> = [:]
        if let token = courses.token(for: message.courseID) {
            attributes = ["course": token]
        }
        let envelope = MailEnvelope.render(message, id: "m1", budget: MailEnvelope.Budget.extraction, extraAttributes: attributes)
        let text = "Today is \(MailEnvelope.dateText(now)). List the items of this mail.\n\n\(envelope)"
        return MessageRequest(
            model: model, maxTokens: maxTokens, effort: effort,
            messages: [.user(text)],
            system: MessageRequest.systemPrompt(system(courses: courses)),
            outputFormat: .jsonSchema(schema)
        )
    }
}
