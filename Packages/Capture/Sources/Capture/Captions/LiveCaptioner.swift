import AVFAudio
import CoreMedia
import Foundation
import Speech
import Synchronization

/// Provisional on-device captions from the recording's audio with Apple's `SpeechTranscriber`.
///
/// Optional and isolated: if the transcriber or the locale is unavailable, or anything fails,
/// the caller simply shows no captions. Nothing here touches the recording itself.
public enum LiveCaptioner {
    public enum Failure: Error, Equatable, Sendable {
        case unavailable
        case noCompatibleFormat
    }

    /// The supported locale equivalent to `locale`, or nil when live captions are unavailable.
    public static func supportedLocale(for locale: Locale) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    /// Transcribes audio and yields the growing transcript.
    ///
    /// Speech assets are installed first if needed; only then is `audio` called to subscribe,
    /// so nothing is buffered while waiting. The first element (empty) means captions are
    /// running. The stream finishes when the audio ends and throws if captions cannot run.
    public static func captions(
        locale: Locale,
        clock: RecordingClock,
        audio: @escaping @Sendable () -> AsyncStream<AudioChunk>
    ) -> AsyncThrowingStream<CaptionTranscript, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(locale: locale, clock: clock, audio: audio, output: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        locale: Locale,
        clock: RecordingClock,
        audio: @escaping @Sendable () -> AsyncStream<AudioChunk>,
        output: AsyncThrowingStream<CaptionTranscript, any Error>.Continuation
    ) async throws {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else { throw Failure.unavailable }

        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.transcriptionConfidence]
        )
        if await !AssetInventory.reservedLocales.contains(supported) {
            _ = try? await AssetInventory.reserve(locale: supported)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            CaptureLog.captions.info("Installing speech assets for \(supported.identifier, privacy: .public)")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.noCompatibleFormat
        }

        let (inputs, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: inputs)
        let timeline = CaptionTimeline()

        var transcript = CaptionTranscript(localeIdentifier: supported.identifier)
        output.yield(transcript)
        CaptureLog.captions.info("Live captions running (\(supported.identifier, privacy: .public))")

        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                let chunks = audio()
                group.addTask {
                    await feed(chunks, format: format, clock: clock, timeline: timeline, into: inputContinuation)
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                }
                for try await result in transcriber.results {
                    let runs = result.text.runs.map { run in
                        let confidence = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
                        return CaptionTranscript.Run(
                            text: String(result.text[run.range].characters),
                            isLowConfidence: confidence.map { $0 < 0.5 } ?? false
                        )
                    }
                    let start = timeline.recordingTime(forAnalyzerTime: result.range.start.seconds)
                    transcript.apply(runs: runs, start: start, isFinal: result.isFinal)
                    output.yield(transcript)
                }
                try await group.waitForAll()
            }
        } onCancel: {
            inputContinuation.finish()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// Converts chunks to the analyzer's format and hands them over. Analyzer time 0 is the
    /// first chunk; after an input discontinuity the buffer start time skips the gap.
    private static func feed(
        _ chunks: AsyncStream<AudioChunk>,
        format: AVAudioFormat,
        clock: RecordingClock,
        timeline: CaptionTimeline,
        into inputs: AsyncStream<AnalyzerInput>.Continuation
    ) async {
        var converter: PCMConverter?
        var run: Int?
        var analyzerSeconds: Double = 0
        for await chunk in chunks {
            guard chunk.barrier == nil else { continue }
            let chunkTime = chunk.hostTime
                .flatMap { clock.sampleTime(atHostTime: $0) }
                .map { clock.seconds(forSample: $0) }
            var startTime: CMTime?
            if run == nil {
                timeline.setOrigin(chunkTime ?? 0)
            } else if run != chunk.run, let chunkTime {
                analyzerSeconds = max(analyzerSeconds, chunkTime - timeline.origin)
                startTime = CMTime(seconds: analyzerSeconds, preferredTimescale: CMTimeScale(format.sampleRate))
            }
            if run != chunk.run || converter?.sourceSampleRate != chunk.sampleRate {
                converter = PCMConverter(sourceSampleRate: chunk.sampleRate, targetFormat: format)
            }
            run = chunk.run
            guard let converter else { continue }
            for buffer in converter.convert(chunk.samples) {
                inputs.yield(AnalyzerInput(buffer: buffer, bufferStartTime: startTime))
                startTime = nil
                analyzerSeconds += Double(buffer.frameLength) / format.sampleRate
            }
        }
        inputs.finish()
    }
}

/// Recording-clock seconds of analyzer time 0, shared between the feeder and the result loop.
private final class CaptionTimeline: Sendable {
    private let originSeconds = Mutex<Double>(0)

    var origin: Double { originSeconds.withLock { $0 } }

    func setOrigin(_ seconds: Double) {
        originSeconds.withLock { $0 = seconds }
    }

    func recordingTime(forAnalyzerTime seconds: Double) -> TimeInterval {
        origin + (seconds.isFinite ? seconds : 0)
    }
}
