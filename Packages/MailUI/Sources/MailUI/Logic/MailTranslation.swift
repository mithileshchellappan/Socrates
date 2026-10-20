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

    /// The student's language: the first of their preferred languages, without its region ("en"
    /// from "en-US") but with its script when that is not the language's usual one ("zh-Hant"
    /// from "zh-TW" or "zh-Hant-HK": the models write Traditional and Simplified Chinese apart).
    static var preferred: Locale.Language {
        let first = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
        return Locale.Language(languageCode: first.languageCode ?? .english, script: distinctiveScript(of: first))
    }

    /// The language's script when the language is usually written in another one (Traditional
    /// Chinese, Latin Serbian); nil for the usual script.
    static func distinctiveScript(of language: Locale.Language) -> Locale.Script? {
        guard let code = language.languageCode else { return nil }
        let script = Locale.Language(identifier: language.maximalIdentifier).script
        let usual = Locale.Language(identifier: Locale.Language(languageCode: code).maximalIdentifier).script
        guard let script, script != usual else { return nil }
        return script
    }

    /// The recognizer's name for a language: Chinese by its script, the others by their code.
    static func recognizerLanguage(_ language: Locale.Language) -> NLLanguage? {
        guard let code = language.languageCode?.identifier else { return nil }
        guard code == "zh" else { return NLLanguage(rawValue: code) }
        let script = Locale.Language(identifier: language.maximalIdentifier).script
        return script == .hanTraditional ? .traditionalChinese : .simplifiedChinese
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
        guard let targetLanguage = recognizerLanguage(target), let sourceLanguage = recognizerLanguage(source),
              target.languageCode != source.languageCode, letterCount(text) >= 2 * minimumLetters else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [targetLanguage, sourceLanguage]
        recognizer.processString(String(text.prefix(sampleLength)))
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        return (hypotheses[targetLanguage] ?? 0) >= 0.8
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
/// line as the sender meant it (`MailTextLayout`): the lines their mail program wrapped are one
/// text, so a sentence is translated whole, while list items, quoted lines, the signature and
/// short lines such as a greeting stay lines of their own. A line's indent and list marker stay
/// as written in front of its translation. Lines without letters, a bare link or address, quoted
/// lines and lines already in the target language (the other half of a bilingual mail) stay as
/// they are, with their own line breaks, as do quoted mail and rules. The found block,
/// attachments and drafts are not part of the body. Texts are plain (Marian takes plain text);
/// links are detected again in the translation.
struct MailTranslationInput: Hashable, Sendable {
    /// One line of a block in the translated mail.
    enum Line: Hashable, Sendable {
        /// The line's indent and list marker as written, then the translation of `texts[index]`.
        case translated(Int, prefix: AttributedString)
        /// The original line, kept.
        case kept(AttributedString)
    }

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
            for line in MailTextLayout.lines(of: block.text) {
                let plain = String(line.text.characters)
                if !line.isQuote, !Self.isBareLink(line.text), translatable(plain) {
                    lines.append(.translated(texts.count, prefix: line.prefix))
                    blockOf[texts.count] = index
                    texts.append(plain)
                    translates = true
                } else {
                    lines.append(.kept(line.original))
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
            case .translated(let position, let prefix):
                guard let translated = texts[position] else { return nil }
                text.append(prefix)
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

    /// A line that is one URL or address: translating it would only break it.
    static func isBareLink(_ line: AttributedString) -> Bool {
        let plain = String(line.characters).trimmingCharacters(in: .whitespaces)
        guard !plain.isEmpty, !plain.contains(where: \.isWhitespace) else { return false }
        if line.runs.contains(where: { $0.link != nil }) { return true }
        let lowered = plain.lowercased()
        return lowered.contains("://") || lowered.hasPrefix("www.") || lowered.contains("@")
    }
}

/// A block's text as the lines the sender meant, for translation (local-translate's
/// `chunker.js` keeps a text's layout the same way: what it translates is a line, and the
/// sentences inside it are split by the translator).
///
/// Mail is written in paragraphs separated by blank lines, and a mail program hard-wraps a
/// paragraph at a fixed width (72–78 characters): a line ends early only when its next word
/// would not have fit. So a break after a line that is "full" (the line, a space and the next
/// line's first word are wider than the block's width) is a wrap, and the lines are joined by a
/// space, whatever their length; a break after a shorter line is the sender's own (a greeting,
/// a sign-off, an address), unless the sentence plainly runs on (the line ends without
/// punctuation and the next starts in lowercase: "ich wollte fragen, ob" / "der Termin steht").
/// The block's width is its longest line of at most `maximumWidth` characters (longer lines are
/// not a mail program's: HTML text, a pasted link), and at least `minimumWidth` (a block of
/// short lines is not wrapped).
///
/// Always lines of their own: list items (-, *, •, 1., a)), a wrapped item's continuation
/// joining its item (indented or wrapped), unless the line before runs into it ("…bis zum" /
/// "3. Semester"; "16. Februar 2027" at a line's start is a date, never an item); quoted lines
/// (>); the signature from its "-- " marker on, line by line; lines without letters; and after
/// a line that ends a sentence, a short line ("…statt." / "Viele Grüße").
enum MailTextLayout {
    struct Line: Hashable {
        /// The indent and list marker, as written ("- ", "  1. "); empty when there is none.
        var prefix: AttributedString
        /// The text after the prefix, the wrapped lines joined by a space.
        var text: AttributedString
        /// The line as written: prefix, text and the sender's own line breaks.
        var original: AttributedString
        /// A quoted line ("> …"): earlier mail, which is not translated.
        var isQuote: Bool
    }

    /// A longer line was not wrapped by a mail program.
    static let maximumWidth = 100
    /// A block is never taken to be wrapped narrower than this.
    static let minimumWidth = 60
    /// After a line that ends a sentence, a line this short is the sender's own (a sign-off).
    static let shortLine = 40

    /// "- ", "* ", "• ", "1. ", "2) ", "(3) ", "a) ", "(b) " at the start of a line, after any indent.
    private static let listMarker: NSRegularExpression? = try? NSRegularExpression(
        pattern: "^[ \\t]*(?:[-*•◦▪‣–+]|\\d{1,3}[.)]|\\(\\d{1,3}\\)|[A-Za-z]\\)|\\([A-Za-z]\\))[ \\t]+(?=\\S)"
    )
    /// "16. Februar", "1. Okt." at the start of a line: a wrapped date, not item 16.
    private static let dateStart: NSRegularExpression? = try? NSRegularExpression(
        pattern: "^[ \\t]*\\d{1,2}\\.[ \\t]+(?:jan|jän|feb|mär|mrz|apr|mai|may|jun|jul|aug|sep|okt|oct|nov|dez|dec)",
        options: [.caseInsensitive]
    )
    private static let closers: Set<Character> = [")", "]", "\"", "'", "“", "”", "»", "’"]
    /// Abbreviations whose dot does not end a sentence (lowercased, without the dot).
    private static let abbreviations: Set<String> = [
        "bzw", "usw", "vgl", "ggf", "evtl", "inkl", "zzgl", "ca", "nr", "tel", "str", "dr", "prof", "hr", "fr",
        "etc", "bspw", "sog", "abs", "art", "geb", "mr", "mrs", "ms", "vs", "no", "approx", "dept",
    ]

    static func lines(of text: AttributedString) -> [Line] {
        let ranges = rawLines(of: text)
        let plains: [String] = ranges.map { String(text[$0].characters) }
        let width = wrapWidth(plains)

        var lines: [Line] = []
        var current: Line?
        var currentIsItem = false
        var lastPlain = ""
        var inSignature = false
        func flush() {
            if let current { lines.append(current) }
            current = nil
            currentIsItem = false
        }
        func standalone(_ line: AttributedString, isQuote: Bool) {
            flush()
            lines.append(Line(prefix: AttributedString(), text: line, original: line, isQuote: isQuote))
        }

        for (number, range) in ranges.enumerated() {
            let plain = plains[number]
            let slice = AttributedString(text[range])
            let trimmed = plain.trimmingCharacters(in: .whitespaces)
            if trimmed == "--" {
                inSignature = true
                standalone(slice, isQuote: false)
                continue
            }
            if MailLanguage.letterCount(trimmed) == 0 {
                standalone(slice, isQuote: false)
                continue
            }
            if trimmed.hasPrefix(">") {
                standalone(slice, isQuote: true)
                continue
            }
            let markerLength = isDateStart(plain) ? 0 : listMarkerLength(plain)
            if var line = current, !inSignature {
                let joins: Bool
                let full = isFull(lastPlain, before: plain, width: width)
                if markerLength > 0 {
                    // A marker the line before runs into is a wrapped "3. Semester", not an item.
                    joins = !currentIsItem && full && !endsClause(lastPlain)
                } else if currentIsItem, plain.first?.isWhitespace == true {
                    joins = true
                } else if runsOn(lastPlain, into: trimmed) {
                    joins = true
                } else {
                    joins = full && !(endsClause(lastPlain) && trimmed.count <= shortLine)
                }
                if joins {
                    line.text = trailingTrimmed(line.text)
                    line.text.append(AttributedString(" "))
                    line.text.append(leadingTrimmed(slice))
                    line.original.append(AttributedString("\n"))
                    line.original.append(slice)
                    current = line
                    lastPlain = plain
                    continue
                }
            }
            flush()
            let prefixLength = markerLength > 0 ? markerLength : plain.prefix(while: { $0 == " " || $0 == "\t" }).count
            let split = slice.characters.index(slice.startIndex, offsetBy: prefixLength)
            let prefix = AttributedString(slice[slice.startIndex..<split])
            let rest = AttributedString(slice[split..<slice.endIndex])
            current = Line(prefix: prefix, text: rest, original: slice, isQuote: false)
            currentIsItem = markerLength > 0
            lastPlain = plain
        }
        flush()
        return lines
    }

    /// The ranges of `text`'s lines, without their line breaks.
    private static func rawLines(of text: AttributedString) -> [Range<AttributedString.Index>] {
        var ranges: [Range<AttributedString.Index>] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            if text.characters[index] == "\n" {
                ranges.append(start..<index)
                start = text.characters.index(after: index)
            }
            index = text.characters.index(after: index)
        }
        ranges.append(start..<text.endIndex)
        return ranges
    }

    /// The width the block is wrapped at: its longest line a mail program could have written.
    static func wrapWidth(_ lines: [String]) -> Int {
        var widest = 0
        for line in lines {
            let length = trailingTrimmed(line).count
            if length <= maximumWidth { widest = max(widest, length) }
        }
        return max(widest, minimumWidth)
    }

    /// Whether `line` is full: the next line's first word would not have fit after it.
    static func isFull(_ line: String, before next: String, width: Int) -> Bool {
        let length = trailingTrimmed(line).count
        guard length <= maximumWidth else { return false }
        let nextWord = next.drop(while: { $0.isWhitespace }).prefix(while: { !$0.isWhitespace })
        return length + 1 + nextWord.count > width
    }

    /// Whether `line` ends a sentence or a clause (".", "!", "?", "…", ":"), not an ordinal ("den
    /// 16."), an initial ("z.") or an abbreviation ("bzw.").
    static func endsClause(_ line: String) -> Bool {
        var text = Substring(trailingTrimmed(line))
        while let last = text.last, closers.contains(last) { text.removeLast() }
        guard let last = text.last else { return false }
        if last == "!" || last == "?" || last == "…" || last == ":" { return true }
        guard last == "." else { return false }
        var word = String(text.dropLast().split(whereSeparator: { $0.isWhitespace }).last ?? "")
        while let first = word.first, first == "(" || first == "\"" || first == "„" || first == "“" { word.removeFirst() }
        if word.isEmpty { return true }
        if word.count <= 3, word.allSatisfy({ $0.isASCII && $0.isNumber }) { return false }
        if word.count == 1 || word.contains(".") { return false }
        return !abbreviations.contains(word.lowercased())
    }

    /// Whether the sentence plainly runs on from `line` into `next`: `line` ends in a letter or
    /// digit (no punctuation, so not a greeting or sign-off with its comma) and `next` starts in
    /// lowercase.
    static func runsOn(_ line: String, into next: String) -> Bool {
        guard let last = trailingTrimmed(line).last, last.isLetter || last.isNumber else { return false }
        guard let first = next.first else { return false }
        return first.isLowercase
    }

    /// Whether the line starts with a day and a month ("16. Februar 2027").
    static func isDateStart(_ line: String) -> Bool {
        guard let dateStart else { return false }
        let range = NSRange(location: 0, length: (line as NSString).length)
        return dateStart.firstMatch(in: line, range: range) != nil
    }

    /// The length of the line's indent and list marker with the space after it; 0 when it is
    /// not a list item.
    static func listMarkerLength(_ line: String) -> Int {
        guard let listMarker else { return 0 }
        let ns = line as NSString
        guard let match = listMarker.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return 0 }
        return ns.substring(with: match.range).count
    }

    private static func trailingTrimmed(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return String(result)
    }

    private static func trailingTrimmed(_ text: AttributedString) -> AttributedString {
        var end = text.endIndex
        while end > text.startIndex {
            let before = text.characters.index(before: end)
            guard text.characters[before].isWhitespace else { break }
            end = before
        }
        return AttributedString(text[text.startIndex..<end])
    }

    private static func leadingTrimmed(_ text: AttributedString) -> AttributedString {
        var start = text.startIndex
        while start < text.endIndex, text.characters[start].isWhitespace {
            start = text.characters.index(after: start)
        }
        return AttributedString(text[start..<text.endIndex])
    }
}
