import Foundation

/// Finds detected speech that a transcript does not cover.
public enum SpeechCoverage {
    public struct Gap: Hashable, Sendable {
        /// From the first to the last uncovered speech in the gap.
        public var range: TimeRange
        /// Seconds of uncovered speech inside `range`.
        public var speechSeconds: Double
    }

    /// Speech not covered by any of `covered`. Uncovered pieces separated by pauses shorter than
    /// `joiningGap` form one gap; gaps with less than `minimumSpeech` seconds of speech are
    /// ignored. Covered ranges are widened by `tolerance` because segment edges are approximate.
    public static func gaps(
        speech: [TimeRange],
        covered: [TimeRange],
        minimumSpeech: Double = 3,
        joiningGap: Double = 1,
        tolerance: Double = 0.25
    ) -> [Gap] {
        let uncovered = TimeRanges.subtract(covered.map { $0.expanded(by: tolerance) }, from: speech)
        return TimeRanges.union(uncovered, joiningGap: joiningGap).compactMap { range in
            let seconds = TimeRanges.seconds(of: uncovered, within: range)
            return seconds >= minimumSpeech ? Gap(range: range, speechSeconds: seconds) : nil
        }
    }

    /// Seconds of `speech` inside `covered` (both lists may overlap internally).
    public static func coveredSeconds(speech: [TimeRange], covered: [TimeRange]) -> Double {
        let speechUnion = TimeRanges.union(speech)
        let uncovered = TimeRanges.subtract(covered, from: speechUnion)
        return TimeRanges.totalDuration(speechUnion) - TimeRanges.totalDuration(uncovered)
    }
}
