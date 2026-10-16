import Foundation

// MARK: - Input

/// Audio to transcribe: one or more files placed on a single recording clock.
///
/// A segmented recording (`recording_segment` rows) becomes one `Part` per file, each at its
/// `start_sample / sample_rate`. Gaps between parts are silence; times in the output are seconds
/// on this clock.
public struct TranscriptionAudio: Hashable, Sendable {
    public struct Part: Hashable, Sendable {
        public var url: URL
        /// Seconds on the recording clock where the file's first sample sits.
        public var startTime: Double

        public init(url: URL, startTime: Double = 0) {
            self.url = url
            self.startTime = startTime
        }
    }

    public var parts: [Part]

    public init(parts: [Part]) {
        self.parts = parts
    }

    public static func file(_ url: URL) -> TranscriptionAudio {
        TranscriptionAudio(parts: [Part(url: url)])
    }
}

/// How the spoken language is chosen for each chunk of audio.
public enum LanguageStrategy: Hashable, Sendable, Codable {
    /// Decode everything in one language (e.g. the course language). German speech decoded as
    /// English comes out translated, so only use this for single-language recordings.
    case forced(String)
    /// Detect the language per chunk among all Whisper languages.
    case detectAny
    /// Detect the language per chunk, restricted to the given candidates (argmax over these only).
    case detect(among: [String])

    /// The default for Exampleton lectures (see docs/decisions.md and docs/eval/transcription-m0.md).
    public static let germanEnglish: LanguageStrategy = .detect(among: ["de", "en"])
}

/// Guards that repair typical Whisper failures after the first pass.
public struct TranscriptionGuards: Hashable, Sendable, Codable {
    /// Re-decode a chunk at a higher temperature when it contains a repetition loop.
    public var redecodeLoops: Bool
    /// Temperatures tried, in order, when re-decoding a looping chunk.
    public var loopRetryTemperatures: [Float]
    /// Re-decode stretches of detected speech that came back without any text.
    public var redecodeMissingSpeech: Bool
    /// Minimum amount of uncovered speech (seconds) that counts as missing.
    public var minimumMissingSpeech: Double
    /// Remove repetitions that survive re-decoding (keep one copy) and drop known
    /// silence hallucinations ("Untertitel der Amara.org-Community", …).
    public var cleanUpText: Bool

    public init(
        redecodeLoops: Bool = true,
        loopRetryTemperatures: [Float] = [0.4, 0.8],
        redecodeMissingSpeech: Bool = true,
        minimumMissingSpeech: Double = 3,
        cleanUpText: Bool = true
    ) {
        self.redecodeLoops = redecodeLoops
        self.loopRetryTemperatures = loopRetryTemperatures
        self.redecodeMissingSpeech = redecodeMissingSpeech
        self.minimumMissingSpeech = minimumMissingSpeech
        self.cleanUpText = cleanUpText
    }

    public static let standard = TranscriptionGuards()
    public static let none = TranscriptionGuards(
        redecodeLoops: false, redecodeMissingSpeech: false, cleanUpText: false
    )
}

public struct TranscriptionOptions: Hashable, Sendable, Codable {
    public var language: LanguageStrategy
    /// Course terms (from course setup) passed to the decoder as a prompt. Empty for none.
    public var glossary: [String]
    public var wordTimestamps: Bool
    public var guards: TranscriptionGuards
    /// Chunks decoded concurrently. `nil` uses the engine default.
    public var concurrentChunks: Int?

    public init(
        language: LanguageStrategy = .germanEnglish,
        glossary: [String] = [],
        wordTimestamps: Bool = true,
        guards: TranscriptionGuards = .standard,
        concurrentChunks: Int? = nil
    ) {
        self.language = language
        self.glossary = glossary
        self.wordTimestamps = wordTimestamps
        self.guards = guards
        self.concurrentChunks = concurrentChunks
    }
}

// MARK: - Progress

public struct TranscriptionProgress: Hashable, Sendable {
    public enum Phase: String, Hashable, Sendable, Codable {
        case downloadingModel
        case loadingModel
        case loadingAudio
        case decoding
        case repairing
        case finished
    }

    public var phase: Phase
    /// 0…1 within the whole job (model preparation is reported separately by `prepare`).
    public var fractionCompleted: Double
    /// Seconds of audio decoded so far (first pass).
    public var decodedSeconds: Double
    public var totalSeconds: Double

    public init(phase: Phase, fractionCompleted: Double, decodedSeconds: Double = 0, totalSeconds: Double = 0) {
        self.phase = phase
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
        self.decodedSeconds = decodedSeconds
        self.totalSeconds = totalSeconds
    }
}

public typealias TranscriptionProgressHandler = @Sendable (TranscriptionProgress) -> Void

// MARK: - Output

/// One word with timing. Times are seconds on the recording clock.
public struct TranscribedWord: Hashable, Sendable, Codable {
    public var text: String
    public var start: Double
    public var end: Double
    /// Decoder probability of the word's tokens, 0…1.
    public var probability: Double

    public init(text: String, start: Double, end: Double, probability: Double) {
        self.text = text
        self.start = start
        self.end = end
        self.probability = probability
    }
}

/// Why a segment differs from the plain first decoding pass.
public enum SegmentRepair: String, Hashable, Sendable, Codable {
    /// The chunk looped and was re-decoded at a higher temperature.
    case loopRedecoded
    /// A repetition survived re-decoding and was collapsed to one copy.
    case loopCollapsed
    /// The text came from re-decoding speech the first pass skipped.
    case gapRecovered
}

public struct TranscribedSegment: Hashable, Sendable, Codable {
    /// Seconds on the recording clock.
    public var start: Double
    public var end: Double
    public var text: String
    /// Whisper language code ("de", "en", …), BCP 47 compatible for these languages.
    public var language: String
    public var words: [TranscribedWord]
    /// Mean token log probability from the decoder (≤ 0).
    public var avgLogProb: Double
    /// Whisper no-speech probability. WhisperKit 1.1 does not compute it yet and reports 0.
    public var noSpeechProb: Double
    public var compressionRatio: Double
    /// Sampling temperature the text was decoded with.
    public var temperature: Double
    public var repair: SegmentRepair?

    public init(
        start: Double,
        end: Double,
        text: String,
        language: String,
        words: [TranscribedWord] = [],
        avgLogProb: Double = 0,
        noSpeechProb: Double = 0,
        compressionRatio: Double = 1,
        temperature: Double = 0,
        repair: SegmentRepair? = nil
    ) {
        self.start = start
        self.end = end
        self.text = text
        self.language = language
        self.words = words
        self.avgLogProb = avgLogProb
        self.noSpeechProb = noSpeechProb
        self.compressionRatio = compressionRatio
        self.temperature = temperature
        self.repair = repair
    }

    /// exp(avgLogProb), 0…1: a rough per-segment confidence.
    public var confidence: Double { min(max(exp(avgLogProb), 0), 1) }
}

/// What happened to one decoding chunk (≤ 30 s of audio).
public struct ChunkReport: Hashable, Sendable, Codable {
    public var start: Double
    public var end: Double
    /// Language the chunk was decoded in; `nil` when the chunk was skipped as silence.
    public var language: String?
    public var speechSeconds: Double
    public var segmentCount: Int
    /// Repetition loops found in the first pass.
    public var loopsFound: Int
    /// Loops left after the guard ran (re-decode and clean-up).
    public var loopsRemaining: Int
    /// Temperature of the accepted decoding.
    public var temperature: Float

    public init(
        start: Double, end: Double, language: String?, speechSeconds: Double, segmentCount: Int,
        loopsFound: Int = 0, loopsRemaining: Int = 0, temperature: Float = 0
    ) {
        self.start = start
        self.end = end
        self.language = language
        self.speechSeconds = speechSeconds
        self.segmentCount = segmentCount
        self.loopsFound = loopsFound
        self.loopsRemaining = loopsRemaining
        self.temperature = temperature
    }
}

/// A stretch of detected speech that the first pass returned no text for.
public struct SpeechGap: Hashable, Sendable, Codable {
    public var start: Double
    public var end: Double
    public var speechSeconds: Double
    /// True when re-decoding produced accepted text for it.
    public var recovered: Bool

    public init(start: Double, end: Double, speechSeconds: Double, recovered: Bool) {
        self.start = start
        self.end = end
        self.speechSeconds = speechSeconds
        self.recovered = recovered
    }
}

public struct Transcript: Hashable, Sendable, Codable {
    public var segments: [TranscribedSegment]
    public var chunks: [ChunkReport]
    public var gaps: [SpeechGap]
    /// Seconds of audio on the recording clock.
    public var duration: Double
    /// Seconds of speech found by the voice activity detector.
    public var speechSeconds: Double
    /// e.g. "whisperkit/openai_whisper-large-v3-v20240930".
    public var engine: String
    public var options: TranscriptionOptions
    /// Wall-clock seconds the job took (excluding model preparation).
    public var wallTime: Double

    public init(
        segments: [TranscribedSegment], chunks: [ChunkReport], gaps: [SpeechGap], duration: Double,
        speechSeconds: Double, engine: String, options: TranscriptionOptions, wallTime: Double
    ) {
        self.segments = segments
        self.chunks = chunks
        self.gaps = gaps
        self.duration = duration
        self.speechSeconds = speechSeconds
        self.engine = engine
        self.options = options
        self.wallTime = wallTime
    }

    /// Languages in order of first appearance with the seconds of audio decoded in each.
    public var languageSeconds: [(language: String, seconds: Double)] {
        var order: [String] = []
        var seconds: [String: Double] = [:]
        for chunk in chunks {
            guard let language = chunk.language else { continue }
            if seconds[language] == nil { order.append(language) }
            seconds[language, default: 0] += chunk.end - chunk.start
        }
        return order.map { ($0, seconds[$0] ?? 0) }
    }
}

// MARK: - Engine

/// Turns recorded audio into timed, language-tagged segments.
///
/// Implementations run off the main actor, report progress through the handler (called from any
/// thread) and stop promptly with `CancellationError` when the calling task is cancelled.
public protocol TranscriptionEngine: Sendable {
    /// Stable identifier stored with results, e.g. "whisperkit/openai_whisper-large-v3-v20240930".
    var identifier: String { get }

    /// Downloads (once) and loads the model. Safe to call repeatedly; `transcribe` calls it too.
    func prepare(progress: @escaping TranscriptionProgressHandler) async throws

    func transcribe(
        _ audio: TranscriptionAudio,
        options: TranscriptionOptions,
        progress: @escaping TranscriptionProgressHandler
    ) async throws -> Transcript
}

public enum TranscriptionError: Error, Hashable, Sendable {
    case audioUnreadable(String)
    case emptyAudio
    case modelUnavailable(String)
    case decodingFailed(String)
}
