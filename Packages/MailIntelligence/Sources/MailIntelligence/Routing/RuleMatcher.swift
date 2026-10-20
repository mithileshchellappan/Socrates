import Deadlines
import Foundation
import StudyCore

/// The deterministic half of routing: `mail_rule` rows compared with a message, case-insensitive
/// with diacritics folded, as substrings.
///
/// - `sender`: the From address or display name contains the pattern;
/// - `list_id`: the List-Id contains it;
/// - `subject`: the subject contains it;
/// - `platform_course`: a notification of the learning platform (the profile's
///   `learningPlatform`) about that course: a "[Data Centers]" subject tag equal to the pattern
///   (semester suffix such as "(WS 2026/27)" ignored), or the pattern (the course path) in the body
///   of a mail from the platform.
///
/// User rules come before learned ones (`MailRuleRepository.rules()` order) and the first matching
/// user rule wins (confidence 1). Without one, matching learned rules decide when they agree
/// (confidence 0.9); when they disagree the model decides.
struct RuleMatcher: Sendable {
    struct Prepared: Sendable {
        var rule: MailRule
        var pattern: String
        /// The pattern without a semester suffix (the platform's course titles).
        var base: String
    }

    enum Outcome: Sendable {
        case rule(MailRule, confidence: Double)
        /// Learned rules disagree: the model decides.
        case conflict
        case none
    }

    static let userConfidence = 1.0
    static let learnedConfidence = 0.9
    /// How much of a body the platform check reads (the course path is at the top).
    static let bodyPrefix = 4_000

    let rules: [Prepared]
    /// The learning platform's folded name (`UniversityProfile.platformMarker`); "" = none.
    let marker: String

    init(rules: [MailRule], marker: String = UniversityProfile.current.platformMarker) {
        self.marker = marker
        self.rules = rules.compactMap { rule in
            let pattern = Folding.fold(rule.pattern)
            guard !pattern.isEmpty, rule.route != nil else { return nil }
            return Prepared(rule: rule, pattern: pattern, base: Self.withoutSemester(pattern))
        }
    }

    func match(_ message: MailMessage) -> Outcome {
        let fields = Fields(message, marker: marker)
        var learned: [MailRule] = []
        for prepared in rules where Self.matches(prepared, fields) {
            if prepared.rule.origin == .user { return .rule(prepared.rule, confidence: Self.userConfidence) }
            learned.append(prepared.rule)
        }
        guard let first = learned.first else { return .none }
        if learned.contains(where: { $0.route != first.route }) { return .conflict }
        return .rule(first, confidence: Self.learnedConfidence)
    }

    /// User rules that match (corrections never learn what a user rule already says).
    func userRules(matching message: MailMessage) -> [MailRule] {
        let fields = Fields(message, marker: marker)
        return rules.filter { $0.rule.origin == .user && Self.matches($0, fields) }.map(\.rule)
    }

    func matches(_ rule: MailRule, _ message: MailMessage) -> Bool {
        let pattern = Folding.fold(rule.pattern)
        guard !pattern.isEmpty else { return false }
        return Self.matches(Prepared(rule: rule, pattern: pattern, base: Self.withoutSemester(pattern)), Fields(message, marker: marker))
    }

    // MARK: - Matching

    /// A message's folded fields, computed once (the body only when a platform rule asks).
    final class Fields {
        let message: MailMessage
        /// The learning platform's folded name; "" = none (no mail is the platform's).
        let marker: String
        let fromAddress: String
        let fromName: String
        let listID: String
        let subject: String
        private var foldedBody: String?

        init(_ message: MailMessage, marker: String = UniversityProfile.current.platformMarker) {
            self.message = message
            self.marker = marker
            fromAddress = Folding.fold(message.fromAddress)
            fromName = Folding.fold(message.fromName)
            listID = Folding.fold(message.listID)
            subject = Folding.fold(message.subject)
        }

        var body: String {
            if let foldedBody { return foldedBody }
            let folded = Folding.fold(message.bodyText.prefix(RuleMatcher.bodyPrefix))
            foldedBody = folded
            return folded
        }

        /// The mail comes from the learning platform (sender, subject, mailer or its own
        /// "X-<platform>…" headers).
        var isPlatform: Bool {
            guard !marker.isEmpty else { return false }
            let prefix = "x-" + marker
            return fromAddress.contains(marker) || fromName.contains(marker) || subject.contains(marker)
                || message.headers.contains { key, value in
                    key.hasPrefix(prefix) || (key == "x-mailer" && Folding.fold(value).contains(marker))
                }
        }

        /// "[Data Centers]" tags of the subject, folded.
        var subjectTags: [String] {
            var tags: [String] = []
            var current: String?
            for character in subject {
                if character == "[" {
                    current = ""
                } else if character == "]" {
                    if let tag = current?.trimmingCharacters(in: .whitespaces), !tag.isEmpty { tags.append(tag) }
                    current = nil
                } else if current != nil {
                    current?.append(character)
                }
            }
            return tags
        }
    }

    static func matches(_ prepared: Prepared, _ fields: Fields) -> Bool {
        switch prepared.rule.kind {
        case .sender:
            return fields.fromAddress.contains(prepared.pattern) || fields.fromName.contains(prepared.pattern)
        case .listID:
            return !fields.listID.isEmpty && fields.listID.contains(prepared.pattern)
        case .subject:
            return fields.subject.contains(prepared.pattern)
        case .platformCourse:
            for tag in fields.subjectTags {
                if tag == prepared.pattern || (!prepared.base.isEmpty && withoutSemester(tag) == prepared.base) { return true }
            }
            guard fields.isPlatform else { return false }
            return containsPhrase(fields.body, prepared.pattern)
        default:
            return false
        }
    }

    /// `phrase` occurs in `text` at word boundaries.
    static func containsPhrase(_ text: String, _ phrase: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: phrase, range: searchStart..<text.endIndex) {
            let beforeOK = range.lowerBound == text.startIndex || !text[text.index(before: range.lowerBound)].isLetterOrDigit
            let afterOK = range.upperBound == text.endIndex || !text[range.upperBound].isLetterOrDigit
            if beforeOK && afterOK { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }

    /// "data centers (ws 2026/27)" → "data centers".
    static func withoutSemester(_ folded: String) -> String {
        guard folded.hasSuffix(")"), let open = folded.lastIndex(of: "(") else { return folded }
        let inside = folded[folded.index(after: open)..<folded.index(before: folded.endIndex)]
        let semesterWords = ["ws", "ss", "sose", "wise", "wintersemester", "sommersemester", "winter", "summer"]
        guard semesterWords.contains(where: { inside.hasPrefix($0) }) else { return folded }
        return String(folded[..<open]).trimmingCharacters(in: .whitespaces)
    }
}

extension Character {
    var isLetterOrDigit: Bool { isLetter || isNumber }
}
