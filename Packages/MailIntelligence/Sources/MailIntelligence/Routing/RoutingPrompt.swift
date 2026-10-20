import ClaudeKit
import Foundation
import StudyCore

/// The Haiku routing request: up to 20 messages per call, courses as short tokens.
enum RoutingPrompt {
    static let model: ClaudeModel = .haiku55
    static let effort: Effort = .low
    static let maxTokens = 6_000
    static let batchSize = 20
    /// Below this the model's answer counts as "other".
    static let minimumConfidence = 0.5

    struct Answer: Decodable, Sendable {
        struct Result: Decodable, Sendable {
            var message: String
            var category: String
            var course: String?
            var confidence: Double
        }

        var results: [Result]
    }

    static let categories = ["course", "university", "newsletter", "personal", "other"]

    static var schema: JSONValue {
        Schemas.object([
            "results": [
                "type": "array",
                "items": Schemas.object([
                    "message": ["type": "string"],
                    "category": Schemas.stringEnum(categories),
                    "course": Schemas.nullable(["type": "string"]),
                    "confidence": ["type": "number"],
                ]),
            ]
        ])
    }

    static func system(courses: CourseDirectory) -> String {
        """
        You sort the university mail of one \(UniversityProfile.current.studentNoun). For each <mail> element \
        decide where the message belongs:
        - course: it is about one of the student's courses listed below; put that course's token in "course".
        - university: university administration and services (\(UniversityProfile.current.officeList), \
        \(UniversityProfile.current.platformName) service notices) that are not about one of the courses.
        - newsletter: mailing lists, newsletters and announcements to many recipients that need nothing \
        from the student.
        - personal: written to the student personally and about none of the courses.
        - other: anything else (spam, automatic notifications of no use).

        The student's courses (token: course; lecturers; languages; mail already known to belong to it):
        \(courses.promptLines)

        Answer with one result per <mail>, using its id attribute as "message". "course" is a token from \
        the list above when the category is course, otherwise null. "confidence" is how sure you are, \
        from 0 to 1.

        \(MailEnvelope.dataRule)
        """
    }

    static func request(messages: [(token: String, message: MailMessage)], courses: CourseDirectory) -> MessageRequest {
        let envelopes = messages.map { MailEnvelope.render($0.message, id: $0.token, budget: MailEnvelope.Budget.routing) }
        let text = "Sort these \(messages.count) messages.\n\n" + envelopes.joined(separator: "\n\n")
        return MessageRequest(
            model: model, maxTokens: maxTokens, effort: effort,
            messages: [.user(text)],
            system: MessageRequest.systemPrompt(system(courses: courses)),
            outputFormat: .jsonSchema(schema)
        )
    }
}
