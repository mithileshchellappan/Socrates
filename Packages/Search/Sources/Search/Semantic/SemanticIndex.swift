import Accelerate
import Foundation
import GRDB
import NaturalLanguage
import StudyCore
import Synchronization

/// On-device semantic search (M5, docs/plan-m5.md §5.1): Apple's `NLContextualEmbedding` (Latin
/// script: one multilingual model for German and English), token vectors mean-pooled and
/// L2-normalised, stored as little-endian Float16 in `search_vector`.
///
/// - **What**: `SemanticWindows` (transcript windows of one slide section up to about 60 words,
///   anchored at their first line; one window per slide, note and further-reading chunk; never
///   mail).
/// - **Reconcile** per unit after the indexer changed it (observes `search_chunk`, debounced
///   5 s): a vector whose `model` + `text_sha256` match within the unit is reused (its `chunk_id`
///   fixed after a re-cut), only new text is embedded, the rest is deleted. Serial, background
///   priority; paused while a processing job is queued or running (tried again a minute later).
///   Resumes from `search_vector` after a relaunch: unchanged text is never embedded twice.
/// - **Model**: assets requested when missing (no UI); loaded per batch and for queries, unloaded
///   after a batch and after 2 min without queries.
/// - **`nearest`**: the query and its alternatives embedded (cached for the last few texts),
///   cosine over an in-memory Float32 matrix (built on first use, dropped when vectors change;
///   about 2 KB per vector, so ≤ 30 MB for a semester), filtered by the query's scope, course and
///   lecture (a lecture's slides by its spans). Never waits for a download: empty until the model
///   and the index are there.
///
/// iOS: compiles; the app starts it on the Mac only (one instance, `start()` after the search
/// indexer, `stop()` at quit).
public actor SemanticIndex: SemanticSearching {
    private let database: any DatabaseWriter
    private let debounce: Duration
    /// How long the model stays loaded after the last query.
    static let idleUnload: Duration = .seconds(120)
    /// Characters of one window embedded (the model reads a few hundred tokens).
    static let maximumCharacters = 1_200
    /// A semantic neighbour must reach this cosine and lie within `scoreMargin` of the best one.
    static let minimumScore: Float = 0.55
    static let scoreMargin: Float = 0.12
    /// Query vectors kept (the query and its alternatives are embedded again on every search).
    static let queryCacheSize = 16

    private var embedding: NLContextualEmbedding?
    private var isLoaded = false
    private var requestedAssets = false

    private var observation: AnyDatabaseCancellable?
    private var loop: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var unloadTimer: Task<Void, Never>?
    private var isReconciling = false
    private var reconcileAgain = false
    private var stopped = false
    private var lastQuery: ContinuousClock.Instant?

    private var matrix: VectorMatrix?
    private var queryVectors: [String: [Float]] = [:]
    private var queryOrder: [String] = []

    public init(services: StudyServices) {
        self.init(database: services.database)
    }

    public init(database: any DatabaseWriter, debounce: Duration = .seconds(5)) {
        self.database = database
        self.debounce = debounce
    }

    // MARK: - Lifecycle

    /// Follows `search_chunk` (debounced 5 s) and reconciles once in the background. Returns at
    /// once.
    public func start() {
        guard observation == nil, !stopped else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let changes = Changes()
        observation = DatabaseRegionObservation(
            tracking: SQLRequest<Row>(sql: "SELECT id, kind, text, course_id, lecture_id, updated_at FROM search_chunk")
        ).start(
            in: database,
            onError: { error in
                Log.search.error("Semantic index observation failed: \(String(describing: error), privacy: .public)")
            },
            onChange: { _ in
                changes.bump()
                continuation.yield()
            }
        )
        let debounce = debounce
        loop = Task(priority: .background) { [weak self] in
            for await _ in stream {
                // A quiet stretch (at most three) so a reindex burst is reconciled once.
                var seen = changes.value
                for _ in 0..<3 {
                    do { try await Task.sleep(for: debounce) } catch { return }
                    let current = changes.value
                    if current == seen { break }
                    seen = current
                }
                await self?.reconcile()
            }
        }
        continuation.yield()
    }

    /// Stops following and ends a running batch after its current unit; unloads the model.
    public func stop() {
        stopped = true
        observation?.cancel()
        observation = nil
        loop?.cancel()
        loop = nil
        retry?.cancel()
        retry = nil
        unloadTimer?.cancel()
        unloadTimer = nil
        unload()
        matrix = nil
    }

    /// Loads the model ahead of the first query (Search on screen); it unloads again after 2 min
    /// without queries. Nothing when the assets are missing.
    public func warm() {
        guard !stopped, hasAssets(), loadModel() else { return }
        lastQuery = .now
        scheduleUnload()
    }

    // MARK: - Reconcile

    /// Brings `search_vector` in step with `search_chunk` (stale units in turn, newest first),
    /// unless a processing job is queued or running. A call during a batch runs one more batch
    /// after it.
    public func reconcile() async {
        guard !stopped else { return }
        guard !isReconciling else {
            reconcileAgain = true
            return
        }
        isReconciling = true
        defer { isReconciling = false }
        repeat {
            reconcileAgain = false
            await reconcileOnce()
        } while reconcileAgain && !stopped && !Task.isCancelled
        unloadAfterBatch()
    }

    private func reconcileOnce() async {
        let started = ContinuousClock.now
        var ready = hasAssets()
        if !ready { ready = await requestAssets() && hasAssets() }
        guard ready, let model = modelName else { return }
        do {
            let (stale, orphans) = try await database.read { db in try SemanticWindows.work(db, model: model) }
            var changed = false
            if !orphans.isEmpty {
                try await database.write { db in
                    for unit in orphans {
                        try db.execute(sql: "DELETE FROM search_vector WHERE kind = ? AND unit_id = ?", arguments: [unit.kind.rawValue, unit.id])
                    }
                }
                changed = true
            }
            var embedded = 0
            var units = 0
            for unit in stale {
                if stopped || Task.isCancelled { break }
                if try await processingBusy() {
                    scheduleRetry()
                    break
                }
                guard let count = try await reconcile(unit, model: model) else { break }
                embedded += count
                units += 1
                changed = true
                await Task.yield()
            }
            if changed { matrix = nil }
            if units > 0 || !orphans.isEmpty {
                let elapsed = ContinuousClock.now - started
                Log.search.info("""
                    Semantic index: \(units) units, \(embedded) windows embedded, \(orphans.count) orphaned units removed \
                    in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public)
                    """)
            }
        } catch {
            Log.search.error("Semantic indexing failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// One unit: reuse vectors by text hash, embed the rest, delete what is left. Written only if
    /// the unit's windows are still the ones embedded (else the next change event tries again).
    /// Returns how many windows were embedded; nil when the model did not load (the batch ends).
    private func reconcile(_ unit: SemanticWindows.Unit, model: String) async throws -> Int? {
        let (windows, existing) = try await database.read { db in
            let windows = try SemanticWindows.windows(of: unit, in: db)
            var existing: [String: [Int64]] = [:]
            let rows = try Row.fetchCursor(db, sql: """
                SELECT id, text_sha256 FROM search_vector WHERE kind = ? AND unit_id = ? AND model = ?
                """, arguments: [unit.kind.rawValue, unit.id, model])
            while let row = try rows.next() { existing[row["text_sha256"], default: []].append(row["id"]) }
            return (windows, existing)
        }
        // The model loads only when there is new text to embed.
        if windows.contains(where: { existing[$0.sha256] == nil }), !loadModel() { return nil }
        var available = existing
        var reused: [(Int64, SemanticWindows.Window)] = []
        var fresh: [(SemanticWindows.Window, Data)] = []
        for window in windows {
            if var ids = available[window.sha256], let id = ids.popLast() {
                available[window.sha256] = ids
                reused.append((id, window))
                continue
            }
            guard let vector = embed(window.text, language: window.language) else { continue }
            fresh.append((window, Self.half(vector)))
            if fresh.count % 8 == 0 { await Task.yield() }
            if stopped || Task.isCancelled { return 0 }
        }
        let dimensions = embedding?.dimension ?? 0
        let signature = windows.map { "\($0.chunkID):\($0.sha256)" }
        let now = Date()
        let leftover = available.values.flatMap { $0 }
        let keep = reused
        let add = fresh
        let written = try await database.write { db -> Bool in
            // The indexer may have re-cut the unit while it was embedded.
            guard try SemanticWindows.windows(of: unit, in: db).map({ "\($0.chunkID):\($0.sha256)" }) == signature else { return false }
            for (id, window) in keep {
                try db.execute(sql: """
                    UPDATE search_vector SET chunk_id = ?, course_id = ?, lecture_id = ?, updated_at = ? WHERE id = ?
                    """, arguments: [window.chunkID, window.courseID, window.lectureID, now, id])
            }
            let insert = try db.cachedStatement(sql: """
                INSERT INTO search_vector (chunk_id, kind, unit_id, course_id, lecture_id, text_sha256, model, dimensions, vector, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for (window, vector) in add {
                try insert.execute(arguments: [
                    window.chunkID, unit.kind.rawValue, unit.id, window.courseID, window.lectureID, window.sha256, model,
                    dimensions, vector, now,
                ])
            }
            if !leftover.isEmpty {
                try db.execute(
                    sql: "DELETE FROM search_vector WHERE id IN (SELECT value FROM json_each(?))",
                    arguments: [Retrieval.json(leftover)])
            }
            // Vectors of another model in this unit are replaced by the ones above.
            try db.execute(
                sql: "DELETE FROM search_vector WHERE kind = ? AND unit_id = ? AND model <> ?",
                arguments: [unit.kind.rawValue, unit.id, model])
            return true
        }
        return written ? fresh.count : 0
    }

    private func processingBusy() async throws -> Bool {
        try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM job WHERE state IN ('queued', 'running')") ?? 0 > 0
        }
    }

    private func scheduleRetry() {
        guard retry == nil else { return }
        retry = Task(priority: .background) { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            await self?.retryEnded()
        }
    }

    private func retryEnded() async {
        retry = nil
        await reconcile()
    }

    // MARK: - Queries

    public func nearest(to texts: [String], query: SearchQuery, limit: Int) async throws -> [SemanticMatch] {
        guard limit > 0, !stopped, hasAssets(), loadModel() else { return [] }
        lastQuery = .now
        scheduleUnload()
        let matrix = try await currentMatrix()
        guard matrix.rows > 0 else { return [] }
        var vectors: [[Float]] = []
        for text in texts.prefix(4) {
            if let vector = queryVector(text), vector.count == matrix.dimensions { vectors.append(vector) }
        }
        guard !vectors.isEmpty else { return [] }
        var allowedSlides: Set<Int64>?
        if let lectureID = query.lectureID { allowedSlides = try await slideChunks(of: lectureID) }
        let scores = matrix.bestScores(for: vectors)
        let kinds = Set(query.scope.kinds.map(\.rawValue))
        let course = query.courseID?.storageText
        let lecture = query.lectureID?.storageText
        var candidates: [(Int, Float)] = []
        for row in 0..<matrix.rows where kinds.contains(matrix.kinds[row]) {
            if let course, matrix.courseIDs[row] != course { continue }
            if let lecture, matrix.lectureIDs[row] != lecture, allowedSlides?.contains(matrix.chunkIDs[row]) != true { continue }
            candidates.append((row, scores[row]))
        }
        guard let best = candidates.map(\.1).max() else { return [] }
        let floor = max(Self.minimumScore, best - Self.scoreMargin)
        return candidates
            .filter { $0.1 >= floor }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { SemanticMatch(chunkID: matrix.chunkIDs[$0.0], score: Double($0.1)) }
    }

    /// The vector of a query text, from the cache or embedded now.
    private func queryVector(_ text: String) -> [Float]? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if let vector = queryVectors[key] { return vector }
        guard let vector = embed(text, language: nil) else { return nil }
        queryVectors[key] = vector
        queryOrder.append(key)
        if queryOrder.count > Self.queryCacheSize { queryVectors[queryOrder.removeFirst()] = nil }
        return vector
    }

    /// Slide chunks a lecture showed (pages inside its deck spans): a lecture filter keeps them,
    /// though slide chunks belong to a deck, not a lecture.
    private func slideChunks(of lectureID: Lecture.ID) async throws -> Set<Int64> {
        try await database.read { db in
            Set(try Int64.fetchAll(db, sql: """
                SELECT c.id FROM search_chunk c JOIN lecture_deck_span s ON s.deck_id = c.deck_id
                WHERE c.kind = 'slide' AND s.lecture_id = ? AND s.first_page IS NOT NULL
                  AND c.page_number BETWEEN s.first_page AND coalesce(s.last_page, s.first_page)
                """, arguments: [lectureID.storageText]))
        }
    }

    private func currentMatrix() async throws -> VectorMatrix {
        if let matrix { return matrix }
        guard let model = modelName, let dimensions = embedding?.dimension, dimensions > 0 else { return VectorMatrix(dimensions: 0) }
        let built = try await database.read { db in try VectorMatrix.load(db, model: model, dimensions: dimensions) }
        if built.byteCount > 30 << 20 {
            Log.search.notice("Semantic matrix is \(built.byteCount >> 20) MB (\(built.rows) vectors)")
        }
        matrix = built
        return built
    }

    // MARK: - Model

    /// The model's name in `search_vector.model`: "nl-contextual-latn-<revision>".
    private var modelName: String? {
        embedding.map { "nl-contextual-latn-\($0.revision)" }
    }

    /// The embedding exists and its assets are on the device (requested by a batch when not,
    /// never waited for by a query).
    private func hasAssets() -> Bool {
        if embedding == nil { embedding = NLContextualEmbedding(script: .latin) }
        guard let embedding else { return false }
        return embedding.hasAvailableAssets
    }

    /// Asks NaturalLanguage for the model's assets once per launch (no UI); true when they are
    /// there afterwards.
    private func requestAssets() async -> Bool {
        guard !requestedAssets, let embedding else { return false }
        requestedAssets = true
        let result: NLContextualEmbedding.AssetsResult = await withCheckedContinuation { continuation in
            embedding.requestAssets { result, error in
                if let error {
                    Log.search.notice("Embedding assets unavailable: \(String(describing: error), privacy: .public)")
                }
                continuation.resume(returning: result)
            }
        }
        return result == .available
    }

    private func loadModel() -> Bool {
        if isLoaded { return true }
        guard let embedding, embedding.hasAvailableAssets else { return false }
        do {
            try embedding.load()
            isLoaded = true
            return true
        } catch {
            Log.search.error("Embedding model did not load: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func unload() {
        guard isLoaded else { return }
        embedding?.unload()
        isLoaded = false
        queryVectors = [:]
        queryOrder = []
    }

    /// After a batch: unloaded unless a query came in the last 2 min (then when that expires).
    private func unloadAfterBatch() {
        if let lastQuery, ContinuousClock.now - lastQuery < Self.idleUnload {
            scheduleUnload()
        } else {
            unload()
        }
    }

    private func scheduleUnload() {
        unloadTimer?.cancel()
        unloadTimer = Task(priority: .background) { [weak self] in
            do { try await Task.sleep(for: Self.idleUnload) } catch { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        unloadTimer = nil
        guard !isReconciling else { return }
        if let lastQuery, ContinuousClock.now - lastQuery < Self.idleUnload {
            scheduleUnload()
            return
        }
        unload()
    }

    /// Mean of the token vectors, L2-normalised; nil when the model gives nothing.
    private func embed(_ text: String, language: String?) -> [Float]? {
        guard let embedding, isLoaded else { return nil }
        let clipped = text.count > Self.maximumCharacters ? String(text.prefix(Self.maximumCharacters)) : text
        guard !clipped.isEmpty else { return nil }
        let result: NLContextualEmbeddingResult
        do {
            result = try embedding.embeddingResult(for: clipped, language: language.map { NLLanguage(rawValue: $0) })
        } catch {
            Log.search.notice("Embedding failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        let dimensions = embedding.dimension
        var sum = [Double](repeating: 0, count: dimensions)
        var tokens = 0
        result.enumerateTokenVectors(in: clipped.startIndex..<clipped.endIndex) { vector, _ in
            guard vector.count == dimensions else { return true }
            for index in 0..<dimensions { sum[index] += vector[index] }
            tokens += 1
            return true
        }
        guard tokens > 0 else { return nil }
        // The mean's direction is the sum's: normalising the sum is enough.
        let length = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0 else { return nil }
        return sum.map { Float($0 / length) }
    }

    // MARK: - Float16

    /// Little-endian IEEE half floats (vImage: works on every architecture, unlike `Float16`).
    static func half(_ values: [Float]) -> Data {
        var source = values
        var output = [UInt16](repeating: 0, count: values.count)
        source.withUnsafeMutableBufferPointer { input in
            output.withUnsafeMutableBufferPointer { half in
                var from = vImage_Buffer(
                    data: input.baseAddress, height: 1, width: vImagePixelCount(values.count), rowBytes: values.count * 4)
                var to = vImage_Buffer(
                    data: half.baseAddress, height: 1, width: vImagePixelCount(values.count), rowBytes: values.count * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&from, &to, vImage_Flags(kvImageNoFlags))
            }
        }
        return output.withUnsafeBytes { Data($0) }
    }
}

/// Every vector of the current model in one Float32 matrix (rows × dimensions), with what the
/// filters need per row.
struct VectorMatrix: Sendable {
    var dimensions: Int
    var values: [Float] = []
    var chunkIDs: [Int64] = []
    var kinds: [String] = []
    var courseIDs: [String?] = []
    var lectureIDs: [String?] = []

    var rows: Int { chunkIDs.count }
    var byteCount: Int { values.count * MemoryLayout<Float>.size }

    static func load(_ db: Database, model: String, dimensions: Int) throws -> VectorMatrix {
        var matrix = VectorMatrix(dimensions: dimensions)
        let count = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM search_vector WHERE model = ? AND dimensions = ? AND chunk_id IS NOT NULL
            """, arguments: [model, dimensions]) ?? 0
        matrix.values.reserveCapacity(count * dimensions)
        let rows = try Row.fetchCursor(db, sql: """
            SELECT chunk_id, kind, course_id, lecture_id, vector FROM search_vector
            WHERE model = ? AND dimensions = ? AND chunk_id IS NOT NULL
            """, arguments: [model, dimensions])
        var row = [Float](repeating: 0, count: dimensions)
        while let record = try rows.next() {
            let data: Data = record["vector"]
            guard data.count == dimensions * 2 else { continue }
            data.withUnsafeBytes { bytes in
                row.withUnsafeMutableBufferPointer { output in
                    var from = vImage_Buffer(
                        data: UnsafeMutableRawPointer(mutating: bytes.baseAddress), height: 1,
                        width: vImagePixelCount(dimensions), rowBytes: dimensions * 2)
                    var to = vImage_Buffer(
                        data: output.baseAddress, height: 1, width: vImagePixelCount(dimensions), rowBytes: dimensions * 4)
                    _ = vImageConvert_Planar16FtoPlanarF(&from, &to, vImage_Flags(kvImageNoFlags))
                }
            }
            matrix.values.append(contentsOf: row)
            matrix.chunkIDs.append(record["chunk_id"])
            matrix.kinds.append(record["kind"])
            matrix.courseIDs.append(record["course_id"])
            matrix.lectureIDs.append(record["lecture_id"])
        }
        return matrix
    }

    /// Per row, the best cosine against any of `queries` (all L2-normalised).
    func bestScores(for queries: [[Float]]) -> [Float] {
        var best = [Float](repeating: -1, count: rows)
        var scores = [Float](repeating: 0, count: rows)
        guard rows > 0 else { return best }
        for query in queries where query.count == dimensions {
            values.withUnsafeBufferPointer { matrix in
                query.withUnsafeBufferPointer { vector in
                    scores.withUnsafeMutableBufferPointer { output in
                        guard let matrix = matrix.baseAddress, let vector = vector.baseAddress,
                              let output = output.baseAddress else { return }
                        // (rows × d) · (d × 1)
                        vDSP_mmul(matrix, 1, vector, 1, output, 1, vDSP_Length(rows), 1, vDSP_Length(dimensions))
                    }
                }
            }
            for row in 0..<rows where scores[row] > best[row] { best[row] = scores[row] }
        }
        return best
    }
}

/// Counts database changes for the debounce (bumped on GRDB's queue, read by the index).
private final class Changes: Sendable {
    private let count = Mutex<UInt64>(0)

    func bump() { count.withLock { $0 &+= 1 } }
    var value: UInt64 { count.withLock { $0 } }
}
