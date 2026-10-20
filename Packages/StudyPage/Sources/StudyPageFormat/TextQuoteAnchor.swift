import Foundation

// Finding a mark's passage again (docs/plan-lecture-notes.md §5.5, the W3C Web Annotation model's
// text-quote selector): `exact` inside its section's displayed text, the occurrence whose
// surroundings best match `prefix` and `suffix` (then the one nearest the stored position); else
// the same on folded words (case, diacritics, punctuation and spacing ignored); else a fuzzy match
// of the words (at least 85 % of them in order over a window). Nil: the mark is orphaned.

public enum TextQuoteAnchor {
    /// The passage's range in `text`, in UTF-16 offsets (NSString ranges).
    public static func locate(exact: String, prefix: String, suffix: String, hint: Int? = nil, in text: String) -> NSRange? {
        let needle = exact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !text.isEmpty else { return nil }
        let haystack = text as NSString
        // 1. Exactly.
        var candidates: [NSRange] = []
        var search = NSRange(location: 0, length: haystack.length)
        while search.length > 0 {
            let found = haystack.range(of: needle, options: [], range: search)
            guard found.location != NSNotFound else { break }
            candidates.append(found)
            let next = found.location + 1
            search = NSRange(location: next, length: haystack.length - next)
        }
        if let best = best(candidates, prefix: prefix, suffix: suffix, hint: hint, in: haystack) { return best }

        // 2. Folded words.
        let folded = Folded(text)
        let foldedNeedle = Folded(needle).string
        guard !foldedNeedle.isEmpty else { return nil }
        let padded = " " + folded.string + " "
        var foldedCandidates: [NSRange] = []
        var start = padded.startIndex
        while let range = padded.range(of: " " + foldedNeedle + " ", range: start..<padded.endIndex) {
            let lower = padded.distance(from: padded.startIndex, to: range.lowerBound)
            let length = foldedNeedle.count
            if let mapped = folded.original(characterRange: lower..<(lower + length)) { foldedCandidates.append(mapped) }
            start = padded.index(after: range.lowerBound)
        }
        if let best = best(foldedCandidates, prefix: prefix, suffix: suffix, hint: hint, in: haystack) { return best }

        // 3. Fuzzy words.
        return fuzzy(needle: foldedNeedle, in: folded, hint: hint)
    }

    /// The candidate with the most matching context, then the nearest to `hint`.
    static func best(_ candidates: [NSRange], prefix: String, suffix: String, hint: Int?, in text: NSString) -> NSRange? {
        guard candidates.count > 1 else { return candidates.first }
        let before = Folded(prefix).string
        let after = Folded(suffix).string
        func score(_ range: NSRange) -> Int {
            let leading = Folded(text.substring(with: NSRange(location: max(0, range.location - 48), length: min(48, range.location)))).string
            let trailingStart = NSMaxRange(range)
            let trailing = Folded(text.substring(with: NSRange(location: trailingStart, length: min(48, text.length - trailingStart)))).string
            return commonSuffix(leading, before) + commonPrefix(trailing, after)
        }
        return candidates.max { lhs, rhs in
            let left = score(lhs)
            let right = score(rhs)
            if left != right { return left < right }
            guard let hint else { return lhs.location > rhs.location }
            return abs(lhs.location - hint) > abs(rhs.location - hint)
        }
    }

    static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

    static func commonSuffix(_ a: String, _ b: String) -> Int {
        zip(a.reversed(), b.reversed()).prefix { $0 == $1 }.count
    }

    /// At least 85 % of the needle's words in order within a window of the text's words.
    static func fuzzy(needle: String, in folded: Folded, hint: Int?) -> NSRange? {
        let words = needle.split(separator: " ").map(String.init)
        guard words.count >= 4 else { return nil }
        let textWords = folded.words
        guard textWords.count >= words.count / 2 else { return nil }
        let window = words.count + max(2, words.count / 5)
        var best: (score: Double, first: Int, last: Int)?
        var start = 0
        while start < textWords.count {
            let end = min(textWords.count, start + window)
            let slice = textWords[start..<end].map(\.text)
            let (matched, first, last) = lcs(words, slice)
            let score = Double(matched) / Double(words.count)
            if score >= 0.85, score > (best?.score ?? 0) {
                best = (score, start + first, start + last)
            }
            start += 1
        }
        guard let best else { return nil }
        let lower = textWords[best.first].range.location
        let upper = NSMaxRange(textWords[best.last].range)
        _ = hint
        return NSRange(location: lower, length: upper - lower)
    }

    /// The longest common subsequence's length and where it starts and ends in `b`.
    static func lcs(_ a: [String], _ b: [String]) -> (Int, Int, Int) {
        guard !a.isEmpty, !b.isEmpty else { return (0, 0, 0) }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                table[i][j] = a[i - 1] == b[j - 1] ? table[i - 1][j - 1] + 1 : max(table[i - 1][j], table[i][j - 1])
            }
        }
        // Walk back for the matched span in `b`.
        var i = a.count
        var j = b.count
        var first = b.count
        var last = 0
        while i > 0, j > 0 {
            if a[i - 1] == b[j - 1] {
                first = j - 1
                last = max(last, j - 1)
                i -= 1
                j -= 1
            } else if table[i - 1][j] >= table[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return (table[a.count][b.count], min(first, last), last)
    }

    /// Text folded for matching (lower case, diacritics folded, letters and digits only, single
    /// spaces), with each folded character's place in the original (UTF-16).
    struct Folded {
        var string = ""
        /// Per folded character: the original character's UTF-16 range.
        var map: [NSRange] = []

        init(_ text: String) {
            var lastWasSpace = true
            var offset = 0
            for character in text {
                let length = character.utf16.count
                defer { offset += length }
                if character.isLetter || character.isNumber {
                    let folded = String(character).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                    for piece in folded where piece.isLetter || piece.isNumber {
                        string.append(piece)
                        map.append(NSRange(location: offset, length: length))
                    }
                    lastWasSpace = false
                } else if !lastWasSpace {
                    string.append(" ")
                    map.append(NSRange(location: offset, length: length))
                    lastWasSpace = true
                }
            }
            if string.hasSuffix(" ") {
                string.removeLast()
                map.removeLast()
            }
        }

        /// The original range of folded characters `range` (character offsets into `string`).
        func original(characterRange range: Range<Int>) -> NSRange? {
            guard range.lowerBound >= 0, range.upperBound <= map.count, !range.isEmpty else { return nil }
            let lower = map[range.lowerBound].location
            let upper = NSMaxRange(map[range.upperBound - 1])
            return NSRange(location: lower, length: upper - lower)
        }

        /// The folded words with their original ranges.
        var words: [(text: String, range: NSRange)] {
            var result: [(String, NSRange)] = []
            var word = ""
            var first: Int?
            for (index, character) in string.enumerated() {
                if character == " " {
                    if let start = first, let range = original(characterRange: start..<index) { result.append((word, range)) }
                    word = ""
                    first = nil
                } else {
                    if first == nil { first = index }
                    word.append(character)
                }
            }
            if let start = first, let range = original(characterRange: start..<string.count) { result.append((word, range)) }
            return result
        }
    }
}
