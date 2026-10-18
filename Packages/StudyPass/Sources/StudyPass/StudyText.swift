import ClaudeKit
import CryptoKit
import Deadlines
import Foundation
import StudyCore

// Text helpers of the study pass: prompt escaping and times, JSON schema pieces, the input hash,
// and the text rules of plan §4 that every stage applies in code (numbers, word counts, exam
// cues, folded spans of slide text).

enum PromptText {
    /// XML-escaped for an element body or attribute (`&`, `<`, `>`, `"`).
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Whitespace runs collapsed to one space, trimmed.
    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `collapsed`, then cut at a word boundary after at most `limit` characters ("…" appended).
    static func clipped(_ text: String, limit: Int) -> String {
        let text = collapsed(text)
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let trimmed = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return trimmed + "…"
    }

    /// "37:27", "1:03:42".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// For German lectures (plan §1): the slide's German key terms stay, in parentheses after the
    /// English. Ends with a space when not empty.
    static func languageNote(german: Bool) -> String {
        guard german else { return "" }
        return "The lecture is in German: after an English technical term, put the slide's German term in "
            + "parentheses when the slide uses one, e.g. \"virtualization (Virtualisierung)\". "
    }

    /// The model's text: entities undone, whitespace collapsed.
    static func answer(_ text: String) -> String {
        collapsed(TranscriptQuote.unescape(text))
    }
}

/// JSON schema pieces for `--json-schema` (every object closed, every property required).
enum SchemaKit {
    static func object(_ properties: JSONObject) -> JSONValue {
        [
            "type": "object",
            "additionalProperties": false,
            "required": .array(properties.keys.sorted().map(JSONValue.string)),
            "properties": .object(properties),
        ]
    }

    static func array(_ items: JSONValue, maxItems: Int? = nil) -> JSONValue {
        var object: JSONObject = ["type": "array", "items": items]
        if let maxItems { object["maxItems"] = .int(maxItems) }
        return .object(object)
    }

    static let string: JSONValue = ["type": "string"]
    static let integer: JSONValue = ["type": "integer"]

    static func enumeration(_ values: [String]) -> JSONValue {
        ["type": "string", "enum": .array(values.map(JSONValue.string))]
    }

    static func nullable(_ schema: JSONValue) -> JSONValue {
        ["anyOf": [schema, ["type": "null"]]]
    }
}

/// A stage's prompt as sent, and the unit's `input_hash`.
struct StudyPrompt: Sendable {
    var system: String
    var schema: JSONValue
    /// The user turn's text (after any images).
    var text: String
    /// What the hash takes instead of `text`: `text` without what never warrants a re-run (the
    /// course's name, the lecturers, the day). Nil: `text` itself.
    var hashedText: String?
    /// Figure slides sent as images before the text (read units).
    var imagePages: [Int] = []
    /// What else the call depends on and the text does not show (the deck file of the images).
    var extraInputs: [String] = []

    /// SHA-256 (hex) of everything that goes into the call (`hashedText` for the text) +
    /// `StudyPass.promptVersion`.
    func inputHash(model: ClaudeModel, effort: Effort) -> String {
        var hasher = SHA256()
        func add(_ part: String) {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        add("v\(StudyPass.promptVersion)")
        add(model.rawValue)
        add(effort.rawValue)
        add(system)
        add((try? schema.serializedString()) ?? "")
        add(hashedText ?? text)
        for page in imagePages { add("image:\(page)") }
        for input in extraInputs { add(input) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The text rules of plan §4.
enum TextRules {
    /// Words as a reader counts them (whitespace separated).
    static func wordCount(_ text: some StringProtocol) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Numbers written with digits ("2003", "3.5", "1,000"), digits only (separators dropped), so
    /// "1,000" and "1.000" compare equal.
    static func numbers(in text: String) -> Set<String> {
        var numbers: Set<String> = []
        var current = ""
        var pendingSeparator = false
        for character in text {
            if character.isASCII, character.isNumber {
                current.append(character)
                pendingSeparator = false
            } else if (character == "." || character == ",") && !current.isEmpty && !pendingSeparator {
                pendingSeparator = true
            } else {
                if !current.isEmpty { numbers.insert(current) }
                current = ""
                pendingSeparator = false
            }
        }
        if !current.isEmpty { numbers.insert(current) }
        return numbers
    }

    /// Every number of `text` appears in one of `sources` (plan §4: "every number in AI text must
    /// appear in its cited lines or slide text").
    static func numbersSupported(_ text: String, by sources: [String]) -> Bool {
        let wanted = numbers(in: text)
        guard !wanted.isEmpty else { return true }
        var found: Set<String> = []
        for source in sources { found.formUnion(numbers(in: source)) }
        return wanted.isSubset(of: found)
    }

    /// AI text within its word limit (a quarter over is tolerated; longer is dropped).
    static func withinWords(_ text: String, limit: Int) -> Bool {
        let count = wordCount(text)
        return count > 0 && count <= limit + limit / 4
    }

    // MARK: Exam cues

    /// A line where the professor points at the exam (DE/EN, plan §3.3): Klausur, Prüfung,
    /// prüfungsrelevant, wichtig, merken, exam, important, you should know, will be asked,
    /// relevant, test. "exam" and "relevant" are whole words ("example", "examine" and
    /// "relevance" are no cue); Klausur, Prüfung and wichtig match as prefixes.
    static func isExamCue(_ text: String) -> Bool {
        let words = TextFolding.words(text)
        for word in words {
            if examWords.contains(word) { return true }
            if examPrefixes.contains(where: { word.hasPrefix($0) }) { return true }
        }
        let folded = " " + words.joined(separator: " ") + " "
        return examPhrases.contains { folded.contains($0) }
    }

    static let examWords: Set<String> = [
        "merken", "merkt", "merke", "test", "tests", "important",
        // "exam-relevant" folds to "exam" + "relevant".
        "exam", "exams", "examination", "examinations", "examen",
        "relevant", "relevante", "relevanten", "relevanter", "relevantes",
    ]
    static let examPrefixes = ["klausur", "prufung", "wichtig"]
    static let examPhrases = [" you should know ", " you need to know ", " will be asked ", " should remember "]

    // MARK: Folded spans

    /// The original span of `needle` in `text`, compared case- and diacritic-insensitively with
    /// whitespace and typography normalized (`NormalizedText`); nil when absent.
    static func foldedSpan(of needle: String, in text: String) -> String? {
        let haystack = NormalizedText(text)
        let pattern = NormalizedText(needle).characters.map(fold)
        let characters = haystack.characters.map(fold)
        guard !pattern.isEmpty, pattern.count <= characters.count else { return nil }
        var start = 0
        while start <= characters.count - pattern.count {
            if characters[start] == pattern[0] {
                var offset = 1
                while offset < pattern.count, characters[start + offset] == pattern[offset] { offset += 1 }
                if offset == pattern.count {
                    let lower = haystack.sources[start].lowerBound
                    let upper = haystack.sources[start + pattern.count - 1].upperBound
                    return String(text[lower..<upper])
                }
            }
            start += 1
        }
        return nil
    }

    private static func fold(_ character: Character) -> String {
        String(character).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    // MARK: Edit distance

    /// Levenshtein distance of the folded texts over the longer one's length (0 = equal).
    static func normalizedEditDistance(_ first: String, _ second: String) -> Double {
        let a = Array(TextFolding.fold(first))
        let b = Array(TextFolding.fold(second))
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 0 }
        guard !a.isEmpty, !b.isEmpty else { return 1 }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return Double(previous[b.count]) / Double(longest)
    }
}

/// Counts what verification dropped, per rule, for one log line (never the text itself).
struct DropLog: Sendable {
    private(set) var counts: [String: Int] = [:]

    mutating func drop(_ rule: String) {
        counts[rule, default: 0] += 1
    }

    var summary: String {
        counts.isEmpty ? "none" : counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
}
