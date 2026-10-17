import AVFAudio
import Capture
import Foundation
import StudyCore

public enum LectureImportError: Error, Equatable, Sendable, LocalizedError {
    /// The course does not exist (a lecture always belongs to a course).
    case courseMissing
    /// The file is not audio this device can decode.
    case unreadableAudio(String)
    /// The package was imported before and its audio is gone, but no recording row exists.
    case packageAlreadyImported(String)

    public var errorDescription: String? {
        switch self {
        case .courseMissing: String(localized: "Choose a course.")
        case .unreadableAudio(let name): String(localized: "“\(name)” can’t be read as audio.")
        case .packageAlreadyImported(let name): String(localized: "“\(name)” was imported before.")
        }
    }
}

/// What an import created (or found, when the same recording was imported before).
public struct ImportedLecture: Sendable, Hashable {
    public var lecture: Lecture
    public var recording: Recording
    public var deck: Deck?
    /// The transcription job; nil when the recording was imported before and already has one.
    public var job: Job?
    public var wasAlreadyImported: Bool
}

/// Brings a lecture into the library and queues its processing.
///
/// Two ways in, one result (`Lecture` + `Recording` + segments + optional `Deck`, a coarse
/// `lecture_deck_span` tying the deck to the lecture, and a queued transcription `Job`):
/// - `importCapture(at:)`: a `<uuid>.lecture` package from live capture (stamps included);
/// - `importRecording(audio:deck:courseID:)`: any audio file the system can decode (Voice
///   Memos `.qta`/`.m4a`, `.wav`, `.caf`, …) plus an optional slide PDF.
///
/// The jobs run in `LectureProcessor`.
public struct LectureImporter: Sendable {
    public let services: StudyServices
    private let now: @Sendable () -> Date

    public init(services: StudyServices, now: @escaping @Sendable () -> Date = { Date() }) {
        self.services = services
        self.now = now
    }

    private var store: RecordStore { services.records }

    // MARK: - Captured packages

    /// Imports a lecture package written by live capture.
    ///
    /// `courseID` and `deckURL` fill in what the manifest lacks; the manifest's lecture id is kept
    /// so notes taken live stay attached. A package imported before (its audio already moved into
    /// the library) resolves to its existing recording.
    ///
    /// Only packages inside the library's Recordings folder (written by live capture here) lose
    /// their audio and are marked imported. A package picked anywhere else (a backup, a USB
    /// drive, an AirDropped iPhone recording) is read and copied but never changed; importing it
    /// again finds the recording by its id.
    @concurrent
    public func importCapture(
        at url: URL,
        courseID: Course.ID? = nil,
        deckURL: URL? = nil,
        title: String? = nil
    ) async throws -> ImportedLecture {
        let package = LecturePackage(url: url)
        let contents = try LecturePackageReader.read(package)
        let manifest = contents.manifest
        guard let course = try await fetchCourse(courseID ?? manifest.courseID) else {
            throw LectureImportError.courseMissing
        }

        var deck = try await existingDeck(id: manifest.deck?.deckID, sha256: manifest.deck?.sha256)
        if deck == nil, let deckURL {
            deck = try await DeckImporter(services: services).importDeck(at: deckURL, courseID: course.id).0
        }

        let ownsPackage = Self.isInside(url, directory: services.paths.recordings)
        // A package from elsewhere is never marked imported, so its recording row says it was.
        let existingRecording = try await store.fetch(Recording.self, id: manifest.id)
        let alreadyImported = manifest.importedAt != nil || (!ownsPackage && existingRecording != nil)
        var filedLecture: Lecture?
        if alreadyImported, let lectureID = existingRecording?.lectureID {
            filedLecture = try await store.fetch(Lecture.self, id: lectureID)
        }
        let lecture: Lecture
        if let filedLecture {
            lecture = filedLecture
        } else {
            lecture = try await ensureLecture(
                id: manifest.lectureID,
                course: course,
                title: title ?? deck?.title ?? "",
                heldAt: manifest.startedAt
            )
        }

        if alreadyImported {
            guard var recording = existingRecording else {
                throw LectureImportError.packageAlreadyImported(package.name)
            }
            if recording.lectureID == nil || recording.courseID == nil {
                recording.lectureID = recording.lectureID ?? lecture.id
                recording.courseID = recording.courseID ?? course.id
                recording = try await store.save(recording)
            }
            let recordingID = recording.id
            let jobCount = try await services.database.read { db in
                try Job.where { $0.recordingID.eq(recordingID) }.fetchCount(db)
            }
            return ImportedLecture(
                lecture: lecture, recording: recording, deck: deck,
                job: jobCount == 0 ? try await enqueueTranscription(lecture: lecture, recording: recording) : nil,
                wasAlreadyImported: true
            )
        }

        let result = try await LecturePackageImporter(services: services).importPackage(
            package, lectureID: lecture.id, courseID: course.id, deckID: deck?.id,
            removeAudioAfterImport: ownsPackage, markImported: ownsPackage
        )

        if let deck {
            let shown = result.slideEvents.filter { $0.kind == .show }.compactMap(\.pageNumber)
            try await linkDeck(
                deck, to: lecture,
                pages: shown.isEmpty ? nil : (shown.min() ?? 1)...(shown.max() ?? deck.pageCount),
                source: shown.isEmpty ? .manual : .stamp
            )
        }
        let job = try await enqueueTranscription(lecture: lecture, recording: result.recording)
        Log.importer.info(
            "Imported capture \(package.name, privacy: .public): \(result.segments.count) segments, \(result.slideEvents.count) events"
        )
        return ImportedLecture(lecture: lecture, recording: result.recording, deck: deck, job: job, wasAlreadyImported: false)
    }

    /// Imports every capture package in `directory` not imported yet (for example after a crash
    /// mid-lecture), skipping `excluding` (a package still recording). Failures are logged.
    @concurrent
    public func importPendingCaptures(in directory: URL, excluding: Set<URL> = []) async -> [ImportedLecture] {
        let excluded = Set(excluding.map(\.lastPathComponent))
        var imported: [ImportedLecture] = []
        for package in (try? LecturePackageReader.pending(in: directory)) ?? [] where !excluded.contains(package.name) {
            do {
                imported.append(try await importCapture(at: package.url))
            } catch {
                Log.importer.error(
                    "Pending capture \(package.name, privacy: .public) not imported: \(String(describing: error), privacy: .public)"
                )
            }
        }
        return imported
    }

    // MARK: - Audio file + slides

    /// Imports an existing recording and, optionally, its slide PDF as a new lecture.
    ///
    /// The audio file is copied into the BlobStore unchanged and becomes a one-segment recording.
    /// Importing the same audio again returns the lecture it already belongs to.
    @concurrent
    public func importRecording(
        audio url: URL,
        deck deckURL: URL? = nil,
        courseID: Course.ID,
        title: String? = nil,
        startedAt: Date? = nil
    ) async throws -> ImportedLecture {
        guard let course = try await fetchCourse(courseID) else { throw LectureImportError.courseMissing }
        let info = try Self.audioInfo(url)
        let ref = try services.blobs.importFile(at: url, mode: .copy)

        if let existing = try await existingImport(sha256: ref.sha256) {
            return existing
        }

        let deck = try await deckURL.asyncMap { try await DeckImporter(services: services).importDeck(at: $0, courseID: course.id).0 }
        let started = startedAt ?? Self.creationDate(of: url) ?? now()
        let lecture = Lecture(
            courseID: course.id,
            title: title ?? deck?.title ?? url.deletingPathExtension().lastPathComponent,
            heldAt: started,
            language: course.language,
            createdAt: now()
        )
        let recording = Recording(
            lectureID: lecture.id,
            courseID: course.id,
            source: .file,
            state: .finished,
            startedAt: started,
            sampleRate: info.sampleRate,
            channelCount: info.channelCount,
            duration: info.duration
        )
        let segment = RecordingSegment(
            recordingID: recording.id,
            sequence: 0,
            startSample: 0,
            frameCount: info.frameCount,
            blobSHA256: ref.sha256,
            blobPath: ref.relativePath,
            byteCount: ref.byteCount ?? 0,
            fileFormat: ref.fileExtension
        )
        let span = deck.map {
            LectureDeckSpan(lectureID: lecture.id, deckID: $0.id, firstPage: 1, lastPage: $0.pageCount, source: .manual)
        }
        let job = Job(stage: .transcribe, lectureID: lecture.id, recordingID: recording.id, createdAt: now())

        let store = store
        let rows = (
            lecture: store.stamp(lecture), recording: store.stamp(recording), segment: store.stamp(segment),
            span: span.map(store.stamp), job: store.stamp(job)
        )
        try await services.database.write { db in
            try Lecture.upsert { rows.lecture }.execute(db)
            try Recording.upsert { rows.recording }.execute(db)
            try RecordingSegment.upsert { rows.segment }.execute(db)
            if let span = rows.span { try LectureDeckSpan.upsert { span }.execute(db) }
            try Job.upsert { rows.job }.execute(db)
        }
        Log.importer.info(
            "Imported \(url.lastPathComponent, privacy: .public): \(info.duration, privacy: .public) s at \(info.sampleRate, privacy: .public) Hz"
        )
        return ImportedLecture(lecture: rows.lecture, recording: rows.recording, deck: deck, job: rows.job, wasAlreadyImported: false)
    }

    // MARK: - Helpers

    struct AudioInfo: Hashable, Sendable {
        var sampleRate: Double
        var channelCount: Int
        var frameCount: Int64
        var duration: Double
    }

    static func audioInfo(_ url: URL) throws -> AudioInfo {
        do {
            let file = try AVAudioFile(forReading: url)
            let rate = file.fileFormat.sampleRate
            guard rate > 0, file.length > 0 else { throw LectureImportError.unreadableAudio(url.lastPathComponent) }
            return AudioInfo(
                sampleRate: rate,
                channelCount: Int(file.fileFormat.channelCount),
                frameCount: file.length,
                duration: Double(file.length) / rate
            )
        } catch let error as LectureImportError {
            throw error
        } catch {
            throw LectureImportError.unreadableAudio(url.lastPathComponent)
        }
    }

    /// True when `url` lies inside `directory` (symlinks resolved, e.g. /var → /private/var).
    static func isInside(_ url: URL, directory: URL) -> Bool {
        func path(_ url: URL) -> String {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            return resolved.hasSuffix("/") ? resolved : resolved + "/"
        }
        let child = path(url)
        let parent = path(directory)
        return child != parent && child.hasPrefix(parent)
    }

    static func creationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    private func fetchCourse(_ id: Course.ID?) async throws -> Course? {
        guard let id else { return nil }
        return try await store.fetch(Course.self, id: id)
    }

    private func existingDeck(id: Deck.ID?, sha256: String?) async throws -> Deck? {
        if let id, let deck = try await store.fetch(Deck.self, id: id) { return deck }
        guard let sha256, !sha256.isEmpty else { return nil }
        return try await services.database.read { db in
            try Deck.where { $0.blobSHA256.eq(sha256) }.fetchOne(db)
        }
    }

    private func ensureLecture(id: Lecture.ID?, course: Course, title: String, heldAt: Date?) async throws -> Lecture {
        if let id, let lecture = try await store.fetch(Lecture.self, id: id) { return lecture }
        return try await store.save(Lecture(
            id: id ?? UUID(),
            courseID: course.id,
            title: title,
            heldAt: heldAt ?? now(),
            language: course.language,
            createdAt: now()
        ))
    }

    /// The coarse, untimed span that says which deck (and pages) a lecture uses. Alignment reads
    /// the deck from it. Replaces an earlier coarse span of the same lecture and deck.
    private func linkDeck(_ deck: Deck, to lecture: Lecture, pages: ClosedRange<Int>?, source: SpanSource) async throws {
        let existing = try await LectureRepository(store: store).spans(lectureID: lecture.id)
            .first { !$0.isTimed && $0.deckID == deck.id }
        try await store.save(LectureDeckSpan(
            id: existing?.id ?? UUID(),
            lectureID: lecture.id,
            deckID: deck.id,
            firstPage: pages?.lowerBound ?? 1,
            lastPage: pages?.upperBound ?? deck.pageCount,
            source: source
        ))
    }

    private func enqueueTranscription(lecture: Lecture, recording: Recording) async throws -> Job {
        try await store.save(Job(stage: .transcribe, lectureID: lecture.id, recordingID: recording.id, createdAt: now()))
    }

    /// The lecture an audio blob was imported into before, if any.
    private func existingImport(sha256: String) async throws -> ImportedLecture? {
        let found: (Recording, Lecture, Job?)? = try await services.database.read { db in
            guard let segment = try RecordingSegment.where({ $0.blobSHA256.eq(sha256) }).fetchOne(db),
                  let recording = try Recording.find(segment.recordingID).fetchOne(db),
                  let lectureID = recording.lectureID,
                  let lecture = try Lecture.find(lectureID).fetchOne(db)
            else { return nil }
            let job = try Job.where { $0.recordingID.eq(recording.id) }.order(by: \.createdAt).fetchAll(db).last
            return (recording, lecture, job)
        }
        guard let (recording, lecture, job) = found else { return nil }
        let deck = try await LectureRepository(store: store).spans(lectureID: lecture.id)
            .first { !$0.isTimed }
            .asyncMap { try await store.fetch(Deck.self, id: $0.deckID) } ?? nil
        return ImportedLecture(lecture: lecture, recording: recording, deck: deck, job: job, wasAlreadyImported: true)
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
