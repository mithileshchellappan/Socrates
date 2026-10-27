import Foundation
import StudyCore
@preconcurrency import WhisperKit

/// The on-device transcription engine: WhisperKit large-v3-turbo behind `GuardedTranscriber`.
///
///     let engine = WhisperKitEngine(store: try .shared())
///     let transcript = try await engine.transcribe(.file(url), options: TranscriptionOptions(course: course)) { progress in … }
///
/// The defaults are the evaluated configuration (docs/eval/transcription-m0.md): per-chunk
/// detection among German and English, all guards on, `.lecture` decoder tuning.
public struct WhisperKitEngine: TranscriptionEngine {
    public let decoder: WhisperKitDecoder
    public var transcriber: GuardedTranscriber

    public init(
        model: WhisperModel = .recommended,
        store: WhisperModelStore,
        concurrentChunks: Int? = nil,
        tuning: WhisperKitDecoder.Tuning = .lecture
    ) {
        let decoder = WhisperKitDecoder(model: model, store: store, concurrentChunks: concurrentChunks, tuning: tuning)
        self.decoder = decoder
        self.transcriber = GuardedTranscriber(decoder: decoder)
    }

    public var identifier: String { decoder.identifier }

    public func prepare(progress: @escaping TranscriptionProgressHandler = { _ in }) async throws {
        try await decoder.load(progress: progress)
    }

    public func transcribe(
        _ audio: TranscriptionAudio,
        options: TranscriptionOptions,
        progress: @escaping TranscriptionProgressHandler = { _ in }
    ) async throws -> Transcript {
        try await prepare(progress: progress)
        try Task.checkCancellation()
        progress(TranscriptionProgress(phase: .loadingAudio, fractionCompleted: 0))
        let timeline = try AudioTimeline.runs(audio)
        try Task.checkCancellation()
        let stored = timeline.runs.reduce(0) { $0 + $1.samples.count }
        Log.transcription.info(
            "Audio on the clock: \(timeline.runs.count, privacy: .public) runs, \(stored / AudioTimeline.sampleRate, privacy: .public) s of \(timeline.count / AudioTimeline.sampleRate, privacy: .public) s held"
        )
        let transcript = try await transcriber.transcribe(timeline: timeline, options: options, progress: progress)
        Log.transcription.info(
            "Transcribed \(transcript.duration, privacy: .public) s into \(transcript.segments.count, privacy: .public) segments in \(transcript.wallTime, privacy: .public) s"
        )
        return transcript
    }
}

/// Loads recording parts onto the recording clock at 16 kHz mono, as runs of continuous audio
/// (`SampleTimeline`): a pause or an interruption between parts is never held as samples, while
/// every time stays seconds from the clock's sample 0.
public enum AudioTimeline {
    public static let sampleRate = 16_000

    /// A part that starts at most this many samples after the current run's end joins it (a hole
    /// becomes zeros inside the run, as before): the resampling drift between a recording's files.
    /// A later part starts a new run (a pause, an interruption). Reads are the same either way.
    static let joinTolerance = sampleRate

    /// Room reserved per part beyond its expected length (resampling rounding), so a run never
    /// grows past what it reserved (an array that grows reallocates at up to twice its size).
    static let reserveMargin = sampleRate / 10

    /// The parts as runs on the recording clock. Each part's first sample sits at its start time
    /// rounded to a sample; a later part overwrites what overlaps it. A part no later part joins
    /// is its run as loaded (an imported file, the part before a pause: never copied); a run that
    /// later parts join reserves its room from their lengths (`Part.duration`) before it loads.
    static func runs(_ audio: TranscriptionAudio) throws -> SampleTimeline {
        guard !audio.parts.isEmpty else { throw TranscriptionError.emptyAudio }
        let parts = audio.parts.sorted { $0.startTime < $1.startTime }
        let offsets = parts.map { max(Int(($0.startTime * Double(sampleRate)).rounded()), 0) }
        var runs: [SampleTimeline.Run] = []
        var end = 0
        for (index, part) in parts.enumerated() {
            let offset = offsets[index]
            let samples = try samples(of: part)
            if let last = runs.indices.last, offset <= runs[last].end + joinTolerance {
                place(samples, at: offset - runs[last].start, in: &runs[last].samples)
            } else if index + 1 == parts.count || offsets[index + 1] > offset + samples.count + joinTolerance {
                runs.append(SampleTimeline.Run(start: offset, samples: samples))
            } else {
                var run = SampleTimeline.Run(start: offset, samples: [])
                run.samples.reserveCapacity(expectedLength(from: index, parts: parts, offsets: offsets))
                place(samples, at: 0, in: &run.samples)
                runs.append(run)
            }
            end = max(end, offset + samples.count)
        }
        guard end > 0 else { throw TranscriptionError.emptyAudio }
        return SampleTimeline(runs: runs, count: end)
    }

    /// All parts as one array, gaps as zeros (the bench's single files).
    public static func load(_ audio: TranscriptionAudio) throws -> [Float] {
        try runs(audio).contiguous
    }

    /// One part's samples at 16 kHz mono.
    static func samples(of part: TranscriptionAudio.Part) throws -> [Float] {
        do {
            return try AudioProcessor.loadAudioAsFloatArray(fromPath: part.url.path(percentEncoded: false))
        } catch {
            throw TranscriptionError.audioUnreadable(part.url.lastPathComponent)
        }
    }

    /// What the run that starts with part `index` will hold, from its parts' lengths (the parts
    /// that follow within the tolerance), with a margin per part; 0 when a length is unknown.
    static func expectedLength(from index: Int, parts: [TranscriptionAudio.Part], offsets: [Int]) -> Int {
        let start = offsets[index]
        var end = start
        var count = 0
        for next in index..<parts.count {
            guard let duration = parts[next].duration else { return 0 }
            if next > index, offsets[next] > end + joinTolerance { break }
            end = max(end, offsets[next] + Int((duration * Double(sampleRate)).rounded()))
            count += 1
        }
        return end - start + count * reserveMargin
    }

    /// Writes `samples` from `offset` in `run`, padding with silence or overwriting overlap.
    static func place(_ samples: [Float], at offset: Int, in run: inout [Float]) {
        if run.count < offset {
            run.append(contentsOf: repeatElement(0, count: offset - run.count))
        }
        let overlap = min(run.count - offset, samples.count)
        if overlap > 0 {
            run.replaceSubrange(offset..<(offset + overlap), with: samples[0..<overlap])
        }
        if overlap < samples.count {
            run.append(contentsOf: samples[max(overlap, 0)...])
        }
    }
}
