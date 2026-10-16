import Foundation
import StudyCore

/// The transcription pipeline around a `ChunkDecoder`:
///
/// 1. Voice activity detection over the whole recording.
/// 2. Chunks of ≤ 30 s cut at pauses; chunks without speech are skipped.
/// 3. First pass: chunks decoded in batches, each with its own language decision.
/// 4. Loop guard: a chunk whose text repeats an n-gram is re-decoded at higher temperatures in
///    the language it was detected in; the decoding with the fewest repeated words wins.
/// 5. Language boundary guard: a chunk next to a chunk of another language is split at its
///    longest pause and each half picks its own language (kept only if the halves differ).
/// 6. Clean-up: repetitions that survive are collapsed to one copy, silence hallucinations dropped.
/// 7. Missing-speech guard: detected speech without text (≥ 3 s) is re-decoded on its own, with
///    its own language decision.
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

        // Language boundaries: a chunk next to a chunk of another language usually holds the switch
        // itself; its minority language would come out translated or not at all.
        if options.guards.refineLanguageBoundaries, case .detect = context.firstPassLanguage {
            states = try await refineLanguageBoundaries(states, speech: speech, context: context)
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
            let recovered = try await recover(found, speech: speech, existing: segments, context: context)
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

    // MARK: - Language boundary guard

    /// Splits each chunk that borders a chunk of another language at its longest pause and decodes
    /// both halves with their own language decision. The split is kept only when the halves come
    /// back in different languages without looping; otherwise the chunk had no switch inside.
    func refineLanguageBoundaries(_ states: [ChunkState], speech: [TimeRange], context: Context) async throws -> [ChunkState] {
        var candidates: [(index: Int, halves: [PlannedChunk])] = []
        for index in states.indices {
            guard let language = states[index].language else { continue }
            let bordersOtherLanguage = [index - 1, index + 1].contains { neighbour in
                guard states.indices.contains(neighbour), let other = states[neighbour].language else { return false }
                return other != language
            }
            guard bordersOtherLanguage, let halves = split(states[index].chunk, speech: speech) else { continue }
            candidates.append((index, halves))
        }
        guard !candidates.isEmpty else { return states }

        let halves = candidates.flatMap(\.halves)
        var outcomes: [Result<ChunkDecodeResult, any Error>] = []
        let batchSize = max(decoder.preferredBatchSize, 1)
        for batchStart in stride(from: 0, to: halves.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = halves[batchStart..<min(batchStart + batchSize, halves.count)]
            outcomes += try await decoder.decode(batch.map { half in
                request(for: half.samples, context: context, language: context.firstPassLanguage,
                        temperature: 0, fallbackCount: 5, prompt: context.prompt)
            })
        }

        var refined = states
        // Back to front so replacing one state with two keeps earlier indexes valid.
        for (number, candidate) in candidates.enumerated().reversed() {
            let first = 2 * number
            guard first + 1 < outcomes.count,
                  case .success(let left) = outcomes[first], case .success(let right) = outcomes[first + 1],
                  !left.language.isEmpty, !right.language.isEmpty, left.language != right.language else { continue }
            var leftState = ChunkState(chunk: candidate.halves[0])
            var rightState = ChunkState(chunk: candidate.halves[1])
            try leftState.acceptFirstPass(.success(left), context: context, detector: loopDetector)
            try rightState.acceptFirstPass(.success(right), context: context, detector: loopDetector)
            guard leftState.loopWords == 0, rightState.loopWords == 0 else { continue }
            leftState.markRepaired(.languageSplit)
            rightState.markRepaired(.languageSplit)
            refined.replaceSubrange(candidate.index...candidate.index, with: [leftState, rightState])
        }
        return refined
    }

    /// The chunk cut in its longest pause, if both halves keep at least a second of speech.
    func split(_ chunk: PlannedChunk, speech: [TimeRange]) -> [PlannedChunk]? {
        let inner = TimeRange(start: chunk.time.start + 1, end: chunk.time.end - 1)
        guard inner.duration > 0,
              let pause = TimeRanges.subtract(speech, from: [inner]).max(by: { $0.duration < $1.duration }) else { return nil }
        let rate = Double(Self.sampleRate)
        let cut = min(max(Int((pause.midpoint * rate).rounded()), chunk.samples.lowerBound + 1), chunk.samples.upperBound - 1)
        let leftTime = TimeRange(start: chunk.time.start, end: Double(cut) / rate)
        let rightTime = TimeRange(start: Double(cut) / rate, end: chunk.time.end)
        let leftSpeech = TimeRanges.seconds(of: speech, within: leftTime)
        let rightSpeech = TimeRanges.seconds(of: speech, within: rightTime)
        guard leftSpeech >= 1, rightSpeech >= 1 else { return nil }
        return [
            PlannedChunk(samples: chunk.samples.lowerBound..<cut, time: leftTime, speechSeconds: leftSpeech),
            PlannedChunk(samples: cut..<chunk.samples.upperBound, time: rightTime, speechSeconds: rightSpeech),
        ]
    }

    // MARK: - Missing-speech guard

    private func recover(
        _ found: [SpeechCoverage.Gap],
        speech: [TimeRange],
        existing: [TranscribedSegment],
        context: Context
    ) async throws -> (segments: [TranscribedSegment], gaps: [SpeechGap]) {
        let rate = Double(Self.sampleRate)
        let total = TimeRange(start: 0, end: Double(context.samples.count) / rate)
        let covered = TimeRanges.union(existing.map { TimeRange(start: $0.start, end: $0.end) })

        // Each gap becomes one or more ≤ 30 s pieces. With a detecting strategy each piece gets its
        // own language decision: speech dropped inside a chunk is often in the chunk's other language.
        struct Piece { var gap: Int; var samples: Range<Int>; var language: ChunkLanguage }
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
            let language = context.firstPassLanguage
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
                request(for: piece.samples, context: context, language: piece.language,
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
                  ChunkState.loops(in: [segment], detector: loopDetector).redundantWords == 0 else { continue }
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
        let score = Self.loops(in: segments, detector: detector)
        loopsFound = score.loops
        loopWords = score.redundantWords
        loopsRemaining = loopsFound
    }

    /// Repetition loops in the segments' words, including loops inside hyphenated tokens.
    static func loops(in segments: [TranscribedSegment], detector: RepetitionDetector) -> (loops: Int, redundantWords: Int) {
        let words = words(of: segments)
        let repetitions = detector.repetitions(in: words)
        let inToken = words.filter { RepetitionDetector.hyphenatedCopies(in: $0) >= RepetitionDetector.minimumHyphenatedCopies }
        return (
            repetitions.count + inToken.count,
            repetitions.reduce(0) { $0 + $1.redundantWords } + RepetitionDetector.hyphenatedRedundancy(in: words)
        )
    }

    /// Replaces the chunk's text with a re-decoding when it repeats less without losing content.
    mutating func considerRetry(
        _ result: ChunkDecodeResult,
        temperature: Float,
        context: GuardedTranscriber.Context,
        detector: RepetitionDetector
    ) {
        let candidate = Self.place(result, in: chunk, cleaner: context.cleaner)
        let candidateScore = Self.loops(in: candidate, detector: detector)
        let currentContent = Self.contentWords(of: segments, detector: detector)
        let candidateContent = Self.contentWords(of: candidate, detector: detector)
        guard candidateScore.redundantWords < loopWords, candidateContent * 2 >= currentContent else { return }
        segments = candidate.map { segment in
            var segment = segment
            segment.repair = .loopRedecoded
            return segment
        }
        loopWords = candidateScore.redundantWords
        loopsRemaining = candidateScore.loops
        self.temperature = temperature
    }

    mutating func markRepaired(_ repair: SegmentRepair) {
        segments = segments.map { segment in
            var segment = segment
            segment.repair = repair
            return segment
        }
    }

    mutating func collapseLoops(cleaner: SegmentPostProcessor, detector: RepetitionDetector) {
        let collapsed = cleaner.collapseRepetitions(in: segments, detector: detector)
        segments = collapsed.segments
        let remaining = Self.loops(in: segments, detector: detector)
        loopWords = remaining.redundantWords
        loopsRemaining = remaining.loops
    }

    static func place(_ result: ChunkDecodeResult, in chunk: PlannedChunk, cleaner: SegmentPostProcessor) -> [TranscribedSegment] {
        let shifted = result.segments.map { GuardedTranscriber.shift($0, by: chunk.time.start) }
        return cleaner.clean(shifted, within: chunk.time)
    }

    /// Words outside repeated n-grams; a token looping inside itself counts as one word.
    static func contentWords(of segments: [TranscribedSegment], detector: RepetitionDetector) -> Int {
        let words = words(of: segments)
        return words.count - detector.redundantWordCount(in: words)
    }

    static func words(of segments: [TranscribedSegment]) -> [String] {
        segments.flatMap { $0.words.isEmpty ? RepetitionDetector.words(in: $0.text) : $0.words.map(\.text) }
    }
}
