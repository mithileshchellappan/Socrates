import Foundation
import NaturalLanguage

/// One piece of a text the model translates, with the whitespace that followed it in the
/// original, so `Σ (translation or text) + sep` rebuilds the text's layout.
struct TextUnit: Hashable, Sendable {
    /// What gets translated (trimmed).
    var text: String
    /// The whitespace after it, re-emitted verbatim.
    var sep: String
    /// No letters, or a bare link: passed through untouched.
    var skip: Bool
}

/// local-translate's `chunker.js`: splits a text into model-sized units, one **sentence** per
/// unit (Marian drops sentences when given several), with `NLTokenizer` in place of
/// `Intl.Segmenter`. Not `Sendable`: one per job, used on the translator's actor.
///
/// Two departures from `chunker.js`, both from translating real German mail: a German ordinal
/// ("den 16. Februar", "im 3. Semester") does not end a sentence, and a link or mail address
/// inside a sentence is a unit of its own that is never translated (the model translates a
/// URL's words: "…/studium/rueckmeldung" came back as "…/study/return message"), with the text
/// around it translated on either side.
final class TextChunker {
    private static let blockSeparator: NSRegularExpression? = try? NSRegularExpression(pattern: "[ \\t\\u00A0]*\\n\\s*")
    /// ASCII `, ; :` followed by whitespace, or CJK clause marks.
    private static let clause: NSRegularExpression? = try? NSRegularExpression(pattern: "[,;:](?=\\s)\\s*|[，；：、]\\s*")
    private static let urlish: NSRegularExpression? = try? NSRegularExpression(
        pattern: "^(https?://|www\\.)\\S+$", options: [.caseInsensitive]
    )
    /// A bare mail address (with or without `mailto:`).
    private static let addressish: NSRegularExpression? = try? NSRegularExpression(
        pattern: "^(mailto:)?[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: [.caseInsensitive]
    )
    /// A link or a mail address inside a text.
    private static let link: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\b(?:https?://|www\\.)[^\\s<>\"«»“”„]+|\\b(?:mailto:)?[a-z0-9._%+\\-]+@[a-z0-9\\-]+(?:\\.[a-z0-9\\-]+)*\\.[a-z]{2,}",
        options: [.caseInsensitive]
    )
    /// Punctuation at a link's end that belongs to the sentence ("…/rueckmeldung.").
    private static let linkTrailers: Set<Character> = [".", ",", ";", ":", "!", "?", "'", "\"", "’", "”"]
    private static let hardCutCharacters = 200
    /// Common abbreviations (lowercased, without the dot) across the supported languages.
    private static let abbreviationList: String = """
        mr mrs ms dr prof st jr sr mt vs etc ca no nr nos inc ltd co corp dept est fig vol op ed eds approx \
        bzw usw vgl ggf evtl inkl zzgl mio mrd tel str abs art hr fr dipl ing \
        mme mlle mm env cf sra srta dña dra av pág núm sig \
        sig ecc pag pp ca lt cdr gen col sgt capt
        """
    private static let abbreviations: Set<String> = Set(abbreviationList.split(separator: " ").map { String($0) })
    /// Words before a number that make "<number>." an ordinal ("am 3.", "den 16.", "im 2.").
    private static let ordinalContextList: String = """
        am an ab bis seit vom zum zur im ins beim den dem der des die das ein eine einem einen einer \
        jede jeden jedem jeder jedes ihr ihre ihrem ihren ihrer sein seine seinem seinen seiner \
        unser unsere unserem unseren unserer diese dieser diesem diesen dieses
        """
    private static let ordinalContext: Set<String> = Set(ordinalContextList.split(separator: " ").map { String($0) })
    /// Month names and abbreviations that follow a day ("16. Februar", "1. Okt.").
    private static let monthList: String = """
        januar jänner februar feber märz maerz april mai juni juli august september oktober november dezember \
        jan feb mär mrz apr jun jul aug sep sept okt nov dez \
        january february march may june july october december mar oct dec
        """
    private static let months: Set<String> = Set(monthList.split(separator: " ").map { String($0) })

    private let language: NLLanguage?
    private var sentenceTokenizer: NLTokenizer?
    private var wordTokenizer: NLTokenizer?

    /// - Parameter language: The source language's code (`TranslationRoutes.normalize`), which
    ///   helps sentence segmentation; nil when unknown.
    init(language: String?) {
        self.language = language.map(Self.nlLanguage)
    }

    /// The units of `text`. `countTokens` gives a text's model tokens (ids + EOS); `joiner`
    /// separates sentences inside a block (" ", or "" for scripts without spaces).
    func units(of text: String, maxTokens: Int, joiner: String, countTokens: (String) -> Int) -> [TextUnit] {
        let source = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let ns = source as NSString
        let length = ns.length
        var matches: [NSTextCheckingResult] = []
        if let separator = Self.blockSeparator {
            matches = separator.matches(in: source, range: NSRange(location: 0, length: length))
        }
        var units: [TextUnit] = []
        var pending: TextUnit?
        var position = 0
        var matchIndex = 0
        while true {
            let match: NSTextCheckingResult? = matchIndex < matches.count ? matches[matchIndex] : nil
            let blockEnd: Int = match?.range.location ?? length
            let block = ns.substring(with: NSRange(location: position, length: blockEnd - position))
            var blockSep = ""
            if let match {
                blockSep = ns.substring(with: match.range)
                position = match.range.location + match.range.length
            } else {
                position = length
            }
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // An empty block: its separator folds into the previous unit's.
                if var last = pending, !blockSep.isEmpty {
                    last.sep.append(blockSep)
                    pending = last
                }
            } else {
                let pieces = splitBlock(trimmed, maxTokens: maxTokens, countTokens: countTokens)
                for (index, piece) in pieces.enumerated() {
                    if let pending { units.append(pending) }
                    let isLast = index == pieces.count - 1
                    let sep: String = isLast ? blockSep : (piece.sep ?? joiner)
                    let skip: Bool = piece.isLink || !Self.shouldTranslate(piece.text)
                    pending = TextUnit(text: piece.text, sep: sep, skip: skip)
                }
            }
            if match == nil { break }
            matchIndex += 1
        }
        if let pending { units.append(pending) }
        return units
    }

    static func shouldTranslate(_ text: String) -> Bool {
        guard MarianOutput.hasLetter(text) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let urlish, urlish.firstMatch(in: text, range: range) != nil { return false }
        if let addressish, addressish.firstMatch(in: text, range: range) != nil { return false }
        return true
    }

    // MARK: Sentences

    /// A piece of a block: a sentence (or part of one) to translate, or a link kept as written.
    struct Piece {
        var text: String
        /// The whitespace after it inside its sentence (around a link); nil: the joiner.
        var sep: String?
        /// A link or mail address: never translated, never cut.
        var isLink: Bool
    }

    private func splitBlock(_ block: String, maxTokens: Int, countTokens: (String) -> Int) -> [Piece] {
        var merged: [String] = []
        var current = ""
        var previous = ""
        for segment in sentenceSegments(block) {
            if !current.isEmpty, !Self.continuesSentence(previous, segment) {
                merged.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
            current.append(segment)
            previous = segment
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { merged.append(rest) }

        var result: [Piece] = []
        for sentence in merged {
            for part in Self.linkParts(sentence) {
                if part.isLink || countTokens(part.text) <= maxTokens {
                    result.append(part)
                    continue
                }
                let cut = splitLong(part.text, maxTokens: maxTokens, countTokens: countTokens)
                for (index, text) in cut.enumerated() {
                    let sep: String? = index == cut.count - 1 ? part.sep : nil
                    result.append(Piece(text: text, sep: sep, isLink: false))
                }
            }
        }
        return result
    }

    /// The sentence cut around its links and mail addresses: the text before, the link, the text
    /// after, each with the whitespace that followed it (the last part's is the joiner's). A
    /// sentence without links is one part.
    static func linkParts(_ sentence: String) -> [Piece] {
        let whole = [Piece(text: sentence, sep: nil, isLink: false)]
        guard let link else { return whole }
        let ns = sentence as NSString
        let matches = link.matches(in: sentence, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return whole }

        var parts: [Piece] = []
        var cursor = 0
        // Text between links: its leading whitespace follows the part before it.
        func addText(_ text: String) {
            let leading = String(text.prefix(while: { $0.isWhitespace }))
            if !leading.isEmpty, !parts.isEmpty { parts[parts.count - 1].sep = leading }
            let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !core.isEmpty else { return }
            let trailing = String(String(text.reversed()).prefix(while: { $0.isWhitespace }).reversed())
            parts.append(Piece(text: core, sep: trailing, isLink: false))
        }
        for match in matches {
            var found = ns.substring(with: match.range)
            // "…/rueckmeldung." and "(siehe https://…)": the dot and the bracket are the sentence's.
            while let last = found.last {
                let opens = found.filter { $0 == "(" }.count
                let closes = found.filter { $0 == ")" }.count
                let isTrailer = Self.linkTrailers.contains(last) || (last == ")" && closes > opens)
                guard isTrailer else { break }
                found.removeLast()
            }
            let location = match.range.location
            let length = (found as NSString).length
            guard location >= cursor, length > 0 else { continue }
            addText(ns.substring(with: NSRange(location: cursor, length: location - cursor)))
            parts.append(Piece(text: found, sep: "", isLink: true))
            cursor = location + length
        }
        addText(ns.substring(from: cursor))
        if !parts.isEmpty { parts[parts.count - 1].sep = nil }
        return parts
    }

    /// The block cut at sentence starts: each segment runs to the next one's start, so
    /// whitespace stays with the segment before it (as `Intl.Segmenter` gives it).
    private func sentenceSegments(_ text: String) -> [String] {
        let tokenizer = sentenceTokenizer ?? NLTokenizer(unit: .sentence)
        sentenceTokenizer = tokenizer
        tokenizer.string = text
        if let language { tokenizer.setLanguage(language) }
        var starts: [String.Index] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            starts.append(range.lowerBound)
            return true
        }
        guard !starts.isEmpty else { return [text] }
        starts[0] = text.startIndex
        var segments: [String] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : text.endIndex
            guard start < end else { continue }
            segments.append(String(text[start..<end]))
        }
        return segments
    }

    /// Does `next` continue the sentence that `previous` (a segment) ended? After "z.", "e.g.",
    /// "U.S.", a known abbreviation, when `next` starts in lowercase or with a digit, or after a
    /// German ordinal: a day before a month's name, or a number after an article or preposition.
    static func continuesSentence(_ previous: String, _ next: String) -> Bool {
        let before = trimmingEnd(previous)
        guard before.hasSuffix(".") else { return false }
        let withoutDot = before.dropLast()
        let words = withoutDot.split(omittingEmptySubsequences: false, whereSeparator: { $0.isWhitespace })
        var lastWord = words.last.map(String.init) ?? ""
        let openers: Set<Character> = ["(", "\"", "'", "«", "“"]
        while let first = lastWord.first, openers.contains(first) { lastWord.removeFirst() }
        if isInitials(lastWord) { return true }
        if abbreviations.contains(lastWord.lowercased()) { return true }
        let after = next.drop(while: { $0.isWhitespace })
        guard let scalar = after.unicodeScalars.first else { return false }
        if scalar.properties.generalCategory == .lowercaseLetter { return true }
        if scalar.value >= 0x30 && scalar.value <= 0x39 { return true }
        // "den 16. | Februar", "bis spätestens 31. | Januar", "im 3. | Semester".
        guard MarianOutput.isLetter(scalar), isNumber(lastWord, digits: 1...3) else { return false }
        let nextWord = String(after.prefix(while: { $0.isLetter })).lowercased()
        if isNumber(lastWord, digits: 1...2), months.contains(nextWord) { return true }
        let wordBefore = words.count >= 2 ? String(words[words.count - 2]) : ""
        let context = wordBefore.trimmingCharacters(in: CharacterSet.letters.inverted).lowercased()
        return ordinalContext.contains(context)
    }

    private static func isNumber(_ word: String, digits: ClosedRange<Int>) -> Bool {
        digits.contains(word.count) && word.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// One letter, or letters separated by dots ("z", "e.g", "U.S").
    private static func isInitials(_ word: String) -> Bool {
        let scalars = Array(word.unicodeScalars)
        guard scalars.count % 2 == 1 else { return false }
        for (index, scalar) in scalars.enumerated() {
            if index % 2 == 0 {
                if !MarianOutput.isLetter(scalar) { return false }
            } else if scalar != "." {
                return false
            }
        }
        return true
    }

    private static func trimmingEnd(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return String(result)
    }

    // MARK: Over budget

    /// A sentence over budget: split at clause punctuation first (so "1,250,000" and "10:30"
    /// stay whole), then at words.
    private func splitLong(_ sentence: String, maxTokens: Int, countTokens: (String) -> Int) -> [String] {
        let ns = sentence as NSString
        let length = ns.length
        var clauses: [String] = []
        var last = 0
        if let clause = Self.clause {
            for match in clause.matches(in: sentence, range: NSRange(location: 0, length: length)) {
                let end: Int = match.range.location + match.range.length
                if end > last {
                    clauses.append(ns.substring(with: NSRange(location: last, length: end - last)))
                }
                last = end
            }
        }
        if last < length { clauses.append(ns.substring(from: last)) }

        var result: [String] = []
        let base: Int = countTokens("")
        var current = ""
        var currentTokens: Int = base
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
            currentTokens = base
        }
        for clause in clauses {
            let trimmedClause = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens: Int = countTokens(trimmedClause) - base
            if tokens + base > maxTokens {
                flush()
                result.append(contentsOf: splitWords(trimmedClause, maxTokens: maxTokens, countTokens: countTokens))
                continue
            }
            let hasCurrent = !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasCurrent, currentTokens + tokens > maxTokens { flush() }
            current.append(clause)
            currentTokens += tokens
        }
        flush()
        return result
    }

    private func splitWords(_ text: String, maxTokens: Int, countTokens: (String) -> Int) -> [String] {
        var result: [String] = []
        let base: Int = countTokens("")
        var current = ""
        var currentTokens: Int = base
        for word in wordSegments(text) {
            let isBlank = word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let tokens: Int = isBlank ? 0 : countTokens(word) - base
            if tokens + base > maxTokens {
                // One enormous "word" (a hash, base64, a URL without spaces): hard-cut it.
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
                currentTokens = base
                let bare = word.trimmingCharacters(in: .whitespacesAndNewlines)
                var start = bare.startIndex
                while start < bare.endIndex {
                    let end = bare.index(start, offsetBy: Self.hardCutCharacters, limitedBy: bare.endIndex) ?? bare.endIndex
                    result.append(String(bare[start..<end]))
                    start = end
                }
                continue
            }
            let hasCurrent = !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasCurrent, currentTokens + tokens > maxTokens {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = String(word.drop(while: { $0.isWhitespace }))
                currentTokens = base + tokens
            } else {
                current.append(word)
                currentTokens += tokens
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    /// The text cut before each word: every segment is the gap before a word plus the word; what
    /// follows the last word is a segment of its own.
    private func wordSegments(_ text: String) -> [String] {
        let tokenizer = wordTokenizer ?? NLTokenizer(unit: .word)
        wordTokenizer = tokenizer
        tokenizer.string = text
        if let language { tokenizer.setLanguage(language) }
        var segments: [String] = []
        var cursor = text.startIndex
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if cursor < range.upperBound {
                segments.append(String(text[cursor..<range.upperBound]))
                cursor = range.upperBound
            }
            return true
        }
        if cursor < text.endIndex { segments.append(String(text[cursor..<text.endIndex])) }
        return segments
    }

    /// A route code as `NLLanguage`.
    private static func nlLanguage(_ code: String) -> NLLanguage {
        switch code {
        case "zh": .simplifiedChinese
        case "zh-TW": .traditionalChinese
        case "no": .norwegian
        default: NLLanguage(rawValue: code)
        }
    }
}
