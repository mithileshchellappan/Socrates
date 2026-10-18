import Foundation
import StudyCore

/// Finds a model's quote in transcript lines: the original span (whitespace and typography
/// normalized, `NormalizedText`), starting at the line the model named or the one before (models
/// are off by one), and the moment it starts (the first word's start from the word timings, else
/// the line's). Used by M3's transcript extraction (deadlines said in class) and M4's study pass
/// (the professor's exact words). Takes plain line values; knows nothing about prompts.
public enum TranscriptQuote {
    /// One transcript line as a prompt showed it: its id ("l17"), its text, when it starts and its
    /// word timings.
    public struct Line: Sendable, Hashable {
        public var id: String
        public var text: String
        public var start: Double
        public var words: [TranscriptWord]

        public init(id: String, text: String, start: Double, words: [TranscriptWord] = []) {
            self.id = id
            self.text = text
            self.start = start
            self.words = words
        }
    }

    /// A located quote.
    public struct Found: Sendable, Hashable {
        /// The original span, byte for byte as the lines have it (lines joined by one space).
        public var quote: String
        /// Seconds on the recording clock: its first word's start, else its first line's start.
        public var time: Double
        /// Index (into the `lines` given) of the line the quote starts in.
        public var firstLine: Int
        /// Index of the line the quote ends in.
        public var lastLine: Int
    }

    /// The original span of `quote` in the window lines from the line with id `line` on (or the
    /// line before it), or nil.
    ///
    /// - `windows`: the line index ranges the prompt showed; the quote never leaves its window.
    /// - `characters`: the length the original span must have (M3: 8…300).
    /// - `words`: the word count it must have (M4 professor quotes: 3…25), when given.
    /// - `maximumLines`: how many consecutive lines it may run across (M4: 3), when given.
    public static func locate(
        _ quote: String,
        line: String,
        lines: [Line],
        windows: [ClosedRange<Int>],
        characters: ClosedRange<Int> = 8...300,
        words: ClosedRange<Int>? = nil,
        maximumLines: Int? = nil
    ) -> Found? {
        let cleaned = cleaned(quote)
        guard cleaned.count >= characters.lowerBound else { return nil }
        let id = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard let named = lines.firstIndex(where: { $0.id == id }) else { return nil }
        for start in [named, named - 1] where start >= 0 {
            guard let window = windows.first(where: { $0.contains(start) }) else { continue }
            var end = min(window.upperBound, lines.count - 1)
            if let maximumLines { end = min(end, start + max(maximumLines, 1) - 1) }
            guard start <= end else { continue }
            // The window's lines from `start` on, joined by spaces, with each line's start index.
            var text = ""
            var starts: [(index: Int, offset: String.Index)] = []
            for index in start...end {
                if !text.isEmpty { text += " " }
                starts.append((index, text.endIndex))
                text += lines[index].text
            }
            guard let span = NormalizedText(text).originalSpan(of: cleaned) else { continue }
            let original = String(span)
            guard characters.contains(original.count) else { return nil }
            if let words, !words.contains(wordCount(original)) { return nil }
            guard let first = starts.last(where: { $0.offset <= span.startIndex }) else { return nil }
            let last = starts.last(where: { $0.offset < span.endIndex }) ?? first
            let lineText = lines[first.index].text
            let offset = text.distance(from: first.offset, to: span.startIndex)
            let time = Self.time(at: offset, in: lineText, words: lines[first.index].words) ?? lines[first.index].start
            return Found(quote: original, time: time, firstLine: first.index, lastLine: last.index)
        }
        return nil
    }

    /// The start of the word at character `offset` of a line, from its word timings; nil when the
    /// timings do not match the text (a corrected word) or there are none.
    public static func time(at offset: Int, in text: String, words: [TranscriptWord]) -> Double? {
        guard !words.isEmpty else { return nil }
        var cursor = text.startIndex
        for word in words {
            let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            guard let range = text.range(of: token, range: cursor..<text.endIndex) else { return nil }
            if text.distance(from: text.startIndex, to: range.upperBound) > offset { return word.start }
            cursor = range.upperBound
        }
        return nil
    }

    /// The model's quote without XML entities, surrounding quotation marks or ellipses.
    public static func cleaned(_ quote: String) -> String {
        var text = unescape(quote).trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers: Set<Character> = ["\"", "'", "„", "“", "”", "‚", "‘", "’", "«", "»"]
        while let first = text.first, let last = text.last, text.count >= 2, wrappers.contains(first), wrappers.contains(last) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for ellipsis in ["...", "…"] {
            while text.hasPrefix(ellipsis) { text = String(text.dropFirst(ellipsis.count)).trimmingCharacters(in: .whitespaces) }
            while text.hasSuffix(ellipsis) { text = String(text.dropLast(ellipsis.count)).trimmingCharacters(in: .whitespaces) }
        }
        return text
    }

    /// The XML entities prompts escape lines with (`&amp;`, `&lt;`, `&gt;`, `&quot;`, `&#39;`), undone.
    public static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Words as a reader counts them: runs separated by whitespace.
    public static func wordCount(_ text: some StringProtocol) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
