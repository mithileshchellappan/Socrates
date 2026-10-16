import Foundation

/// Places where a slide change can plausibly start: speech onsets after a pause or a sentence end.
///
/// Stamps snap back to these (people press "next" after the professor has started talking about the
/// new slide), and automatic span boundaries are moved onto them so click-to-seek lands on a sentence.
public struct BoundaryCandidates: Hashable, Sendable {
    public struct Candidate: Hashable, Sendable {
        /// Speech onset (start of the first word after the break).
        public var time: Double
        /// Silence before the onset in seconds (0 for back-to-back lines).
        public var pause: Double
        /// True after sentence-final punctuation or a long pause, or at the first line.
        public var isSentenceStart: Bool
    }

    /// Sorted by time.
    public private(set) var candidates: [Candidate]

    public init(transcript: [TranscriptLine], parameters: AlignmentParameters = .default) {
        var result: [Candidate] = []
        var previousEnd: Double?
        var previousText: String?

        // Every line start is a candidate (ASR lines follow phrasing); sentence starts rank higher.
        func add(onset: Double) {
            let pause = previousEnd.map { max(0, onset - $0) }
            let endsSentence = previousText.map(Self.endsSentence) ?? true
            let isSentence = endsSentence || (pause ?? .infinity) >= parameters.sentencePause
            result.append(Candidate(time: onset, pause: pause ?? 0, isSentenceStart: isSentence))
        }

        for line in transcript.sorted(by: { $0.start < $1.start }) {
            if line.words.isEmpty {
                add(onset: line.start)
                previousEnd = line.end
                previousText = line.text
                continue
            }
            for (index, word) in line.words.enumerated() {
                if index == 0 {
                    add(onset: word.start)
                } else {
                    let pause = max(0, word.start - (previousEnd ?? word.start))
                    let endsSentence = previousText.map(Self.endsSentence) ?? false
                    if pause >= parameters.minimumPause || endsSentence {
                        result.append(Candidate(
                            time: word.start,
                            pause: pause,
                            isSentenceStart: endsSentence || pause >= parameters.sentencePause
                        ))
                    }
                }
                previousEnd = word.end
                previousText = word.text
            }
        }
        candidates = result
    }

    /// The best onset in `[time - back, time + forward]`: the nearest sentence start, else the nearest
    /// other break, else nil.
    public func best(near time: Double, back: Double, forward: Double, preferEarlier: Bool) -> Candidate? {
        let low = time - back
        let high = time + forward
        var bestSentence: Candidate?
        var bestOther: Candidate?
        var index = firstIndex(atOrAfter: low)
        while index < candidates.count, candidates[index].time <= high {
            let candidate = candidates[index]
            if candidate.isSentenceStart {
                if Self.isCloser(candidate, than: bestSentence, to: time, preferEarlier: preferEarlier) { bestSentence = candidate }
            } else if Self.isCloser(candidate, than: bestOther, to: time, preferEarlier: preferEarlier) {
                bestOther = candidate
            }
            index += 1
        }
        return bestSentence ?? bestOther
    }

    func firstIndex(atOrAfter time: Double) -> Int {
        var low = 0
        var high = candidates.count
        while low < high {
            let mid = (low + high) / 2
            if candidates[mid].time < time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func isCloser(_ candidate: Candidate, than current: Candidate?, to time: Double, preferEarlier: Bool) -> Bool {
        guard let current else { return true }
        let distance = abs(candidate.time - time)
        let currentDistance = abs(current.time - time)
        if distance != currentDistance { return distance < currentDistance }
        return preferEarlier ? candidate.time < current.time : candidate.time > current.time
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return last == "." || last == "?" || last == "!" || last == "…"
    }
}
