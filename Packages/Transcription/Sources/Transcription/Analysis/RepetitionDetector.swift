import Foundation

/// A phrase repeated back to back, as in Whisper's decoding loops
/// ("we can see that we can see that we can see that …").
public struct Repetition: Hashable, Sendable, Codable {
    /// Index of the first word of the first copy in the word list given to the detector.
    public var start: Int
    /// One past the last word of the last copy.
    public var end: Int
    /// One past the last word of the first copy (the copy that is kept when collapsing).
    public var firstCopyEnd: Int
    /// Words per copy (punctuation-only words not counted).
    public var length: Int
    /// Consecutive copies, including the first.
    public var count: Int

    public init(start: Int, end: Int, firstCopyEnd: Int, length: Int, count: Int) {
        self.start = start
        self.end = end
        self.firstCopyEnd = firstCopyEnd
        self.length = length
        self.count = count
    }

    /// Words beyond the first copy.
    public var redundantWords: Int { length * (count - 1) }
    /// Indexes of the words beyond the first copy.
    public var redundantRange: Range<Int> { firstCopyEnd..<end }
}

/// Finds back-to-back repeated n-grams in a word sequence.
///
/// The evaluation metric is an n-gram of 3–8 words repeated at least 3 times in a row
/// (`.loopMetric`). The engine's guard also catches one- and two-word loops, which need more
/// copies before they count because people do say "no, no, no".
public struct RepetitionDetector: Hashable, Sendable {
    /// Minimum consecutive copies per n-gram length.
    public var minimumCopies: [Int: Int]

    public init(minimumCopies: [Int: Int]) {
        self.minimumCopies = minimumCopies.filter { $0.key > 0 && $0.value > 1 }
    }

    /// n = 3…8 words, ≥ 3 copies.
    public static let loopMetric = RepetitionDetector(
        minimumCopies: Dictionary(uniqueKeysWithValues: (3...8).map { ($0, 3) })
    )

    /// The metric plus single words repeated ≥ 8 times and word pairs repeated ≥ 5 times.
    public static let loopGuard = RepetitionDetector(
        minimumCopies: loopMetric.minimumCopies.merging([1: 8, 2: 5]) { current, _ in current }
    )

    /// Repetitions in `words`, non-overlapping, in order. Words are compared case- and
    /// punctuation-insensitively; punctuation-only words are skipped.
    public func repetitions(in words: [String]) -> [Repetition] {
        let normalized = words.map(Self.normalize)
        let positions = normalized.indices.filter { !normalized[$0].isEmpty }
        let tokens = positions.map { normalized[$0] }
        let lengths = minimumCopies.keys.sorted()
        var found: [Repetition] = []
        var index = 0
        while index < tokens.count {
            var best: (length: Int, copies: Int)?
            for length in lengths where index + length * 2 <= tokens.count {
                let copies = consecutiveCopies(of: index..<(index + length), in: tokens)
                guard copies >= (minimumCopies[length] ?? .max) else { continue }
                // Prefer the pattern that covers most words; on a tie the shorter period wins.
                if let current = best, current.length * current.copies >= length * copies { continue }
                best = (length, copies)
            }
            if let best {
                let lastToken = index + best.length * best.copies - 1
                found.append(Repetition(
                    start: positions[index],
                    end: positions[lastToken] + 1,
                    firstCopyEnd: positions[index + best.length - 1] + 1,
                    length: best.length,
                    count: best.copies
                ))
                index = lastToken + 1
            } else {
                index += 1
            }
        }
        return found
    }

    /// Indexes (into `words`) of every word beyond the first copy of each repetition.
    public func redundantIndexes(in words: [String]) -> IndexSet {
        var indexes = IndexSet()
        for repetition in repetitions(in: words) {
            indexes.insert(integersIn: repetition.redundantRange)
        }
        return indexes
    }

    /// Total words beyond the first copy of every repetition.
    public func redundantWordCount(in words: [String]) -> Int {
        repetitions(in: words).reduce(0) { $0 + $1.redundantWords }
    }

    private func consecutiveCopies(of pattern: Range<Int>, in tokens: [String]) -> Int {
        let length = pattern.count
        var copies = 1
        var next = pattern.upperBound
        while next + length <= tokens.count, tokens[next..<(next + length)].elementsEqual(tokens[pattern]) {
            copies += 1
            next += length
        }
        return copies
    }

    /// Lowercased word without surrounding punctuation.
    public static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines))
    }

    /// Splits text into words on whitespace.
    public static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
