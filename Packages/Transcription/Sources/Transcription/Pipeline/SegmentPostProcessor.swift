import Foundation

/// Cleans decoder output into well-formed segments.
///
/// Always: strips special tokens (`<|…|>`), trims whitespace, drops empty and punctuation-only
/// segments, clamps times into the chunk and keeps words ordered. With `removeHallucinations`:
/// drops the subtitle-credit phrases Whisper is known to invent on silence.
public struct SegmentPostProcessor: Hashable, Sendable {
    public var removeHallucinations: Bool

    public init(removeHallucinations: Bool = true) {
        self.removeHallucinations = removeHallucinations
    }

    /// Normalised phrases (lowercase, no punctuation) Whisper produces on silence or noise,
    /// learned from subtitle credits in its training data. A lecturer does not say these.
    public static let knownHallucinations: Set<String> = [
        "untertitel im auftrag des zdf für funk 2017",
        "untertitel im auftrag des zdf 2017",
        "untertitel im auftrag des zdf 2018",
        "untertitel im auftrag des zdf 2020",
        "untertitel im auftrag des zdf 2021",
        "untertitelung des zdf 2020",
        "untertitel der amaraorg-community",
        "untertitel von stephanie geiges",
        "copyright wdr 2021",
        "copyright wdr 2020",
        "swr 2020",
        "swr 2021",
        "thanks for watching",
        "thank you for watching",
        "thanks for watching and see you next time",
        "please subscribe to my channel",
        "subtitles by the amaraorg community",
        "ondertitels ingediend door de amaraorg gemeenschap",
        "sous-titres réalisés para la communauté damaraorg",
    ]

    static func normalizedPhrase(_ text: String) -> String {
        let folded = text.lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public func isKnownHallucination(_ text: String) -> Bool {
        Self.knownHallucinations.contains(Self.normalizedPhrase(text))
    }

    /// Cleans segments decoded from one chunk. Times must already be on the recording clock.
    public func clean(_ segments: [TranscribedSegment], within bounds: TimeRange) -> [TranscribedSegment] {
        segments.compactMap { clean($0, within: bounds) }
    }

    func clean(_ segment: TranscribedSegment, within bounds: TimeRange) -> TranscribedSegment? {
        var segment = segment
        segment.text = Self.tidy(segment.text)
        segment.words = segment.words.compactMap { word in
            var word = word
            word.text = Self.tidy(word.text)
            guard !word.text.isEmpty else { return nil }
            word.start = min(max(word.start, bounds.start), bounds.end)
            word.end = min(max(word.end, word.start), bounds.end)
            return word
        }
        // Word times must not run backwards.
        for index in segment.words.indices.dropFirst() where segment.words[index].start < segment.words[index - 1].start {
            segment.words[index].start = segment.words[index - 1].start
            segment.words[index].end = max(segment.words[index].end, segment.words[index].start)
        }
        guard Self.hasContent(segment.text) else { return nil }
        if removeHallucinations, isKnownHallucination(segment.text) { return nil }
        segment.start = min(max(segment.start, bounds.start), bounds.end)
        segment.end = min(max(segment.end, segment.start), bounds.end)
        if let first = segment.words.first, let last = segment.words.last {
            segment.start = min(segment.start, first.start)
            segment.end = max(segment.end, last.end)
        }
        return segment
    }

    /// Removes `<|…|>` tokens and collapses whitespace.
    static func tidy(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<|"), let close = result.range(of: "|>", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func hasContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// Sorts segments and drops a segment that repeats the previous one's text while overlapping
    /// it in time (re-decodes and chunk seams can produce both copies).
    public func merge(_ segments: [TranscribedSegment]) -> [TranscribedSegment] {
        let sorted = segments.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var result: [TranscribedSegment] = []
        for segment in sorted {
            if let last = result.last,
               segment.start < last.end,
               Self.normalizedPhrase(segment.text) == Self.normalizedPhrase(last.text) {
                continue
            }
            result.append(segment)
        }
        return result
    }

    /// Collapses back-to-back repetitions across `segments` to one copy, using word timings when
    /// present. Returns the cleaned segments and how many words were removed.
    public func collapseRepetitions(
        in segments: [TranscribedSegment],
        detector: RepetitionDetector
    ) -> (segments: [TranscribedSegment], removedWords: Int) {
        // Flatten into (segment, word) units so loops spanning segments are found.
        var units: [(segment: Int, word: Int)] = []
        var texts: [String] = []
        let tokenized: [[String]] = segments.map { segment in
            segment.words.isEmpty ? RepetitionDetector.words(in: segment.text) : segment.words.map(\.text)
        }
        for (segmentIndex, words) in tokenized.enumerated() {
            for (wordIndex, word) in words.enumerated() {
                units.append((segmentIndex, wordIndex))
                texts.append(word)
            }
        }
        let redundant = detector.redundantIndexes(in: texts)
        guard !redundant.isEmpty else { return (segments, 0) }

        var dropped: [Int: IndexSet] = [:]
        for index in redundant {
            dropped[units[index].segment, default: IndexSet()].insert(units[index].word)
        }
        var result: [TranscribedSegment] = []
        for (segmentIndex, segment) in segments.enumerated() {
            guard let drop = dropped[segmentIndex] else {
                result.append(segment)
                continue
            }
            var updated = segment
            let words = tokenized[segmentIndex]
            let keptText = words.indices.filter { !drop.contains($0) }.map { words[$0] }
            if !segment.words.isEmpty {
                updated.words = segment.words.indices.filter { !drop.contains($0) }.map { segment.words[$0] }
                if let first = updated.words.first, let last = updated.words.last {
                    updated.start = first.start
                    updated.end = last.end
                }
            }
            updated.text = keptText.joined(separator: " ")
            updated.repair = .loopCollapsed
            if Self.hasContent(updated.text) {
                result.append(updated)
            }
        }
        let removedWords = redundant.count(where: { !RepetitionDetector.normalize(texts[$0]).isEmpty })
        return (result, removedWords)
    }
}
