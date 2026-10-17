import Foundation

/// How one query term shows up in a chunk's words, for highlighting. Mirrors what the FTS5
/// expressions matched: word prefixes, lemma stems (through the word-aligned `lemma_text`),
/// exact phrases, trigram substrings and near spellings.
struct TermMatcher: Sendable {
    var words: [String]
    var quoted: Bool
    var lemmas: [QueryPlan.LemmaForm]
    /// Trigram pattern (folded), when the trigram index was used for this term.
    var substring: String?
    /// Near spellings found for the term.
    var nearWords: Set<String>

    init(term: QueryPlan.Term, usedTrigram: Bool, nearWords: [String]) {
        words = term.words
        quoted = term.quoted
        lemmas = term.lemmas
        substring = usedTrigram ? Tokenizer.fold(term.raw) : nil
        self.nearWords = Set(nearWords)
    }

    /// Ranges of `text` this term matched (whole words; a phrase as one range). `tokenLemmas` are
    /// the folded lemmas of `tokens`, one each.
    func ranges(in text: String, tokens: [Token], lemmas tokenLemmas: [String]?) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        if words.count == 1 {
            let word = words[0]
            for (index, token) in tokens.enumerated() {
                if quoted ? token.folded == word : token.folded.hasPrefix(word) {
                    ranges.append(token.range)
                } else if nearWords.contains(token.folded) {
                    ranges.append(token.range)
                } else if let lemma = tokenLemmas?[index], matchesLemma(lemma, lemmas) {
                    ranges.append(token.range)
                } else if let substring, token.folded.contains(substring) {
                    ranges.append(token.range)
                }
            }
        } else if tokens.count >= words.count {
            for start in 0...(tokens.count - words.count) {
                var matched = true
                for offset in words.indices {
                    let folded = tokens[start + offset].folded
                    let last = offset == words.count - 1
                    let textMatch = (last && !quoted) ? folded.hasPrefix(words[offset]) : folded == words[offset]
                    var lemmaMatch = false
                    if !textMatch, !quoted, lemmas.count == words.count, let tokenLemmas {
                        lemmaMatch = tokenLemmas[start + offset] == lemmas[offset].word
                    }
                    if !textMatch && !lemmaMatch { matched = false; break }
                }
                if matched {
                    ranges.append(tokens[start].range.lowerBound..<tokens[start + words.count - 1].range.upperBound)
                }
            }
        }
        if ranges.isEmpty, words.count > 1, let substring {
            var searchRange = text.startIndex..<text.endIndex
            while let found = text.range(of: substring, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                ranges.append(found)
                searchRange = found.upperBound..<text.endIndex
            }
        }
        return ranges
    }

    private func matchesLemma(_ lemma: String, _ forms: [QueryPlan.LemmaForm]) -> Bool {
        forms.contains { $0.prefix ? lemma.hasPrefix($0.word) : lemma == $0.word }
    }
}

/// Cuts the stretch of a chunk that best shows the matches and marks them.
enum Snippet {
    /// Chunks up to this many words are shown whole.
    static let wholeLimit = 30
    /// Otherwise a window of this many words.
    static let window = 24

    static func make(text: String, lemmaText: String, matchers: [TermMatcher]) -> AttributedString {
        let tokens = Tokenizer.tokens(in: text)
        let lemmaWords = lemmaText.split(separator: " ")
        let lemmas = lemmaWords.count == tokens.count ? lemmaWords.map(Tokenizer.fold) : nil

        // Matched ranges and, per word, which terms matched there.
        var ranges: [Range<String.Index>] = []
        var termsAtToken = [Set<Int>](repeating: [], count: tokens.count)
        for (termIndex, matcher) in matchers.enumerated() {
            for range in matcher.ranges(in: text, tokens: tokens, lemmas: lemmas) {
                ranges.append(range)
                for (index, token) in tokens.enumerated() where token.range.overlaps(range) {
                    termsAtToken[index].insert(termIndex)
                }
            }
        }

        var first = 0
        var last = tokens.count
        if tokens.count > wholeLimit {
            first = bestWindow(termsAtToken)
            last = min(tokens.count, first + window)
        }
        guard first < last else { return AttributedString(text) }
        let start = first == 0 ? text.startIndex : tokens[first].range.lowerBound
        var end = last == tokens.count ? text.endIndex : tokens[last - 1].range.upperBound
        // Keep punctuation that closes the last word ("system.").
        while end < text.endIndex, !text[end].isWhitespace, !Tokenizer.isWordCharacter(text[end]) {
            end = text.index(after: end)
        }

        let marked = merge(ranges.compactMap { range -> Range<String.Index>? in
            let lower = max(range.lowerBound, start)
            let upper = min(range.upperBound, end)
            return lower < upper ? lower..<upper : nil
        }, in: text)
        var snippet = AttributedString()
        if first > 0 { snippet += AttributedString("…") }
        var cursor = start
        for range in marked {
            if cursor < range.lowerBound { snippet += AttributedString(String(text[cursor..<range.lowerBound])) }
            var match = AttributedString(String(text[range]))
            match[SearchMatchAttribute.self] = true
            snippet += match
            cursor = range.upperBound
        }
        if cursor < end { snippet += AttributedString(String(text[cursor..<end])) }
        if last < tokens.count { snippet += AttributedString("…") }
        return snippet
    }

    /// The window start with the most distinct terms, then the most matched words; it opens a
    /// few words before its first match.
    private static func bestWindow(_ termsAtToken: [Set<Int>]) -> Int {
        let matched = termsAtToken.indices.filter { !termsAtToken[$0].isEmpty }
        guard !matched.isEmpty else { return 0 }
        var best = (start: 0, distinct: -1, count: -1)
        for position in matched {
            let start = max(0, min(position - 4, termsAtToken.count - window))
            let span = termsAtToken[start..<min(termsAtToken.count, start + window)]
            let distinct = span.reduce(into: Set<Int>()) { $0.formUnion($1) }.count
            let count = span.filter { !$0.isEmpty }.count
            if distinct > best.distinct || (distinct == best.distinct && count > best.count) {
                best = (start, distinct, count)
            }
        }
        return best.start
    }

    /// Overlapping ranges, and neighbours with only spaces between them ("binary rewriting"),
    /// become one highlight.
    private static func merge(_ ranges: [Range<String.Index>], in text: String) -> [Range<String.Index>] {
        var merged: [Range<String.Index>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let lastRange = merged.last,
               range.lowerBound <= lastRange.upperBound
                || text[lastRange.upperBound..<range.lowerBound].allSatisfy({ $0 == " " }) {
                merged[merged.count - 1] = lastRange.lowerBound..<max(lastRange.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
