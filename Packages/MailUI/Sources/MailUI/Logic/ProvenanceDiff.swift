import Foundation

/// Who wrote which words of a draft (PRD "provenance by typography"): the agent's words that the
/// student left unchanged are shown in the AI style, everything the student typed in the primary
/// style. A word diff of what the agent wrote (`generated_body`) against the text that will be
/// sent (`body`).
enum ProvenanceDiff {
    /// A word of a text and where it is.
    struct Word: Equatable {
        var text: Substring
        var range: Range<String.Index>
    }

    /// The words of `text` (runs of non-whitespace), in order.
    static func words(_ text: String) -> [Word] {
        var words: [Word] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace {
                end = text.index(after: end)
            }
            words.append(Word(text: text[index..<end], range: index..<end))
            index = end
        }
        return words
    }

    /// The ranges of `body` that are the agent's unchanged words, merged where only whitespace
    /// lies between them. Empty when the agent wrote nothing (`generated` nil or empty) or the
    /// student replaced every word.
    static func agentRanges(generated: String?, body: String) -> [Range<String.Index>] {
        guard let generated, !generated.isEmpty else { return [] }
        let bodyWords = words(body)
        guard !bodyWords.isEmpty else { return [] }
        if generated == body {
            return [bodyWords[0].range.lowerBound..<bodyWords[bodyWords.count - 1].range.upperBound]
        }
        let generatedWords = words(generated)
        // Myers diff (the standard library's): fast when the student changed little.
        let difference = bodyWords.map(\.text).difference(from: generatedWords.map(\.text))
        var typed = Set<Int>()
        for change in difference {
            if case .insert(let offset, _, _) = change { typed.insert(offset) }
        }
        // Runs of unchanged words. A single word standing alone among the student's ("the",
        // "own") is a coincidence of the diff, not the agent's text: it counts as the student's.
        var ranges: [Range<String.Index>] = []
        var current: (range: Range<String.Index>, words: Int)?
        func close() {
            if let run = current, run.words > 1 || typed.isEmpty { ranges.append(run.range) }
            current = nil
        }
        for (offset, word) in bodyWords.enumerated() {
            if typed.contains(offset) {
                close()
            } else if let run = current {
                current = (run.range.lowerBound..<word.range.upperBound, run.words + 1)
            } else {
                current = (word.range, 1)
            }
        }
        close()
        return ranges
    }

    /// The ranges as UTF-16 `NSRange`s (text views).
    static func agentNSRanges(generated: String?, body: String) -> [NSRange] {
        agentRanges(generated: generated, body: body).map { NSRange($0, in: body) }
    }
}
