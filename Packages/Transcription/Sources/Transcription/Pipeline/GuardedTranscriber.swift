import Foundation
import StudyCore

/// The transcription pipeline around a `ChunkDecoder`:
///
/// 1. Voice activity detection over the whole recording.
/// 2. Chunks of ≤ 30 s cut at pauses; chunks without speech are skipped.
/// 3. First pass: chunks decoded in batches, each with its own language decision.
/// 4. Loop guard: a chunk whose text repeats an n-gram is re-decoded at higher temperatures in
///    the language it was detected in; the decoding with the fewest repeated words wins.
/// 5. Clean-up: repetitions that survive are collapsed to one copy, silence hallucinations dropped.
/// 6. Missing-speech guard: detected speech without text (≥ 3 s) is re-decoded on its own.
public struct GuardedTranscriber: Sendable {
    public var decoder: any ChunkDecoder
    public var speechDetector: SpeechActivityDetector
    public var planner: ChunkPlanner
    public var loopDetector: RepetitionDetector

    public static let sampleRate = 16_000

    public init(
        decoder: any ChunkDecoder,
        speechDetector: SpeechActivityDetector = SpeechActivityDetector(),
        planner: ChunkPlanner = ChunkPlanner(),
        loopDetector: RepetitionDetector = .loopGuard
    ) {
        self.decoder = decoder
        self.speechDetector = speechDetector
        self.planner = planner
        self.loopDetector = loopDetector
    }

    /// Transcribes 16 kHz mono samples. Times in the result are seconds from sample 0.
    public func transcribe(
        samples: [Float],
        options: TranscriptionOptions,
        progress: @escaping TranscriptionProgressHandler = { _ in }
    ) async throws -> Transcript {
        guard !samples.isEmpty else { throw TranscriptionError.emptyAudio }
        let started = ContinuousClock.now
        let rate = Double(Self.sampleRate)
        let duration = Double(samples.count) / rate
        let speech = speechDetector.speechRegions(in: samples)
        let plan = planner.plan(sampleCount: samples.count, speech: speech)
        let cleaner = SegmentPostProcessor(removeHallucinations: options.guards.cleanUpText)
        let context = Context(
            samples: samples,
            options: options,
            prompt: Self.prompt(from: options.glossary),
            firstPassLanguage: Self.chunkLanguage(for: options.language),
            fallbackLanguage: Self.fallbackLanguage(for: options.language),
            cleaner: cleaner
        )

        var states = plan.map { ChunkState(chunk: $0) }
        let decodable = plan.indices.filter { planner.shouldDecode(plan[$0]) }
        let batchSize = max(decoder.preferredBatchSize, 1)
        progress(TranscriptionProgress(phase: .decoding, fractionCompleted: 0, totalSeconds: duration))

        // First pass, batch by batch.
        for batchStart in stride(from: 0, to: decodable.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(decodable[batchStart..<min(batchStart + batchSize, decodable.count)])
            let requests = batch.map { index in
                request(for: plan[index].samples, context: context, language: context.firstPassLanguage,
                        temperature: 0, fallbackCount: 5, prompt: context.prompt)
            }
            let outcomes = try await decoder.decode(requests)
            for (offset, index) in batch.enumerated() {
                let outcome = offset < outcomes.count ? outcomes[offset] : .failure(TranscriptionError.decodingFailed("missing result"))
                try states[index].acceptFirstPass(outcome, context: context, detector: loopDetector)
            }
            let decodedSeconds = plan[batch[batch.count - 1]].time.end
            progress(TranscriptionProgress(
                phase: .decoding, fractionCompleted: 0.9 * decodedSeconds / duration,
                decodedSeconds: decodedSeconds, totalSeconds: duration
            ))
        }

        progress(TranscriptionProgress(phase: .repairing, fractionCompleted: 0.9, decodedSeconds: duration, totalSeconds: duration))

        // Loop guard: all looping chunks re-decoded together so the decoder stays busy.
        if options.guards.redecodeLoops {
            try await repairLoops(in: decodable.filter { states[$0].loopWords > 0 }, states: &states, context: context)
        }

        if options.guards.cleanUpText {
            for index in states.indices where states[index].loopWords > 0 {
                states[index].collapseLoops(cleaner: cleaner, detector: loopDetector)
            }
        }

        var segments = cleaner.merge(states.flatMap(\.segments))
        var gaps: [SpeechGap] = []
        let found = SpeechCoverage.gaps(
            speech: speech,
            covered: segments.map { TimeRange(start: $0.start, end: $0.end) },
            minimumSpeech: options.guards.minimumMissingSpeech
        )
        if options.guards.redecodeMissingSpeech, !found.isEmpty {
            let recovered = try await recover(found, speech: speech, existing: segments, states: states, context: context)
            gaps = recovered.gaps
            segments = cleaner.merge(segments + recovered.segments)
        } else {
            gaps = found.map { SpeechGap(start: $0.range.start, end: $0.range.end, speechSeconds: $0.speechSeconds, recovered: false) }
        }

        progress(TranscriptionProgress(phase: .finished, fractionCompleted: 1, decodedSeconds: duration, totalSeconds: duration))
        let elapsed = started.duration(to: .now)
        return Transcript(
            segments: segments,
            chunks: states.map(\.report),
            gaps: gaps,
            duration: duration,
            speechSeconds: TimeRanges.totalDuration(speech),
            engine: decoder.identifier,
            options: options,
            wallTime: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        )
    }

    // MARK: - Loop guard

    private func repairLoops(in chunks: [Int], states: inout [ChunkState], context: Context) async throws {
        var looping = chunks
        let batchSize = max(decoder.preferredBatchSize, 1)
        for temperature in context.options.guards.loopRetryTemperatures where !looping.isEmpty {
            for batchStart in stride(from: 0, to: looping.count, by: batchSize) {
                try Task.checkCancellation()
                let batch = Array(looping[batchStart..<min(batchStart + batchSize, looping.count)])
                let requests = batch.map { index in
                    request(for: states[index].chunk.samples, context: context,
                            language: .fixed(states[index].language ?? context.fallbackLanguage),
                            temperature: temperature, fallbackCount: 1, prompt: nil)
                }
                let outcomes = try await decoder.decode(requests)
                for (offset, index) in batch.enumerated() where offset < outcomes.count {
                    guard case .success(let result) = outcomes[offset] else {
                        if case .failure(let error) = outcomes[offset], error is CancellationError { throw error }
                        continue
                    }
                    states[index].considerRetry(result, temperature: temperature, context: context, detector: loopDetector)
                }
            }
            looping = looping.filter { states[$0].loopWords > 0 }
        }
        Log.transcription.debug("Loop guard: \(looping.count, privacy: .public) chunk(s) still repeat after re-decoding")
    }

    // MARK: - Missing-speech guard

    private func recover(
        _ found: [SpeechCoverage.Gap],
        speech: [TimeRange],
        existing: [TranscribedSegment],
        states: [ChunkState],
        context: Context
    ) async throws -> (segments: [TranscribedSegment], gaps: [SpeechGap]) {
        let rate = Double(Self.sampleRate)
        let total = TimeRange(start: 0, end: Double(context.samples.count) / rate)
        let covered = TimeRanges.union(existing.map { TimeRange(start: $0.start, end: $0.end) })

        // Each gap becomes one or more ≤ 30 s pieces, decoded in the language of the chunk around it.
        struct Piece { var gap: Int; var samples: Range<Int>; var language: String }
        var pieces: [Piece] = []
        for (gapIndex, gap) in found.enumerated() {
            let window = gap.range.expanded(by: 0.5).clamped(to: total)
            let first = Int((window.start * rate).rounded(.down))
            let last = min(Int((window.end * rate).rounded(.up)), context.samples.count)
            guard last > first else { continue }
            let local = speech.compactMap { region -> TimeRange? in
                let clipped = region.clamped(to: window)
                return clipped.duration > 0 ? TimeRange(start: clipped.start - window.start, end: clipped.end - window.start) : nil
            }
            let language = states.first { $0.chunk.time.contains(gap.range.midpoint) }?.language ?? context.fallbackLanguage
            for sub in planner.plan(sampleCount: last - first, speech: local) {
                pieces.append(Piece(gap: gapIndex, samples: (first + sub.samples.lowerBound)..<(first + sub.samples.upperBound), language: language))
            }
        }

        var recoveredSegments: [TranscribedSegment] = []
        var recoveredGaps = Set<Int>()
        let batchSize = max(decoder.preferredBatchSize, 1)
        for batchStart in stride(from: 0, to: pieces.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(pieces[batchStart..<min(batchStart + batchSize, pieces.count)])
            let outcomes = try await decoder.decode(batch.map { piece in
                request(for: piece.samples, context: context, language: .fixed(piece.language),
                        temperature: 0, fallbackCount: 5, prompt: nil)
            })
            for (offset, piece) in batch.enumerated() where offset < outcomes.count {
                guard case .success(let result) = outcomes[offset] else {
                    if case .failure(let error) = outcomes[offset], error is CancellationError { throw error }
                    continue
                }
                let pieceTime = TimeRange(start: Double(piece.samples.lowerBound) / rate, end: Double(piece.samples.upperBound) / rate)
                let accepted = acceptRecovered(
                    result, pieceTime: pieceTime, gap: found[piece.gap].range, covered: covered, context: context
                )
                if !accepted.isEmpty {
                    recoveredGaps.insert(piece.gap)
                    recoveredSegments.append(contentsOf: accepted)
                }
            }
        }
        let gaps = found.enumerated().map { index, gap in
            SpeechGap(start: gap.range.start, end: gap.range.end, speechSeconds: gap.speechSeconds, recovered: recoveredGaps.contains(index))
        }
        return (recoveredSegments, gaps)
    }

    /// Keeps re-decoded text that lies in the gap, is not already transcribed, does not loop and
    /// is not a low-confidence guess.
    private func acceptRecovered(
        _ result: ChunkDecodeResult,
        pieceTime: TimeRange,
        gap: TimeRange,
        covered: [TimeRange],
        context: Context
    ) -> [TranscribedSegment] {
        let shifted = result.segments.map { Self.shift($0, by: pieceTime.start) }
        let cleaned = context.cleaner.clean(shifted, within: pieceTime)
        let target = gap.expanded(by: 0.5)
        let alreadyCovered = covered.map { $0.expanded(by: 0.1) }
        var accepted: [TranscribedSegment] = []
        for var segment in cleaned {
            guard segment.avgLogProb >= Self.recoveryLogProbThreshold else { continue }
            if segment.words.isEmpty {
                let time = TimeRange(start: segment.start, end: segment.end)
                let overlap = alreadyCovered.reduce(0) { $0 + $1.overlap(with: time) }
                guard target.contains(time.midpoint), overlap < time.duration / 2 else { continue }
            } else {
                // Drop words that were already transcribed (the window is padded) or lie outside the gap.
                let kept = segment.words.filter { word in
                    let mid = (word.start + word.end) / 2
                    return target.contains(mid) && !alreadyCovered.contains { $0.contains(mid) }
                }
                guard !kept.isEmpty else { continue }
                if kept.count != segment.words.count {
                    segment.words = kept
                    segment.text = kept.map(\.text).joined(separator: " ")
                }
                segment.start = kept[0].start
                segment.end = kept[kept.count - 1].end
            }
            guard SegmentPostProcessor.hasContent(segment.text),
                  loopDetector.repetitions(in: RepetitionDetector.words(in: segment.text)).isEmpty else { continue }
            segment.repair = .gapRecovered
            accepted.append(segment)
        }
        return accepted
    }

    /// Whisper's own "decoding failed" threshold; re-decoded speech below it is noise or a guess.
    static let recoveryLogProbThreshold = -1.0

    // MARK: - Helpers

    struct Context: Sendable {
        var samples: [Float]
        var options: TranscriptionOptions
        var prompt: String?
        var firstPassLanguage: ChunkLanguage
        var fallbackLanguage: String
        var cleaner: SegmentPostProcessor
    }

    private func request(
        for range: Range<Int>, context: Context, language: ChunkLanguage,
        temperature: Float, fallbackCount: Int, prompt: String?
    ) -> ChunkDecodeRequest {
        ChunkDecodeRequest(
            samples: Array(context.samples[range]),
            language: language,
            temperature: temperature,
            temperatureFallbackCount: fallbackCount,
            prompt: prompt,
            wordTimestamps: context.options.wordTimestamps
        )
    }

    static func shift(_ segment: TranscribedSegment, by offset: Double) -> TranscribedSegment {
        var segment = segment
        segment.start += offset
        segment.end += offset
        segment.words = segment.words.map { word in
            var word = word
            word.start += offset
            word.end += offset
            return word
        }
        return segment
    }

    static func chunkLanguage(for strategy: LanguageStrategy) -> ChunkLanguage {
        switch strategy {
        case .forced(let code): .fixed(code)
        case .detectAny: .detect(among: nil)
        case .detect(let candidates) where candidates.count == 1: .fixed(candidates[0])
        case .detect(let candidates) where candidates.isEmpty: .detect(among: nil)
        case .detect(let candidates): .detect(among: candidates)
        }
    }

    static func fallbackLanguage(for strategy: LanguageStrategy) -> String {
        switch strategy {
        case .forced(let code): code
        case .detectAny: "en"
        case .detect(let candidates): candidates.first ?? "en"
        }
    }

    /// Glossary terms as one comma-separated prompt, or nil.
    static func prompt(from glossary: [String]) -> String? {
        let terms = glossary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return terms.isEmpty ? nil : terms.joined(separator: ", ")
    }
}

// MARK: - Per-chunk state

struct ChunkState: Sendable {
    let chunk: PlannedChunk
    var language: String?
    var segments: [TranscribedSegment] = []
    var loopsFound = 0
    var loopWords = 0
    var loopsRemaining = 0
    var temperature: Float = 0
    var decoded = false

    init(chunk: PlannedChunk) {
        self.chunk = chunk
    }

    var report: ChunkReport {
        ChunkReport(
            start: chunk.time.start,
            end: chunk.time.end,
            language: decoded ? language : nil,
            speechSeconds: chunk.speechSeconds,
            segmentCount: segments.count,
            loopsFound: loopsFound,
            loopsRemaining: loopsRemaining,
            temperature: temperature
        )
    }

    mutating func acceptFirstPass(
        _ outcome: Result<ChunkDecodeResult, any Error>,
        context: GuardedTranscriber.Context,
        detector: RepetitionDetector
    ) throws {
        decoded = true
        switch outcome {
        case .success(let result):
            language = result.language.isEmpty ? nil : result.language
            segments = Self.place(result, in: chunk, cleaner: context.cleaner)
        case .failure(let error as CancellationError):
            throw error
        case .failure(let error):
            let start = chunk.time.start
            Log.transcription.error("Chunk at \(start, privacy: .public) s failed: \(String(describing: error), privacy: .public)")
            segments = []
        }
        let words = Self.words(of: segments)
        loopsFound = detector.repetitions(in: words).count
        loopWords = detector.redundantWordCount(in: words)
        loopsRemaining = loopsFound
    }

    /// Replaces the chunk's text with a re-decoding when it repeats less without losing content.
    mutating func considerRetry(
        _ result: ChunkDecodeResult,
        temperature: Float,
        context: GuardedTranscriber.Context,
        detector: RepetitionDetector
    ) {
        let candidate = Self.place(result, in: chunk, cleaner: context.cleaner)
        let candidateWords = Self.words(of: candidate)
        let candidateLoopWords = detector.redundantWordCount(in: candidateWords)
        let currentContent = Self.words(of: segments).count - loopWords
        let candidateContent = candidateWords.count - candidateLoopWords
        guard candidateLoopWords < loopWords, candidateContent * 2 >= currentContent else { return }
        segments = candidate.map { segment in
            var segment = segment
            segment.repair = .loopRedecoded
            return segment
        }
        loopWords = candidateLoopWords
        loopsRemaining = detector.repetitions(in: candidateWords).count
        self.temperature = temperature
    }

    mutating func collapseLoops(cleaner: SegmentPostProcessor, detector: RepetitionDetector) {
        let collapsed = cleaner.collapseRepetitions(in: segments, detector: detector)
        segments = collapsed.segments
        let remaining = detector.repetitions(in: Self.words(of: segments))
        loopWords = remaining.reduce(0) { $0 + $1.redundantWords }
        loopsRemaining = remaining.count
    }

    static func place(_ result: ChunkDecodeResult, in chunk: PlannedChunk, cleaner: SegmentPostProcessor) -> [TranscribedSegment] {
        let shifted = result.segments.map { GuardedTranscriber.shift($0, by: chunk.time.start) }
        return cleaner.clean(shifted, within: chunk.time)
    }

    static func words(of segments: [TranscribedSegment]) -> [String] {
        segments.flatMap { $0.words.isEmpty ? RepetitionDetector.words(in: $0.text) : $0.words.map(\.text) }
    }
}
