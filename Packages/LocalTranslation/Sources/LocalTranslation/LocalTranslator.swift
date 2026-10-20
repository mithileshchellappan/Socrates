import Foundation

/// What a translation reports while it runs.
public enum TranslationEvent: Sendable {
    /// The route's missing models are downloading: 0…1, never going backwards.
    case downloading(fraction: Double)
    /// `texts[index]` translated in full. Texts arrive in index order.
    case translated(index: Int, text: String)
}

/// The on-device translator: local-translate's engine (`runJobInner`) in Swift, on the same
/// OPUS-MT models. Every ONNX Runtime call runs on this actor, off the main actor.
///
/// One route is resident at a time (a job keeps its own references, so a model another job
/// still uses is freed when that job ends); it unloads 120 s after the last job. Units already
/// translated on a route come back from an in-memory cache (signatures, footers, re-runs).
public actor LocalTranslator {
    public static let shared = LocalTranslator(store: .shared)

    /// Tokens per translated unit: Marian degrades well before its 512 positions.
    static let maxUnitTokens = 120
    /// Units per batch after the first (1, then 2, then 4…).
    static let maxBatch = 4
    /// ONNX Runtime intra-op threads per session.
    static let threads = 4
    static let cacheLimit = 4_096

    private typealias Continuation = AsyncThrowingStream<TranslationEvent, any Error>.Continuation

    private final class LoadedRoute {
        let id: String
        let models: [MarianModel]

        init(id: String, models: [MarianModel]) {
            self.id = id
            self.models = models
        }
    }

    private struct DownloadState {
        var id: UUID
        var task: Task<Void, Never>
        var done: Int64 = 0
        var total: Int64 = 0
        var isFinished = false
        var failure: (any Error)?
    }

    private struct UnitReference {
        var text: Int
        var unit: Int
    }

    private let store: TranslationModelStore
    private let idleUnload: Duration
    private var resident: LoadedRoute?
    private var activeJobs = 0
    private var idleTask: Task<Void, Never>?
    private var idleGeneration = 0
    private var cache: [String: String] = [:]
    private var downloads: [String: DownloadState] = [:]

    public init(store: TranslationModelStore, idleUnload: Duration = .seconds(120)) {
        self.store = store
        self.idleUnload = idleUnload
    }

    /// Whether a model route exists from `source` to `target` (language codes such as "de",
    /// "en", "zh-Hant"). Needs no download and no model.
    public nonisolated static func canTranslate(from source: String, to target: String) -> Bool {
        TranslationRoutes.plan(from: source, to: target) != nil
    }

    /// Translates `texts` from `source` to `target`, downloading the route's models the first
    /// time. Cancelling the consumer (or dropping the stream) stops decoding at the next step.
    public nonisolated func translations(
        of texts: [String], from source: String, to target: String
    ) -> AsyncThrowingStream<TranslationEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranslationEvent.self, throwing: (any Error).self)
        let task = Task(priority: .userInitiated) {
            do {
                try await self.run(texts, from: source, to: target, continuation: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Frees the resident models now (a running job keeps the ones it uses until it ends).
    public func unload() {
        resident = nil
    }

    // MARK: The job

    private func run(_ texts: [String], from source: String, to target: String, continuation: Continuation) async throws {
        let from = TranslationRoutes.normalize(source)
        let to = TranslationRoutes.normalize(target)
        guard let route = TranslationRoutes.plan(from: from, to: to) else { throw TranslationError.unsupportedPair }
        if route.steps.isEmpty {
            for (index, text) in texts.enumerated() {
                continuation.yield(.translated(index: index, text: text))
            }
            return
        }
        beginJob()
        defer { endJob() }

        // Models first: download what is missing, then load (or reuse) the route.
        var missing: [String] = []
        for step in route.steps where !missing.contains(step.repository) && !store.isReady(step.repository) {
            missing.append(step.repository)
        }
        if !missing.isEmpty {
            try await waitForDownloads(missing, continuation: continuation)
        }
        try Task.checkCancellation()
        let loaded = try load(route)
        guard let first = loaded.models.first, loaded.models.count == route.steps.count else {
            throw TranslationError.unsupportedPair
        }

        // One sentence per unit, counted with the first model's tokenizer.
        let chunker = TextChunker(language: from == "auto" ? nil : from)
        let joiner = TranslationRoutes.spaceless.contains(to) ? "" : " "
        var units: [[TextUnit]] = []
        for text in texts {
            let textUnits = chunker.units(of: text, maxTokens: Self.maxUnitTokens, joiner: joiner) { first.countTokens($0) }
            units.append(textUnits)
        }

        // Skipped and cached units are done; the rest queue in order.
        let routeID = route.id
        var results: [[String?]] = []
        var queue: [UnitReference] = []
        for (textIndex, textUnits) in units.enumerated() {
            var row = [String?](repeating: nil, count: textUnits.count)
            for (unitIndex, unit) in textUnits.enumerated() {
                if unit.skip {
                    row[unitIndex] = unit.text
                } else if let known = cache[Self.cacheKey(routeID, unit.text)] {
                    row[unitIndex] = known
                } else {
                    queue.append(UnitReference(text: textIndex, unit: unitIndex))
                }
            }
            results.append(row)
        }
        var emitted = 0
        emitReady(texts: texts, units: units, results: results, next: &emitted, continuation: continuation)

        // Batches of 1, 2, 4, 4… units across texts (the first text appears fast), each through
        // every step of the route.
        var size = 1
        var position = 0
        while position < queue.count {
            try Task.checkCancellation()
            var batch: [UnitReference] = []
            var sources: [String] = []
            while position < queue.count, batch.count < size {
                let reference = queue[position]
                position += 1
                let text = units[reference.text][reference.unit].text
                if let known = cache[Self.cacheKey(routeID, text)] {
                    results[reference.text][reference.unit] = known
                    continue
                }
                batch.append(reference)
                sources.append(text)
            }
            if !batch.isEmpty {
                var outputs = sources
                for (index, step) in route.steps.enumerated() {
                    outputs = try loaded.models[index].translate(outputs, targetToken: step.targetToken)
                }
                for (offset, reference) in batch.enumerated() {
                    let translated = outputs[offset]
                    results[reference.text][reference.unit] = translated
                    remember(translated, for: sources[offset], on: routeID)
                }
                size = min(Self.maxBatch, size * 2)
            }
            emitReady(texts: texts, units: units, results: results, next: &emitted, continuation: continuation)
            await Task.yield()
        }
        emitReady(texts: texts, units: units, results: results, next: &emitted, continuation: continuation)
    }

    /// Yields every text, in order, whose units are all done.
    private func emitReady(
        texts: [String], units: [[TextUnit]], results: [[String?]], next: inout Int, continuation: Continuation
    ) {
        while next < texts.count {
            let row = results[next]
            if row.contains(where: { $0 == nil }) { return }
            let textUnits = units[next]
            var text = ""
            if textUnits.isEmpty {
                text = texts[next]
            } else {
                for (index, unit) in textUnits.enumerated() {
                    text.append(row[index] ?? unit.text)
                    text.append(unit.sep)
                }
            }
            continuation.yield(.translated(index: next, text: text))
            next += 1
        }
    }

    // MARK: Models

    /// The route's models: the resident ones, or loaded after dropping the old route. A model
    /// ONNX Runtime cannot open is invalidated, so the next download checks it again.
    private func load(_ route: TranslationRoute) throws -> LoadedRoute {
        if let resident, resident.id == route.id { return resident }
        resident = nil
        var models: [MarianModel] = []
        for step in route.steps {
            let folder = store.folder(for: step.repository)
            do {
                let model = try MarianModel(folder: folder, repository: step.repository, threads: Self.threads)
                models.append(model)
            } catch {
                store.invalidate(step.repository)
                TranslationLog.logger.error("Could not load \(step.repository, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw TranslationError.modelUnreadable("\(step.repository): \(error.localizedDescription)")
            }
        }
        let loaded = LoadedRoute(id: route.id, models: models)
        resident = loaded
        return loaded
    }

    private func beginJob() {
        activeJobs += 1
        idleTask?.cancel()
        idleTask = nil
        idleGeneration += 1
    }

    private func endJob() {
        activeJobs -= 1
        guard activeJobs == 0 else { return }
        idleGeneration += 1
        let generation = idleGeneration
        let delay = idleUnload
        idleTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.unloadIfIdle(generation)
        }
    }

    private func unloadIfIdle(_ generation: Int) {
        guard activeJobs == 0, generation == idleGeneration, resident != nil else { return }
        resident = nil
        idleTask = nil
        TranslationLog.logger.info("Unloaded the translation models after idling")
    }

    // MARK: Cache

    private static func cacheKey(_ routeID: String, _ text: String) -> String {
        "\(routeID)\u{1}\(text)"
    }

    private func remember(_ translation: String, for text: String, on routeID: String) {
        if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[Self.cacheKey(routeID, text)] = translation
    }

    // MARK: Downloads

    /// Starts (or joins) each repo's download and reports their progress, polled 10 times a
    /// second, until all are done. A cancelled job stops waiting; the download goes on.
    private func waitForDownloads(_ repositories: [String], continuation: Continuation) async throws {
        for repository in repositories { startDownload(repository) }
        var reported: Double = -1
        while true {
            var pending = false
            var sum: Double = 0
            for repository in repositories {
                guard let state = downloads[repository] else { continue }
                if let failure = state.failure { throw failure }
                if state.isFinished {
                    sum += 1
                    continue
                }
                pending = true
                if state.total > 0 {
                    let part: Double = Double(state.done) / Double(state.total)
                    sum += min(1, part)
                }
            }
            let count: Double = Double(max(1, repositories.count))
            let fraction: Double = sum / count
            if fraction > reported {
                reported = fraction
                continuation.yield(.downloading(fraction: fraction))
            }
            if !pending { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// One download per repo: a request for a repo already downloading joins it.
    private func startDownload(_ repository: String) {
        if let state = downloads[repository], !state.isFinished { return }
        let id = UUID()
        let store = store
        let task = Task.detached(priority: .userInitiated) {
            do {
                try await store.download(repository) { done, total in
                    Task { await self.noteProgress(repository, id: id, done: done, total: total) }
                }
                await self.finishDownload(repository, id: id, failure: nil)
            } catch {
                await self.finishDownload(repository, id: id, failure: error)
            }
        }
        downloads[repository] = DownloadState(id: id, task: task)
    }

    private func noteProgress(_ repository: String, id: UUID, done: Int64, total: Int64) {
        guard var state = downloads[repository], state.id == id, !state.isFinished else { return }
        state.total = total
        state.done = max(state.done, done)
        downloads[repository] = state
    }

    private func finishDownload(_ repository: String, id: UUID, failure: (any Error)?) {
        guard var state = downloads[repository], state.id == id else { return }
        state.isFinished = true
        state.failure = failure
        if failure == nil { state.done = state.total }
        downloads[repository] = state
    }
}
