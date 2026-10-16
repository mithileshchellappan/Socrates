import Foundation

/// Which language was actually spoken when, for evaluation fixtures.
public struct ReferenceLanguage: Hashable, Sendable, Codable {
    public struct Span: Hashable, Sendable, Codable {
        public var range: TimeRange
        public var language: String

        public init(range: TimeRange, language: String) {
            self.range = range
            self.language = language
        }
    }

    public var spans: [Span]

    public init(spans: [Span]) {
        self.spans = spans
    }

    public func language(at time: Double) -> String? {
        spans.first { $0.range.contains(time) }?.language
    }

    /// Parses "de:0-371,en:371-" (seconds; an open end means "to the end").
    public init?(parsing text: String) {
        var spans: [Span] = []
        for item in text.split(separator: ",") {
            let parts = item.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let bounds = parts[1].split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2, let start = Double(bounds[0]) else { return nil }
            let end = bounds[1].isEmpty ? Double.greatestFiniteMagnitude : Double(bounds[1])
            guard let end else { return nil }
            spans.append(Span(range: TimeRange(start: start, end: end), language: String(parts[0])))
        }
        self.init(spans: spans)
    }
}

/// Text-free quality numbers for a transcript, used by the evaluation (docs/eval).
public struct TranscriptMetrics: Hashable, Sendable, Codable {
    public struct Segment: Hashable, Sendable, Codable {
        public var start: Double
        public var end: Double
        public var text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public struct LanguageRun: Hashable, Sendable, Codable {
        public var range: TimeRange
        public var language: String
        public var chunks: Int
    }

    /// A window whose text is in a different language than was spoken.
    public struct LanguageMismatch: Hashable, Sendable, Codable {
        public var range: TimeRange
        public var spoken: String
        public var written: String
    }

    public var segmentCount: Int
    public var wordCount: Int
    public var speechSeconds: Double
    public var coveredSpeechSeconds: Double
    /// Detected speech with no text, ≥ the minimum, grouped across short pauses.
    public var missing: [TimeRange]
    public var missingSpeechSeconds: Double
    /// n-grams of 3–8 words repeated ≥ 3 times in a row.
    public var loops: Int
    public var loopRedundantWords: Int
    /// Seconds of audio per chunk language label (empty when the source has no labels).
    public var languageSeconds: [String: Double]
    /// Consecutive chunks with the same label, merged.
    public var languageRuns: [LanguageRun]
    /// 30 s windows with enough text to tell the language.
    public var judgedWindows: Int
    /// Windows written in another language than the reference says was spoken
    /// (German speech written in English = translated).
    public var mismatches: [LanguageMismatch]

    public var coverage: Double { speechSeconds > 0 ? coveredSpeechSeconds / speechSeconds : 0 }
    public var labelSwitches: Int { max(languageRuns.count - 1, 0) }

    public func mismatches(spoken: String, written: String) -> [LanguageMismatch] {
        mismatches.filter { $0.spoken == spoken && $0.written == written }
    }

    public static let windowLength: Double = 30

    public static func measure(
        segments: [Segment],
        chunkLabels: [(range: TimeRange, language: String)],
        speech: [TimeRange],
        duration: Double,
        reference: ReferenceLanguage?,
        minimumMissingSpeech: Double = 3
    ) -> TranscriptMetrics {
        let withText = segments.filter { SegmentPostProcessor.hasContent($0.text) }
        let words = withText.flatMap { RepetitionDetector.words(in: $0.text) }
            .filter { !RepetitionDetector.normalize($0).isEmpty }
        let covered = withText.map { TimeRange(start: $0.start, end: $0.end) }
        let gaps = SpeechCoverage.gaps(speech: speech, covered: covered, minimumSpeech: minimumMissingSpeech)

        // Loops are counted over the whole text in time order, so a loop spanning segments counts once.
        let allWords = withText.sorted { $0.start < $1.start }.flatMap { RepetitionDetector.words(in: $0.text) }
        let repetitions = RepetitionDetector.loopMetric.repetitions(in: allWords)

        var languageSeconds: [String: Double] = [:]
        var runs: [LanguageRun] = []
        for label in chunkLabels.sorted(by: { $0.range.start < $1.range.start }) {
            languageSeconds[label.language, default: 0] += label.range.duration
            if let last = runs.last, last.language == label.language {
                runs[runs.count - 1].range.end = label.range.end
                runs[runs.count - 1].chunks += 1
            } else {
                runs.append(LanguageRun(range: label.range, language: label.language, chunks: 1))
            }
        }

        var judged = 0
        var mismatches: [LanguageMismatch] = []
        var windowStart = 0.0
        while windowStart < duration {
            let window = TimeRange(start: windowStart, end: min(windowStart + windowLength, duration))
            let text = withText.filter { window.contains(($0.start + $0.end) / 2) }.map(\.text).joined(separator: " ")
            if let written = TextLanguage.guess(text) {
                judged += 1
                if let spoken = reference?.language(at: window.midpoint), spoken != written {
                    mismatches.append(LanguageMismatch(range: window, spoken: spoken, written: written))
                }
            }
            windowStart += windowLength
        }

        return TranscriptMetrics(
            segmentCount: withText.count,
            wordCount: words.count,
            speechSeconds: TimeRanges.totalDuration(speech),
            coveredSpeechSeconds: SpeechCoverage.coveredSeconds(speech: speech, covered: covered),
            missing: gaps.map(\.range),
            missingSpeechSeconds: gaps.reduce(0) { $0 + $1.speechSeconds },
            loops: repetitions.count,
            loopRedundantWords: repetitions.reduce(0) { $0 + $1.redundantWords },
            languageSeconds: languageSeconds,
            languageRuns: runs,
            judgedWindows: judged,
            mismatches: mismatches
        )
    }
}
