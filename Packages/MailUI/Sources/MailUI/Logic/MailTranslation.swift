import Foundation
import NaturalLanguage

/// Which language a mail is in, and whether the reader offers to translate it.
enum MailLanguage {
    /// The recognizer must be at least this sure of a text's language.
    static let minimumConfidence = 0.6
    /// Fewer letters say too little about the language (a subject like "Quiz 1").
    static let minimumLetters = 20
    /// The recognizer reads at most this much of a mail.
    static let sampleLength = 2_000

    /// The student's language: the first of their preferred languages.
    static var preferred: Locale.Language {
        // The language only ("en" from "en-US"): the region is not part of the target.
        let first = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
        return Locale.Language(languageCode: first.languageCode ?? .english)
    }

    /// The dominant language of the mail's own text (the subject and the blocks that are not quoted
    /// earlier mail), when the recognizer is sure enough. Runs off the main actor.
    static func dominant(subject: String, body: MailBody) async -> Locale.Language? {
        var own = body.blocks.filter { !$0.isQuoted }
        if own.isEmpty { own = body.blocks }
        let text = ([subject] + own.map { String($0.text.characters) }).joined(separator: "\n")
        return dominant(of: text)
    }

    /// The dominant language of `text`, when the recognizer is sure enough.
    static func dominant(of text: String) -> Locale.Language? {
        let sample = String(text.prefix(sampleLength))
        guard letterCount(sample) >= minimumLetters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              best.key != .undetermined, best.value >= minimumConfidence else { return nil }
        return Locale.Language(identifier: best.key.rawValue)
    }

    /// The language to translate a mail from: its own, when that is not the student's.
    static func translationSource(of language: Locale.Language?, for target: Locale.Language) -> Locale.Language? {
        guard let language, let code = language.languageCode else { return nil }
        return code == target.languageCode ? nil : language
    }

    /// Whether `text` is a paragraph already in `target` rather than `source` (the English half of
    /// a bilingual mail). Only sentences count: a short line ("Ihr Data-Centers-Team") is
    /// translated anyway, which costs nothing when it is already in `target`.
    static func isIn(_ target: Locale.Language, notIn source: Locale.Language, _ text: String) -> Bool {
        guard let targetCode = target.languageCode?.identifier, let sourceCode = source.languageCode?.identifier,
              targetCode != sourceCode, letterCount(text) >= 2 * minimumLetters else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [NLLanguage(rawValue: targetCode), NLLanguage(rawValue: sourceCode)]
        recognizer.processString(String(text.prefix(sampleLength)))
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        return (hypotheses[NLLanguage(rawValue: targetCode)] ?? 0) >= 0.8
    }

    static func letterCount(_ text: String) -> Int {
        text.unicodeScalars.lazy.filter { CharacterSet.letters.contains($0) }.count
    }
}

/// A mail as the reader shows it translated: the subject and the body with the translations in
/// place of the original text.
struct MailTranslatedMail: Hashable, Sendable {
    var subject: String
    var body: MailBody
}

/// What the reader hands the translator for one mail, and how the translations go back in place.
///
/// The subject is one text. Each body block that is not quoted earlier mail gives one text per
/// line, except that a line the sender's mail program wrapped (at least `wrapLength` long)
/// continues on the next, so a sentence is translated whole; the lines are joined again with the
/// same breaks. Lines without letters, a bare link or address, and lines already in the target
/// language (the other half of a bilingual mail) stay as they are, as do quoted mail and rules.
/// The found block, attachments and drafts are not part of the body. Texts are plain (Marian
/// takes plain text); links are detected again in the translation.
struct MailTranslationInput: Hashable, Sendable {
    /// One line of a block in the translated mail.
    enum Line: Hashable, Sendable {
        /// The translation of `texts[index]`.
        case translated(Int)
        /// The original line, kept.
        case kept(AttributedString)
    }

    /// A line break after a line this long is the sender's mail program wrapping a paragraph.
    static let wrapLength = 60

    /// The texts to translate, in order: the subject (when it has letters), then the body's lines.
    private(set) var texts: [String] = []
    /// Where the subject's translation is in `texts`.
    private(set) var subjectIndex: Int?
    /// The lines of each body block (by index in `MailBody.blocks`) that has something to translate.
    private(set) var blocks: [Int: [Line]] = [:]
    /// The block (index in `MailBody.blocks`) each body text belongs to, by text index.
    private(set) var blockOf: [Int: Int] = [:]

    /// - Parameters:
    ///   - source: The mail's language; with `target`, lines already in `target` are kept.
    init(subject: String, body: MailBody, source: Locale.Language? = nil, target: Locale.Language? = nil) {
        func translatable(_ text: String) -> Bool {
            guard MailLanguage.letterCount(text) > 0 else { return false }
            if let source, let target, MailLanguage.isIn(target, notIn: source, text) { return false }
            return true
        }
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if translatable(trimmedSubject) {
            subjectIndex = texts.count
            texts.append(trimmedSubject)
        }
        for (index, block) in body.blocks.enumerated() where !block.isQuoted && block.kind != .rule {
            var lines: [Line] = []
            var translates = false
            for line in Self.lines(of: block.text) {
                let plain = String(line.characters)
                if !Self.isBareLink(line), translatable(plain) {
                    lines.append(.translated(texts.count))
                    blockOf[texts.count] = index
                    texts.append(plain)
                    translates = true
                } else {
                    lines.append(.kept(line))
                }
            }
            if translates { blocks[index] = lines }
        }
    }

    /// Block `index` with its translated lines (`texts`, by text index) in place of the original
    /// ones, marked translated; nil until every line of the block is back. The block keeps the
    /// original's id, kind, indent and quoting; links are detected again in each translated line.
    func translatedBlock(_ index: Int, original: MailBlock, texts: [Int: String]) -> MailBlock? {
        guard let lines = blocks[index] else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var text = AttributedString()
        for (number, line) in lines.enumerated() {
            if number > 0 { text.append(AttributedString("\n")) }
            switch line {
            case .translated(let position):
                guard let translated = texts[position] else { return nil }
                text.append(MailBodyRenderer.detectingLinks(in: AttributedString(translated), detector: detector))
            case .kept(let kept):
                text.append(kept)
            }
        }
        var block = original
        block.text = text
        block.isTranslated = true
        return block
    }

    /// A block's lines, with the sender's wrapped lines joined into one (by a space). Empty lines
    /// stay lines of their own.
    static func lines(of text: AttributedString) -> [AttributedString] {
        var raw: [AttributedSubstring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            if text.characters[index] == "\n" {
                raw.append(text[start..<index])
                start = text.characters.index(after: index)
            }
            index = text.characters.index(after: index)
        }
        raw.append(text[start..<text.endIndex])

        var lines: [AttributedString] = []
        var continues = false
        for line in raw {
            let length = String(line.characters).trimmingCharacters(in: .whitespaces).count
            if continues, length > 0, var last = lines.last {
                if last.characters.last?.isWhitespace != true { last.append(AttributedString(" ")) }
                last.append(AttributedString(line))
                lines[lines.count - 1] = last
            } else {
                lines.append(AttributedString(line))
            }
            continues = length >= wrapLength
        }
        return lines
    }

    /// A line that is one URL or address: translating it would only break it.
    static func isBareLink(_ line: AttributedString) -> Bool {
        let plain = String(line.characters).trimmingCharacters(in: .whitespaces)
        guard !plain.isEmpty, !plain.contains(where: \.isWhitespace) else { return false }
        if line.runs.contains(where: { $0.link != nil }) { return true }
        let lowered = plain.lowercased()
        return lowered.contains("://") || lowered.hasPrefix("www.") || lowered.contains("@")
    }
}
