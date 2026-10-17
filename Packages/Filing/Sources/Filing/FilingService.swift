import Capture
import Foundation
import Processing
import StudyCore

public enum FilingError: Error, Equatable, Sendable, LocalizedError {
    /// The filing (or what it points to) is gone.
    case missing
    /// Not a slide PDF, an audio/video file or a captured lecture.
    case unsupported(String)
    /// The file could not be read.
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .missing: String(localized: "It is gone.")
        case .unsupported(let name): String(localized: "“\(name)” is not slides or a recording.")
        case .unreadable(let name): String(localized: "“\(name)” can’t be read.")
        }
    }
}

/// Smart import (PRD #2): files dropped decks, recordings and captures to their course and
/// lecture on their own, writes one `filing` row per file with the evidence, and undoes or moves
/// a filing on request.
///
/// - `predict` reads a file while it is dragged and says where it would go (no writes).
/// - `file` imports through `DeckImporter`/`LectureImporter` and calls `afterImport` after each
///   filing (the app wakes the job processor there).
/// - `undo` removes exactly what a filing created; `change` moves the file and everything that
///   hangs off it to another lecture in one transaction.
public actor FilingService {
    public nonisolated let services: StudyServices
    let afterImport: @Sendable () async -> Void
    let cancelJobs: @Sendable (Recording.ID) async -> Void
    let now: @Sendable () -> Date
    private var evidenceCache: [URL: (stamp: FileStamp, evidence: FileEvidence)] = [:]

    /// - Parameters:
    ///   - afterImport: called after every filing that wrote something (wake the processor).
    ///   - cancelJobs: stops a recording's running job before Undo deletes the recording
    ///     (`LectureProcessor.cancel(recordingID:)`); queued jobs are removed here either way.
    public init(
        services: StudyServices,
        afterImport: @escaping @Sendable () async -> Void = {},
        cancelJobs: @escaping @Sendable (Recording.ID) async -> Void = { _ in },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.services = services
        self.afterImport = afterImport
        self.cancelJobs = cancelJobs
        self.now = now
    }

    var store: RecordStore { services.records }

    // MARK: - Prediction

    /// Where each file would go if dropped now. Unsupported or unreadable files are left out.
    public func predict(_ urls: [URL]) async -> [FilingPrediction] {
        var predictions: [FilingPrediction] = []
        guard let library = try? await loadLibrary() else { return [] }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let evidence = await evidence(for: url) else { continue }
            // A deck is small enough to recognise while dragging; audio is hashed on drop.
            if evidence.kind == .deck, let sha = try? BlobStore.sha256(of: url),
               let filing = try? await knownFiling(sha256: sha), let place = try? await place(of: filing) {
                predictions.append(FilingPrediction(
                    url: url, fileName: evidence.fileName, kind: evidence.kind, verdict: .file, places: [place],
                    isKnown: true, pageCount: evidence.pageCount, duration: evidence.duration
                ))
                continue
            }
            let decision = FilingMatcher(library: library).decide(evidence)
            predictions.append(FilingPrediction(
                url: url, fileName: evidence.fileName, kind: evidence.kind, verdict: decision.verdict,
                places: decision.places, pageCount: evidence.pageCount, duration: evidence.duration
            ))
        }
        return predictions
    }

    // MARK: - Filing

    /// Files each file (decks first, then captures, then recordings by start time) and returns
    /// one outcome per file. With `destination` the user's choice wins (a drop on a lecture or
    /// session, a picked course).
    public func file(_ urls: [URL], to destination: FilingDestination? = nil) async -> [FilingOutcome] {
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

        var items: [(url: URL, evidence: FileEvidence?)] = []
        for url in urls { items.append((url, await evidence(for: url))) }
        let order: [FilingKind: Int] = [.deck: 0, .capture: 1, .recording: 2]
        items.sort { lhs, rhs in
            let left = lhs.evidence.map { order[$0.kind] ?? 3 } ?? 4
            let right = rhs.evidence.map { order[$0.kind] ?? 3 } ?? 4
            if left != right { return left < right }
            let leftStart = lhs.evidence?.startedAt ?? .distantFuture
            let rightStart = rhs.evidence?.startedAt ?? .distantFuture
            if leftStart != rightStart { return leftStart < rightStart }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }

        var outcomes: [FilingOutcome] = []
        var contested: Set<Lecture.ID>?
        for item in items {
            guard let evidence = item.evidence else {
                let name = item.url.lastPathComponent
                let error: FilingError = FileEvidence.kind(of: item.url) == nil ? .unsupported(name) : .unreadable(name)
                outcomes.append(FilingOutcome(
                    url: item.url, fileName: name, kind: FileEvidence.kind(of: item.url),
                    status: .failed(error.localizedDescription)
                ))
                continue
            }
            if evidence.kind != .deck, destination == nil, contested == nil {
                // Decks are in; recordings dated only by day must not share one lecture.
                contested = (try? await contestedLectures(items.compactMap(\.evidence).filter { $0.kind != .deck })) ?? []
            }
            let outcome: FilingOutcome
            do {
                switch evidence.kind {
                case .deck: outcome = try await fileDeck(evidence, destination: destination)
                case .capture: outcome = try await fileCapture(evidence, destination: destination, contested: contested ?? [])
                default: outcome = try await fileRecording(evidence, destination: destination, contested: contested ?? [])
                }
            } catch {
                Log.importer.error("Filing \(evidence.fileName, privacy: .private) failed: \(String(describing: error), privacy: .public)")
                outcomes.append(FilingOutcome(
                    url: item.url, fileName: evidence.fileName, kind: evidence.kind, status: .failed(error.localizedDescription),
                    pageCount: evidence.pageCount, duration: evidence.duration
                ))
                continue
            }
            outcomes.append(outcome)
            if outcome.status != .known { await afterImport() }
        }
        return outcomes
    }

    // MARK: - Decks

    private func fileDeck(_ evidence: FileEvidence, destination: FilingDestination?) async throws -> FilingOutcome {
        let url = evidence.url
        let sha = try BlobStore.sha256(of: url)
        if let filing = try await knownFiling(sha256: sha) {
            return try await outcome(evidence, filing: filing, status: .known)
        }
        let existingDeck = try await services.database.read { db in
            try Deck.where { $0.blobSHA256.eq(sha) }.fetchOne(db)
        }
        if let existingDeck, let filing = try await describeLinkedDeck(existingDeck, evidence: evidence, sha256: sha) {
            return try await outcome(evidence, filing: filing, status: .known)
        }

        let decision = FilingMatcher(library: try await loadLibrary()).decide(evidence, destination: destination)
        let deck: Deck
        if let existingDeck {
            deck = existingDeck
        } else {
            deck = try await DeckImporter(services: services).importDeck(
                at: url, courseID: decision.best?.place.course.id, title: evidence.deckTitle
            ).0
        }
        let reused = existingDeck.map { _ in [FilingSignal(kind: .knownFile, evidence: evidence.fileName, weight: 1)] } ?? []
        let createdAt = now()

        guard let best = decision.best, decision.verdict != .needsCourse else {
            let filing = try await store.save(unfiled(evidence, sha256: sha, decision: decision, createdAt: createdAt, extra: reused, deckID: deck.id))
            return try await outcome(evidence, filing: filing, status: .needsCourse, decision: decision)
        }
        let filingID = UUID()
        let source: FilingSource = destination == nil ? .auto : .manual
        let make: @Sendable (AttachedDeck) -> Filing = { attached in
            Filing(
                id: filingID, kind: .deck, fileName: evidence.fileName, blobSHA256: sha,
                courseID: attached.lecture.courseID, lectureID: attached.lecture.id,
                lectureSessionID: attached.lecture.lectureSessionID, deckID: attached.deck.id, source: source,
                confidence: best.confidence,
                signals: best.signals + reused + (attached.movedDeck ? [.priorDeckCourse(attached.previousDeckCourseID)] : []),
                candidates: decision.alternatives.map(Self.candidate), createdLecture: attached.createdLecture,
                createdAt: createdAt
            )
        }
        let store = store
        let attached = try await LectureImporter(services: services).attachDeck(
            deck, to: best.target, courseID: best.place.course.id,
            title: best.place.title.isEmpty ? evidence.lectureTitle : best.place.title
        ) { db, attached in
            let filing = store.stamp(make(attached))
            try Filing.upsert { filing }.execute(db)
        }
        Log.importer.info("Filed deck \(evidence.fileName, privacy: .private) (\(best.confidence, privacy: .public))")
        return try await outcome(evidence, filing: make(attached), status: status(decision, destination: destination), decision: decision)
    }

    /// A deck imported before smart import existed (or before filings were kept) that already
    /// belongs to a lecture: a filing row that records where it is, creating nothing else.
    private func describeLinkedDeck(_ deck: Deck, evidence: FileEvidence, sha256: String) async throws -> Filing? {
        let deckID = deck.id
        let link: (LectureDeckSpan, Lecture)? = try await services.database.read { db in
            guard let span = try LectureDeckSpan
                .where({ $0.deckID.eq(deckID) && $0.startTime.is(nil) })
                .order(by: \.updatedAt)
                .fetchAll(db)
                .last,
                let lecture = try Lecture.find(span.lectureID).fetchOne(db)
            else { return nil }
            return (span, lecture)
        }
        guard let (_, lecture) = link else { return nil }
        return try await store.save(Filing(
            kind: .deck, fileName: evidence.fileName, blobSHA256: sha256, courseID: lecture.courseID,
            lectureID: lecture.id, lectureSessionID: lecture.lectureSessionID, deckID: deck.id, source: .auto, confidence: 1,
            signals: [FilingSignal(kind: .knownFile, evidence: deck.fileName, weight: 1)], createdAt: now()
        ))
    }

    // MARK: - Recordings

    private func fileRecording(_ evidence: FileEvidence, destination: FilingDestination?, contested: Set<Lecture.ID>) async throws -> FilingOutcome {
        let url = evidence.url
        let sha = try BlobStore.sha256(of: url)
        if let filing = try await knownFiling(sha256: sha) {
            return try await outcome(evidence, filing: filing, status: .known)
        }
        let existing: Recording? = try await services.database.read { db in
            try RecordingSegment.where { $0.blobSHA256.eq(sha) }.fetchOne(db)
                .flatMap { try Recording.find($0.recordingID).fetchOne(db) }
        }
        if let existing {
            let filing = try await describeRecording(existing, kind: .recording, evidence: evidence, sha256: sha)
            return try await outcome(evidence, filing: filing, status: filing.courseID == nil ? .needsCourse : .known)
        }

        let decision = FilingMatcher(library: try await loadLibrary()).decide(evidence, destination: destination, contested: contested)
        let importer = LectureImporter(services: services)
        let createdAt = now()
        guard let best = decision.best, decision.verdict != .needsCourse else {
            // Transcribed right away: once it is, what was said can file it (`fileBySpokenContent`).
            let recording = try await importer.storeRecording(audio: url, startedAt: evidence.startedAt, transcribe: true)
            let filing = try await store.save(unfiled(evidence, sha256: sha, decision: decision, createdAt: createdAt, recordingID: recording.id))
            return try await outcome(evidence, filing: filing, status: .needsCourse, decision: decision)
        }
        let filingID = UUID()
        let source: FilingSource = destination == nil ? .auto : .manual
        let make: @Sendable (ImportedLecture) -> Filing = { imported in
            Filing(
                id: filingID, kind: .recording, fileName: evidence.fileName, blobSHA256: sha,
                courseID: imported.lecture.courseID, lectureID: imported.lecture.id,
                lectureSessionID: imported.lecture.lectureSessionID, recordingID: imported.recording.id, source: source,
                confidence: best.confidence,
                signals: best.signals + (imported.redatedLecture ? [.priorHeldAt(imported.previousHeldAt)] : []),
                candidates: decision.alternatives.map(Self.candidate),
                createdLecture: imported.createdLecture, createdAt: createdAt
            )
        }
        let store = store
        let imported = try await importer.importRecording(
            audio: url, courseID: best.place.course.id, title: best.place.title, startedAt: evidence.startedAt, into: best.target
        ) { db, imported in
            let filing = store.stamp(make(imported))
            try Filing.upsert { filing }.execute(db)
        }
        Log.importer.info("Filed recording \(evidence.fileName, privacy: .private) (\(best.confidence, privacy: .public))")
        return try await outcome(evidence, filing: make(imported), status: status(decision, destination: destination), decision: decision)
    }

    /// A recording in the library without a filing row (imported before smart import): a row
    /// that records where it is, creating nothing else.
    private func describeRecording(_ recording: Recording, kind: FilingKind, evidence: FileEvidence, sha256: String) async throws -> Filing {
        var lecture: Lecture?
        if let id = recording.lectureID { lecture = try await store.fetch(Lecture.self, id: id) }
        return try await store.save(Filing(
            kind: kind, fileName: evidence.fileName, blobSHA256: sha256, courseID: lecture?.courseID ?? recording.courseID,
            lectureID: lecture?.id, lectureSessionID: lecture?.lectureSessionID, recordingID: recording.id, source: .auto,
            confidence: lecture == nil ? 0 : 1, signals: [FilingSignal(kind: .knownFile, evidence: evidence.fileName, weight: 1)],
            createdAt: now()
        ))
    }

    // MARK: - Captures

    private func fileCapture(_ evidence: FileEvidence, destination: FilingDestination?, contested: Set<Lecture.ID>) async throws -> FilingOutcome {
        guard let capture = evidence.capture else { throw FilingError.unreadable(evidence.fileName) }
        let recordingID = capture.recordingID
        if let filing = try await FilingRepository(store: store).latest(recordingID: recordingID) {
            // An un-filed capture still waits for its course.
            return try await outcome(evidence, filing: filing, status: filing.lectureID == nil ? .needsCourse : .known)
        }
        if let existing = try await store.fetch(Recording.self, id: recordingID) {
            let filing = try await describeRecording(existing, kind: .capture, evidence: evidence, sha256: "")
            return try await outcome(evidence, filing: filing, status: filing.courseID == nil ? .needsCourse : .known)
        }

        let decision = FilingMatcher(library: try await loadLibrary()).decide(evidence, destination: destination, contested: contested)
        let createdAt = now()
        guard let best = decision.best, decision.verdict != .needsCourse else {
            // Read and copied, never changed: the package stays as it is until it gets a course.
            let result = try await LecturePackageImporter(services: services).importPackage(
                LecturePackage(url: evidence.url), lectureID: nil, courseID: nil, removeAudioAfterImport: false, markImported: false
            )
            let filing = try await store.save(unfiled(evidence, sha256: "", decision: decision, createdAt: createdAt, recordingID: result.recording.id))
            return try await outcome(evidence, filing: filing, status: .needsCourse, decision: decision)
        }
        let imported = try await LectureImporter(services: services).importCapture(
            at: evidence.url, courseID: best.place.course.id, into: best.target
        )
        let filing = try await store.save(Filing(
            kind: .capture, fileName: evidence.fileName, blobSHA256: "", courseID: imported.lecture.courseID,
            lectureID: imported.lecture.id, lectureSessionID: imported.lecture.lectureSessionID,
            deckID: imported.deck?.id, recordingID: imported.recording.id,
            source: destination == nil ? .auto : .manual, confidence: best.confidence,
            signals: best.signals + (imported.redatedLecture ? [.priorHeldAt(imported.previousHeldAt)] : []),
            candidates: decision.alternatives.map(Self.candidate), createdLecture: imported.createdLecture, createdAt: createdAt
        ))
        Log.importer.info("Filed capture \(evidence.fileName, privacy: .private) (\(best.confidence, privacy: .public))")
        return try await outcome(evidence, filing: filing, status: status(decision, destination: destination), decision: decision)
    }

    /// Capture packages in `directory` (the library's Recordings folder) that never reached a
    /// filing: left behind by a crash mid-lecture, or by a filing that failed. Packages whose
    /// recording has a filing are in the library already (un-filed ones wait in a toast), and
    /// `excluding` (the package being recorded) is skipped. File them with `file(_:)`.
    public func unfiledCaptures(in directory: URL, excluding: Set<URL> = []) async -> [URL] {
        let excluded = Set(excluding.map(\.lastPathComponent))
        var urls: [URL] = []
        for package in (try? LecturePackageReader.pending(in: directory)) ?? [] where !excluded.contains(package.name) {
            guard let manifest = try? LecturePackageReader.read(package).manifest else { continue }
            let recordingID = manifest.id
            let filed = (try? await services.database.read { db in
                try Filing.where { $0.recordingID.eq(recordingID) }.fetchCount(db) > 0
            }) ?? true
            if !filed { urls.append(package.url) }
        }
        return urls
    }

    /// Gives decks stored under their file name ("02_Virtualization_Basics_…_v1", imported
    /// before decks took their title slide's) their title from the stored slide text, as smart
    /// import names new ones. Returns how many changed.
    @discardableResult
    public func repairDeckTitles() async -> Int {
        do {
            let decks = try await services.database.read { db in try Deck.all.fetchAll(db) }
            var repaired = 0
            for deck in decks where deck.title.isEmpty || deck.title == (deck.fileName as NSString).deletingPathExtension {
                let filing = Filing(kind: .deck, fileName: deck.fileName, deckID: deck.id)
                let title = try await storedEvidence(of: filing).deckTitle
                guard !title.isEmpty, title != deck.title else { continue }
                let id = deck.id
                let stamp = store.currentDate
                try await services.database.write { db in
                    try Deck.find(id).update { $0.title = title; $0.updatedAt = stamp }.execute(db)
                }
                repaired += 1
            }
            if repaired > 0 { Log.importer.info("Named \(repaired) deck(s) by their title slides") }
            return repaired
        } catch {
            Log.importer.error("Naming decks failed: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    // MARK: - Helpers

    struct FileStamp: Hashable, Sendable {
        var modified: Date?
        var size: Int?
    }

    /// Reads (or reuses) what a file says about itself.
    func evidence(for url: URL) async -> FileEvidence? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = FileStamp(modified: values?.contentModificationDate, size: values?.fileSize)
        if let cached = evidenceCache[url], cached.stamp == stamp { return cached.evidence }
        guard let evidence = await FileEvidence.read(url) else { return nil }
        evidenceCache[url] = (stamp, evidence)
        if evidenceCache.count > 64 { evidenceCache.removeValue(forKey: evidenceCache.keys.first ?? url) }
        return evidence
    }

    func loadLibrary() async throws -> FilingLibrary {
        let now = now()
        return try await services.database.read { db in try FilingLibrary.load(db, now: now) }
    }

    /// The filing of a file with these contents, if it was filed before.
    private func knownFiling(sha256: String) async throws -> Filing? {
        try await services.database.read { db in
            try Filing.where { $0.blobSHA256.eq(sha256) }.order { $0.createdAt.desc() }.fetchOne(db)
        }
    }

    /// Recordings in this drop that would each be filed to the same lecture by their day alone.
    private func contestedLectures(_ recordings: [FileEvidence]) async throws -> Set<Lecture.ID> {
        let matcher = FilingMatcher(library: try await loadLibrary())
        var claims: [Lecture.ID: Int] = [:]
        for evidence in recordings {
            guard let start = evidence.startedAt else { continue }
            for course in matcher.library.courses {
                let end = start.addingTimeInterval(max(0, evidence.duration ?? 0))
                guard matcher.bestSession(course.id, start: start, end: end) == nil,
                      let info = matcher.sameDayLecture(course.id, start: start, contested: [])
                else { continue }
                claims[info.lecture.id, default: 0] += 1
            }
        }
        return Set(claims.filter { $0.value > 1 }.keys)
    }

    private func unfiled(
        _ evidence: FileEvidence, sha256: String, decision: FilingDecision, createdAt: Date,
        extra: [FilingSignal] = [], deckID: Deck.ID? = nil, recordingID: Recording.ID? = nil
    ) -> Filing {
        Filing(
            kind: evidence.kind, fileName: evidence.fileName, blobSHA256: sha256, deckID: deckID, recordingID: recordingID,
            source: .auto, confidence: decision.alternatives.first?.courseScore ?? 0,
            signals: (decision.alternatives.first?.signals ?? []) + extra,
            candidates: decision.alternatives.map { FilingCandidate(courseID: $0.place.course.id, confidence: $0.courseScore) },
            createdAt: createdAt
        )
    }

    private func status(_ decision: FilingDecision, destination: FilingDestination?) -> FilingOutcome.Status {
        if destination != nil { return .filed }
        return decision.verdict == .file ? .filed : .review
    }

    static func candidate(_ choice: FilingChoice) -> FilingCandidate {
        FilingCandidate(
            courseID: choice.place.course.id, lectureID: choice.place.lectureID,
            lectureSessionID: choice.place.sessionID, confidence: choice.confidence
        )
    }

    private func outcome(
        _ evidence: FileEvidence, filing: Filing, status: FilingOutcome.Status, decision: FilingDecision? = nil
    ) async throws -> FilingOutcome {
        let place = try await place(of: filing)
        var alternatives: [FilingPlace] = []
        if let decision {
            switch status {
            case .needsCourse: alternatives = decision.alternatives.map(\.place)
            case .review: alternatives = decision.alternatives.prefix(2).map(\.place).filter { $0.destination != place?.destination }
            default: break
            }
        }
        return FilingOutcome(
            url: evidence.url, fileName: evidence.fileName, kind: evidence.kind, status: status, filing: filing,
            place: place, alternatives: alternatives, pageCount: evidence.pageCount, duration: evidence.duration
        )
    }
}
