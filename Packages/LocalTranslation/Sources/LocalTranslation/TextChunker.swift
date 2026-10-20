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
final class TextChunker {
    private static let blockSeparator: NSRegularExpression? = try? NSRegularExpression(pattern: "[ \\t\\u00A0]*\\n\\s*")
    /// ASCII `, ; :` followed by whitespace, or CJK clause marks.
    private static let clause: NSRegularExpression? = try? NSRegularExpression(pattern: "[,;:](?=\\s)\\s*|[，；：、]\\s*")
    private static let urlish: NSRegularExpression? = try? NSRegularExpression(
        pattern: "^(https?://|www\\.)\\S+$", options: [.caseInsensitive]
    )
    private static let hardCutCharacters = 200
    /// Common abbreviations (lowercased, without the dot) across the supported languages.
    private static let abbreviationList: String = """
        mr mrs ms dr prof st jr sr mt vs etc ca no nr nos inc ltd co corp dept est fig vol op ed eds approx \
        bzw usw vgl ggf evtl inkl zzgl mio mrd tel str abs art hr fr dipl ing \
        mme mlle mm env cf sra srta dña dra av pág núm sig \
        sig ecc pag pp ca lt cdr gen col sgt capt
        """
    private static let abbreviations: Set<String> = Set(abbreviationList.split(separator: " ").map { String($0) })

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
                    pending = TextUnit(text: piece, sep: isLast ? blockSep : joiner, skip: !Self.shouldTranslate(piece))
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
        guard let urlish else { return true }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return urlish.firstMatch(in: text, range: range) == nil
    }

    // MARK: Sentences

    private func splitBlock(_ block: String, maxTokens: Int, countTokens: (String) -> Int) -> [String] {
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

        var result: [String] = []
        for sentence in merged {
            if countTokens(sentence) > maxTokens {
                result.append(contentsOf: splitLong(sentence, maxTokens: maxTokens, countTokens: countTokens))
            } else {
                result.append(sentence)
            }
        }
        return result
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
    /// "U.S.", a known abbreviation, or when `next` starts in lowercase or with a digit.
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
        return scalar.value >= 0x30 && scalar.value <= 0x39
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
