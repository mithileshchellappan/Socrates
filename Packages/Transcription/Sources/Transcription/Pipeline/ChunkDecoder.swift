import Foundation

/// How a single chunk's language is chosen by the decoder.
public enum ChunkLanguage: Hashable, Sendable {
    case fixed(String)
    /// Let the decoder detect it; `nil` candidates means any Whisper language.
    case detect(among: [String]?)
}

/// One decode call for at most 30 s of 16 kHz mono audio.
public struct ChunkDecodeRequest: Sendable {
    public var samples: [Float]
    public var language: ChunkLanguage
    /// Starting temperature; the decoder may raise it on its own fallback rules.
    public var temperature: Float
    /// How many times the decoder may raise the temperature by 0.2 on failure.
    public var temperatureFallbackCount: Int
    /// Conditioning text (glossary), or nil.
    public var prompt: String?
    public var wordTimestamps: Bool

    public init(
        samples: [Float], language: ChunkLanguage, temperature: Float = 0,
        temperatureFallbackCount: Int = 5, prompt: String? = nil, wordTimestamps: Bool = true
    ) {
        self.samples = samples
        self.language = language
        self.temperature = temperature
        self.temperatureFallbackCount = temperatureFallbackCount
        self.prompt = prompt
        self.wordTimestamps = wordTimestamps
    }
}

public struct ChunkDecodeResult: Hashable, Sendable {
    /// Language the decoder used for (the last window of) this chunk.
    public var language: String
    /// Segments with times relative to the start of the request's samples.
    public var segments: [TranscribedSegment]

    public init(language: String, segments: [TranscribedSegment]) {
        self.language = language
        self.segments = segments
    }
}

/// The model-facing part of the pipeline. `GuardedTranscriber` owns chunking, guards and
/// post-processing; a decoder only turns short audio into segments. Tests use a fake.
public protocol ChunkDecoder: Sendable {
    /// Short identifier, e.g. "whisperkit/openai_whisper-large-v3-v20240930".
    var identifier: String { get }
    /// Chunks the caller should send per `decode` call to keep the model busy.
    var preferredBatchSize: Int { get }

    /// Decodes the requests, possibly concurrently. Results are in request order; a failed chunk
    /// is a `.failure` and does not fail the others. Throws `CancellationError` when cancelled.
    func decode(_ requests: [ChunkDecodeRequest]) async throws -> [Result<ChunkDecodeResult, any Error>]
}
