import Foundation
import StudyCore
@preconcurrency import WhisperKit

/// `ChunkDecoder` backed by an in-process WhisperKit pipeline.
///
/// WhisperKit's types are not `Sendable`; this actor owns the one `WhisperKit` instance and is
/// the only code that touches it.
public actor WhisperKitDecoder: ChunkDecoder {
    public nonisolated let model: WhisperModel
    public nonisolated let store: WhisperModelStore
    public nonisolated let identifier: String
    public nonisolated let preferredBatchSize: Int

    private var kit: WhisperKit?
    private var baseTokenizer: (any WhisperTokenizer)?
    /// The language filter WhisperKit has built. It builds it lazily on the first detection and
    /// caches it until the models are unloaded.
    private var builtFilter: LanguageFilter?
    private var promptTokenCache: [String: [Int]] = [:]

    /// Prompt tokens are capped well below Whisper's 223-token limit so a 30 s window keeps room
    /// for its own text.
    static let maxPromptTokens = 96

    /// Decoder thresholds that decide when WhisperKit retries a window at a higher temperature.
    public struct Tuning: Hashable, Sendable, Codable {
        /// Fail a window whose first text token is less likely than this (WhisperKit-specific).
        public var firstTokenLogProbThreshold: Float?
        /// Fail a window whose mean token log probability is below this (OpenAI default -1).
        public var logProbThreshold: Float?
        /// Fail a window whose text compresses better than this (repetition; OpenAI default 2.4).
        public var compressionRatioThreshold: Float?

        public init(firstTokenLogProbThreshold: Float?, logProbThreshold: Float?, compressionRatioThreshold: Float?) {
            self.firstTokenLogProbThreshold = firstTokenLogProbThreshold
            self.logProbThreshold = logProbThreshold
            self.compressionRatioThreshold = compressionRatioThreshold
        }

        /// WhisperKit 1.1 defaults. On far-field lecture audio the first word of most windows
        /// scores below -1.5, so nearly every window fails at temperature 0 and is re-sampled
        /// at 0.2–1.0 (see docs/eval/transcription-m0.md).
        public static let whisperKitDefaults = Tuning(
            firstTokenLogProbThreshold: -1.5, logProbThreshold: -1, compressionRatioThreshold: 2.4
        )

        /// OpenAI Whisper's rules: no first-token check. Silent chunks are skipped by the VAD
        /// and silence hallucinations are filtered afterwards instead.
        public static let lecture = Tuning(
            firstTokenLogProbThreshold: nil, logProbThreshold: -1, compressionRatioThreshold: 2.4
        )
    }

    public nonisolated let tuning: Tuning

    public init(
        model: WhisperModel = .largeV3Turbo,
        store: WhisperModelStore,
        concurrentChunks: Int? = nil,
        tuning: Tuning = .lecture
    ) {
        self.model = model
        self.store = store
        self.tuning = tuning
        self.identifier = "whisperkit/\(model.name)"
        #if os(macOS)
        self.preferredBatchSize = max(concurrentChunks ?? 16, 1)
        #else
        self.preferredBatchSize = max(concurrentChunks ?? 4, 1)
        #endif
    }

    public var isLoaded: Bool { kit != nil }

    /// Downloads the model if needed and loads it. The first load on a machine compiles the
    /// Core ML model for the device, which takes minutes for large-v3-turbo.
    public func load(progress: @escaping TranscriptionProgressHandler = { _ in }) async throws {
        if kit != nil { return }
        let folder: URL
        if store.isDownloaded(model) {
            folder = store.folder(for: model)
        } else {
            progress(TranscriptionProgress(phase: .downloadingModel, fractionCompleted: 0))
            folder = try await store.download(model) { fraction in
                progress(TranscriptionProgress(phase: .downloadingModel, fractionCompleted: fraction))
            }
        }
        try Task.checkCancellation()
        progress(TranscriptionProgress(phase: .loadingModel, fractionCompleted: 0))
        let started = ContinuousClock.now
        let config = WhisperKitConfig(
            model: model.name,
            downloadBase: store.directory,
            modelRepo: model.repository,
            modelFolder: folder.path(percentEncoded: false),
            tokenizerFolder: store.directory,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        let loaded: WhisperKit
        do {
            loaded = try await WhisperKit(config)
        } catch {
            throw TranscriptionError.modelUnavailable(String(describing: error))
        }
        guard let tokenizer = loaded.tokenizer else {
            throw TranscriptionError.modelUnavailable("tokenizer missing")
        }
        kit = loaded
        baseTokenizer = tokenizer
        builtFilter = nil
        promptTokenCache = [:]
        let seconds = Double(started.duration(to: .now).components.seconds)
        Log.transcription.info("Loaded \(self.model.name, privacy: .public) in \(seconds, privacy: .public) s")
        progress(TranscriptionProgress(phase: .loadingModel, fractionCompleted: 1))
    }

    public func unload() async {
        await kit?.unloadModels()
        kit = nil
        baseTokenizer = nil
        builtFilter = nil
    }

    // MARK: - ChunkDecoder

    public func decode(_ requests: [ChunkDecodeRequest]) async throws -> [Result<ChunkDecodeResult, any Error>] {
        guard !requests.isEmpty else { return [] }
        try Task.checkCancellation()
        try await load()

        // All requests in one WhisperKit call share the language filter, so group by it.
        var results = [Result<ChunkDecodeResult, any Error>?](repeating: nil, count: requests.count)
        var groups: [LanguageFilter: [Int]] = [:]
        var groupOrder: [LanguageFilter] = []
        for (index, request) in requests.enumerated() {
            let key = LanguageFilter(request.language)
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(index)
        }
        for key in groupOrder {
            let indexes = groups[key] ?? []
            try await install(key)
            let groupResults = try await run(indexes.map { requests[$0] })
            for (offset, index) in indexes.enumerated() {
                results[index] = groupResults[offset]
            }
        }
        return results.map { $0 ?? .failure(TranscriptionError.decodingFailed("chunk not decoded")) }
    }

    private func run(_ requests: [ChunkDecodeRequest]) async throws -> [Result<ChunkDecodeResult, any Error>] {
        guard let kit else { throw TranscriptionError.modelUnavailable("not loaded") }
        let options: [DecodingOptions?] = requests.map { decodingOptions(for: $0, workers: requests.count) }
        let outcomes = await kit.transcribeWithOptions(
            audioArrays: requests.map(\.samples),
            decodeOptionsArray: options
        )
        try Task.checkCancellation()
        guard outcomes.count == requests.count else {
            var message = "result count mismatch"
            if case .failure(let error)? = outcomes.first { message = String(describing: error) }
            throw TranscriptionError.decodingFailed(message)
        }
        return outcomes.map { outcome in
            switch outcome {
            case .success(let results):
                .success(Self.convert(results))
            case .failure(let error as CancellationError):
                .failure(error)
            case .failure(let error):
                .failure(TranscriptionError.decodingFailed(String(describing: error)))
            }
        }
    }

    private func decodingOptions(for request: ChunkDecodeRequest, workers: Int) -> DecodingOptions {
        let language: String?
        switch request.language {
        case .fixed(let code): language = code
        case .detect: language = nil
        }
        return DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: request.temperature,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: request.temperatureFallbackCount,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: request.wordTimestamps,
            promptTokens: request.prompt.flatMap(promptTokens(for:)),
            compressionRatioThreshold: tuning.compressionRatioThreshold,
            logProbThreshold: tuning.logProbThreshold,
            firstTokenLogProbThreshold: tuning.firstTokenLogProbThreshold,
            concurrentWorkerCount: max(workers, 1),
            chunkingStrategy: ChunkingStrategy.none
        )
    }

    private func promptTokens(for text: String) -> [Int]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let tokenizer = baseTokenizer else { return nil }
        if let cached = promptTokenCache[trimmed] { return cached.isEmpty ? nil : cached }
        let special = tokenizer.specialTokens.specialTokenBegin
        let tokens = Array(tokenizer.encode(text: " " + trimmed).filter { $0 < special }.prefix(Self.maxPromptTokens))
        promptTokenCache[trimmed] = tokens
        return tokens.isEmpty ? nil : tokens
    }

    // MARK: - Language filter

    /// Which language tokens WhisperKit's per-window detection may choose from.
    enum LanguageFilter: Hashable {
        /// Fixed-language decoding: the filter is not consulted.
        case unused
        case all
        case restricted([String])

        init(_ language: ChunkLanguage) {
            switch language {
            case .fixed: self = .unused
            case .detect(nil): self = .all
            case .detect(let candidates?): self = .restricted(Array(Set(candidates)).sorted())
            }
        }
    }

    /// Installs a tokenizer whose language tokens match `filter`. Replacing a filter WhisperKit
    /// has already built reloads the models (seconds once Core ML has specialised them).
    private func install(_ filter: LanguageFilter) async throws {
        guard filter != .unused, filter != builtFilter else { return }
        guard let kit, let base = baseTokenizer else { throw TranscriptionError.modelUnavailable("not loaded") }
        let mustReload = builtFilter != nil
        if mustReload {
            await kit.unloadModels()
        }
        if case .restricted(let languages) = filter,
           let restricted = LanguageRestrictedTokenizer(base: base, languages: languages) {
            kit.tokenizer = restricted
        } else {
            kit.tokenizer = base
        }
        if mustReload {
            try await kit.loadModels()
        }
        builtFilter = filter
    }

    // MARK: - Conversion

    static func convert(_ results: [TranscriptionResult]) -> ChunkDecodeResult {
        var language = ""
        var segments: [TranscribedSegment] = []
        for result in results {
            language = result.language
            for segment in result.segments {
                segments.append(TranscribedSegment(
                    start: Double(segment.start),
                    end: Double(segment.end),
                    text: segment.text,
                    language: result.language,
                    words: (segment.words ?? []).map {
                        TranscribedWord(
                            text: $0.word,
                            start: Double($0.start),
                            end: Double($0.end),
                            probability: Double($0.probability)
                        )
                    },
                    avgLogProb: Double(segment.avgLogprob),
                    noSpeechProb: Double(segment.noSpeechProb),
                    compressionRatio: Double(segment.compressionRatio),
                    temperature: Double(segment.temperature)
                ))
            }
        }
        return ChunkDecodeResult(language: language, segments: segments)
    }

    /// Raw WhisperKit call for debugging decoder behaviour from TranscribeBench.
    package func rawTranscribe(samples: [Float], options: DecodingOptions) async throws -> [TranscriptionResult] {
        try await load()
        try await install(.all)
        guard let kit else { throw TranscriptionError.modelUnavailable("not loaded") }
        return try await kit.transcribe(audioArray: samples, decodeOptions: options)
    }

    // MARK: - Evaluation path

    /// One chunk of WhisperKit's own `.vad` chunking pipeline, times on the input's clock.
    public struct BuiltInChunk: Hashable, Sendable {
        public var start: Double
        public var language: String
        public var segments: [TranscribedSegment]
    }

    /// Runs WhisperKit's built-in VAD chunking (`chunkingStrategy: .vad`) over the whole input
    /// with no guards. TranscribeBench uses it to evaluate the raw language strategies.
    public func transcribeWithBuiltInChunking(
        samples: [Float],
        language: ChunkLanguage,
        prompt: String? = nil,
        wordTimestamps: Bool = true
    ) async throws -> [BuiltInChunk] {
        try await load()
        try await install(LanguageFilter(language))
        guard let kit else { throw TranscriptionError.modelUnavailable("not loaded") }
        var options = decodingOptions(
            for: ChunkDecodeRequest(samples: [], language: language, prompt: prompt, wordTimestamps: wordTimestamps),
            workers: preferredBatchSize
        )
        options.chunkingStrategy = .vad
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map { result in
            BuiltInChunk(
                start: Double(result.seekTime ?? 0),
                language: result.language,
                segments: Self.convert([result]).segments
            )
        }
    }
}
