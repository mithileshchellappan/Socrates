import ClaudeKit
import Foundation
import StudyCore
import StudyPass

/// Strict output schemas (closed objects, every property required, optional values nullable).
enum CoachSchema {
    static func object(_ properties: JSONObject) -> JSONValue {
        [
            "type": "object",
            "additionalProperties": false,
            "required": .array(properties.keys.sorted().map(JSONValue.string)),
            "properties": .object(properties),
        ]
    }

    static func nullable(_ schema: JSONValue) -> JSONValue { ["anyOf": [schema, ["type": "null"]]] }
    static let string: JSONValue = ["type": "string"]
    static let integer: JSONValue = ["type": "integer"]
    static let number: JSONValue = ["type": "number"]
    static let boolean: JSONValue = ["type": "boolean"]
    static func array(_ items: JSONValue) -> JSONValue { ["type": "array", "items": items] }
    static func oneOf(_ values: [String]) -> JSONValue { ["type": "string", "enum": .array(values.map(JSONValue.string))] }

    /// A label diagram: stacks of rows of boxes.
    static var diagram: JSONValue {
        object([
            "stacks": array(object([
                "title": string,
                "rows": array(array(object(["text": string, "blank": boolean]))),
            ])),
            "terms": array(string),
        ])
    }

    /// One drafted or extracted question.
    static func question(formats: [String], pools: Bool, quote: Bool) -> JSONValue {
        var properties: JSONObject = [
            "format": oneOf(formats),
            "title": string,
            "prompt": string,
            "choices": array(string),
            "correct_choice": nullable(integer),
            "model_answer": string,
            "explanation": string,
            "points": integer,
            "slide": nullable(integer),
            "diagram": nullable(diagram),
        ]
        if pools { properties["pool"] = oneOf(["round", "exam"]) }
        if quote {
            properties["quote"] = string
            properties["line"] = nullable(string)
        }
        return object(properties)
    }
}

/// A question as a model wrote it (drafting, an old exam), before the checks in code.
struct DraftedQuestion: Decodable, Sendable {
    struct Diagram: Decodable, Sendable {
        struct Stack: Decodable, Sendable {
            var title: String
            var rows: [[Box]]
        }

        struct Box: Decodable, Sendable {
            var text: String
            var blank: Bool
        }

        var stacks: [Stack]
        var terms: [String]
    }

    var format: String
    var pool: String?
    var title: String
    var prompt: String
    var choices: [String]
    var correctChoice: Int?
    var modelAnswer: String
    var explanation: String
    var points: Int?
    var slide: Int?
    var quote: String?
    var line: String?
    var diagram: Diagram?

    enum CodingKeys: String, CodingKey {
        case format, pool, title, prompt, choices, explanation, points, slide, quote, line, diagram
        case correctChoice = "correct_choice"
        case modelAnswer = "model_answer"
    }

    /// The checked question (nil when it is unusable): a choice has 4 options and a right one, a
    /// label diagram at least one blank whose text is among the terms, a written one a model
    /// answer; titles at most 6 words; points as an exam counts them.
    func checked(base: StudyQuestion) -> StudyQuestion? {
        var question = base
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        question.format = StudyQuestionFormat(rawValue: format)
        question.prompt = prompt
        question.title = CoachText.words(title.trimmingCharacters(in: .whitespacesAndNewlines), 6)
        question.modelAnswer = modelAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        question.explanation = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        switch question.format {
        case .choice:
            let options = choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard options.count == 4, !options.contains(where: \.isEmpty), let right = correctChoice, (0..<4).contains(right) else { return nil }
            question.choices = options
            question.correctChoice = right
            if question.modelAnswer.isEmpty { question.modelAnswer = options[right] }
            question.points = 2
        case .label:
            guard let diagram else { return nil }
            var stacks: [LabelDiagram.Stack] = []
            for (s, stack) in diagram.stacks.enumerated() {
                let rows = stack.rows.enumerated().map { r, row in
                    row.enumerated().map { b, box in
                        LabelDiagram.Box(id: "s\(s)r\(r)b\(b)", text: box.text.trimmingCharacters(in: .whitespacesAndNewlines), blank: box.blank)
                    }
                }
                stacks.append(LabelDiagram.Stack(title: stack.title, rows: rows))
            }
            let built = LabelDiagram(stacks: stacks, terms: diagram.terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            let blanks = built.blanks
            guard !blanks.isEmpty, blanks.allSatisfy({ box in !box.text.isEmpty && built.terms.contains(box.text) }) else { return nil }
            question.diagram = built
            question.points = blanks.count
        case .short:
            guard !question.modelAnswer.isEmpty else { return nil }
            question.points = 2
        case .explain, .calculation:
            guard !question.modelAnswer.isEmpty else { return nil }
            question.points = min(18, max(10, points ?? 12))
        default:
            return nil
        }
        if base.origin == .oldExam, let points, points > 0 { question.points = points }
        return question
    }
}

/// Quotes as exact spans of a line's `original_text` (plan §4 "Drafting"): checked in code, else
/// dropped (the question keeps its slide).
enum QuoteCheck {
    /// The line and the quote's character offset in it: the named line first, then `candidates`.
    static func locate(_ quote: String?, line id: String?, in candidates: [LectureText.Line], all: [LectureText.Line]) -> (LectureText.Line, String, Int)? {
        guard let quote = quote?.trimmingCharacters(in: .whitespacesAndNewlines), quote.count >= 8 else { return nil }
        var ordered: [LectureText.Line] = []
        if let id = id?.trimmingCharacters(in: .whitespaces).lowercased(), let named = all.first(where: { $0.id == id }) { ordered.append(named) }
        ordered += candidates
        for line in ordered {
            if let range = line.original.range(of: quote) {
                return (line, String(line.original[range]), line.original.distance(from: line.original.startIndex, to: range.lowerBound))
            }
        }
        return nil
    }

    /// Sets the question's quote, line, recording and times when the quote is verified.
    static func apply(_ quote: String?, line: String?, candidates: [LectureText.Line], all: [LectureText.Line], to question: inout StudyQuestion) {
        guard let (found, span, offset) = locate(quote, line: line, in: candidates, all: all) else {
            question.quote = ""
            return
        }
        question.quote = span
        question.transcriptSegmentID = found.segmentID
        question.recordingID = found.recordingID
        question.quoteTime = TranscriptQuoteTime.time(at: offset, in: found)
        question.quoteEnd = found.end
    }
}

/// The moment a character of a line is said (its word's start), else the line's start.
enum TranscriptQuoteTime {
    static func time(at offset: Int, in line: LectureText.Line) -> Double {
        guard !line.words.isEmpty else { return line.start }
        // Words in order; find the word whose text starts at or before the offset.
        var cursor = line.original.startIndex
        var best = line.start
        for word in line.words {
            let text = word.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let range = line.original.range(of: text, range: cursor..<line.original.endIndex) else { continue }
            if line.original.distance(from: line.original.startIndex, to: range.lowerBound) > offset { break }
            best = word.start
            cursor = range.upperBound
        }
        return best
    }
}
