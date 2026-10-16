import Foundation

/// A piece of the recording decoded in one Whisper call.
public struct PlannedChunk: Hashable, Sendable {
    /// Sample range in the 16 kHz timeline.
    public var samples: Range<Int>
    public var time: TimeRange
    /// Seconds of detected speech inside the chunk.
    public var speechSeconds: Double

    public init(samples: Range<Int>, time: TimeRange, speechSeconds: Double) {
        self.samples = samples
        self.time = time
        self.speechSeconds = speechSeconds
    }
}

/// Splits a recording into chunks of at most one Whisper window (30 s), cutting in the middle of
/// the longest pause in the second half of each window (WhisperKit's VAD chunking rule), so
/// words are not cut and every chunk gets its own language decision.
public struct ChunkPlanner: Hashable, Sendable {
    public var sampleRate: Int
    public var maximumDuration: Double
    /// Chunks with less speech than this are not decoded (they produce only hallucinations).
    public var minimumSpeech: Double

    public init(sampleRate: Int = 16_000, maximumDuration: Double = 30, minimumSpeech: Double = 0.3) {
        self.sampleRate = sampleRate
        self.maximumDuration = maximumDuration
        self.minimumSpeech = minimumSpeech
    }

    public func plan(sampleCount: Int, speech: [TimeRange]) -> [PlannedChunk] {
        guard sampleCount > 0 else { return [] }
        let rate = Double(sampleRate)
        let maxSamples = max(Int(maximumDuration * rate), 1)
        let regions = TimeRanges.union(speech)
        var chunks: [PlannedChunk] = []
        var cursor = 0
        while cursor < sampleCount {
            var end = sampleCount
            if sampleCount - cursor > maxSamples {
                let windowStart = Double(cursor + maxSamples / 2) / rate
                let windowEnd = Double(cursor + maxSamples) / rate
                end = cursor + maxSamples
                if let pause = longestPause(in: TimeRange(start: windowStart, end: windowEnd), speech: regions) {
                    end = min(max(Int((pause.midpoint * rate).rounded()), cursor + 1), cursor + maxSamples)
                }
            }
            let time = TimeRange(start: Double(cursor) / rate, end: Double(end) / rate)
            chunks.append(PlannedChunk(
                samples: cursor..<end,
                time: time,
                speechSeconds: TimeRanges.seconds(of: regions, within: time)
            ))
            cursor = end
        }
        return chunks
    }

    /// Whether a chunk has enough speech to be worth decoding.
    public func shouldDecode(_ chunk: PlannedChunk) -> Bool {
        chunk.speechSeconds >= minimumSpeech
    }

    /// The longest stretch inside `window` not covered by speech.
    func longestPause(in window: TimeRange, speech: [TimeRange]) -> TimeRange? {
        let pauses = TimeRanges.subtract(speech, from: [window])
        return pauses.max { $0.duration < $1.duration }
    }
}
