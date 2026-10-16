import Foundation
import StudyCore
@preconcurrency import WhisperKit

/// The on-device transcription engine: WhisperKit large-v3-turbo behind `GuardedTranscriber`.
///
///     let engine = WhisperKitEngine(store: try .shared())
///     let transcript = try await engine.transcribe(.file(url), options: TranscriptionOptions(
///         language: .germanEnglish, glossary: course.glossaryTerms
///     )) { progress in … }
public struct WhisperKitEngine: TranscriptionEngine {
    public let decoder: WhisperKitDecoder
    public var transcriber: GuardedTranscriber

    public init(
        model: WhisperModel = .largeV3Turbo,
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
        let samples = try AudioTimeline.load(audio)
        try Task.checkCancellation()
        var transcriber = transcriber
        transcriber.decoder = decoder
        let transcript = try await transcriber.transcribe(samples: samples, options: options, progress: progress)
        Log.transcription.info(
            "Transcribed \(transcript.duration, privacy: .public) s into \(transcript.segments.count, privacy: .public) segments in \(transcript.wallTime, privacy: .public) s"
        )
        return transcript
    }
}

/// Loads recording parts into one 16 kHz mono sample array on the recording clock.
public enum AudioTimeline {
    public static let sampleRate = 16_000

    public static func load(_ audio: TranscriptionAudio) throws -> [Float] {
        guard !audio.parts.isEmpty else { throw TranscriptionError.emptyAudio }
        var timeline: [Float] = []
        for part in audio.parts.sorted(by: { $0.startTime < $1.startTime }) {
            let samples: [Float]
            do {
                samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: part.url.path(percentEncoded: false))
            } catch {
                throw TranscriptionError.audioUnreadable(part.url.lastPathComponent)
            }
            place(samples, at: part.startTime, in: &timeline)
        }
        guard !timeline.isEmpty else { throw TranscriptionError.emptyAudio }
        return timeline
    }

    /// Writes `samples` starting at `startTime`, padding with silence or overwriting overlap.
    static func place(_ samples: [Float], at startTime: Double, in timeline: inout [Float]) {
        let offset = max(Int((startTime * Double(sampleRate)).rounded()), 0)
        if timeline.count < offset {
            timeline.append(contentsOf: repeatElement(0, count: offset - timeline.count))
        }
        let overlap = min(timeline.count - offset, samples.count)
        if overlap > 0 {
            timeline.replaceSubrange(offset..<(offset + overlap), with: samples[0..<overlap])
        }
        if overlap < samples.count {
            timeline.append(contentsOf: samples[max(overlap, 0)...])
        }
    }
}
