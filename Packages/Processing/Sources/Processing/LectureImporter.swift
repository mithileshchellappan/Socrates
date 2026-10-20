import AVFAudio
import Capture
import Foundation
import StudyCore

public enum LectureImportError: Error, Equatable, Sendable, LocalizedError {
    /// The course does not exist (a lecture always belongs to a course).
    case courseMissing
    /// The lecture or session to attach to does not exist (any more).
    case lectureMissing
    /// The file is not audio this device can decode.
    case unreadableAudio(String)
    /// The package was imported before and its audio is gone, but no recording row exists.
    case packageAlreadyImported(String)

    public var errorDescription: String? {
        switch self {
        case .courseMissing: String(localized: "Choose a course.")
        case .lectureMissing: String(localized: "The lecture is gone.")
        case .unreadableAudio(let name): String(localized: "“\(name)” can’t be read as audio.")
        case .packageAlreadyImported(let name): String(localized: "“\(name)” was imported before.")
        }
    }
}

/// Which lecture an import goes into.
public enum LectureTarget: Sendable, Hashable {
    /// A new lecture. `number`, `heldAt` and `sessionID` fill in what the import does not know
    /// (held-at defaults to the recording start).
    case newLecture(number: Int? = nil, heldAt: Date? = nil, sessionID: LectureSession.ID? = nil)
    /// An existing lecture (its course wins over the import's).
    case lecture(Lecture.ID)
    /// The lecture filed to this session; created, linked to the session, when there is none.
    case session(LectureSession.ID)

    /// A new lecture with nothing known in advance.
    public static let new = LectureTarget.newLecture()
}

/// What an import created (or found, when the same recording was imported before).
public struct ImportedLecture: Sendable, Hashable {
    public var lecture: Lecture
    public var recording: Recording
    public var deck: Deck?
    /// The transcription job; nil when the recording was imported before and already has one.
    public var job: Job?
    public var wasAlreadyImported: Bool
    /// The import created `lecture` (false when it attached to an existing one).
    public var createdLecture: Bool = false
    /// The import dated an existing lecture (undated, or dated by day only) with the recording's
    /// start; `previousHeldAt` is what it said before (what Undo puts back).
    public var redatedLecture: Bool = false
    public var previousHeldAt: Date?
}

/// A deck linked to a lecture by `LectureImporter.attachDeck`.
public struct AttachedDeck: Sendable, Hashable {
    public var lecture: Lecture
    public var deck: Deck
    /// The coarse, untimed span tying the deck to the lecture.
    public var span: LectureDeckSpan
    public var createdLecture: Bool
    /// `align` jobs queued for the lecture's recordings that already had a transcript.
    public var alignJobs: [Job]
    /// The deck belonged to another course (or none) before and was moved to the lecture's;
    /// `previousDeckCourseID` is that course (what Undo puts back).
    public var movedDeck: Bool = false
    public var previousDeckCourseID: Course.ID?
}

/// Brings a lecture into the library and queues its processing.
///
/// Two ways in, one result (`Lecture` + `Recording` + segments + optional `Deck`, a coarse
/// `lecture_deck_span` tying the deck to the lecture, and a queued transcription `Job`):
/// - `importCapture(at:)`: a `<uuid>.lecture` package from live capture (stamps included);
/// - `importRecording(audio:deck:courseID:)`: any audio file the system can decode (Voice
///   Memos `.qta`/`.m4a`, `.wav`, `.caf`, …) plus an optional slide PDF.
///
/// Both create a new lecture by default; `into:` attaches to an existing lecture or to a
/// session's lecture instead (smart import). `attachDeck` links a slide deck on its own, and
/// queues alignment when the lecture's recordings are already transcribed.
///
/// The jobs run in `LectureProcessor`.
public struct LectureImporter: Sendable {
    public let services: StudyServices
    private let now: @Sendable () -> Date

    /// Extra rows written in the same transaction as the import (e.g. smart import's `filing`).
    public typealias Companion = @Sendable (Database, ImportedLecture) throws -> Void

    public init(services: StudyServices, now: @escaping @Sendable () -> Date = { Date() }) {
        self.services = services
        self.now = now
    }

    private var store: RecordStore { services.records }

    // MARK: - Captured packages

    /// Imports a lecture package written by live capture.
    ///
    /// `courseID` and `deckURL` fill in what the manifest lacks. By default the manifest's
    /// lecture id is kept so notes taken live stay attached; `into:` files the capture into an
    /// existing lecture or a session's lecture instead (notes and stamps move with it). A package
    /// imported before (its audio already moved into the library) resolves to its existing
    /// recording.
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
        title: String? = nil,
        into target: LectureTarget = .new
    ) async throws -> ImportedLecture {
        let package = LecturePackage(url: url)
        let contents = try LecturePackageReader.read(package)
        let manifest = contents.manifest
        let targetCourse = try await targetCourseID(target)
        guard let course = try await fetchCourse(targetCourse ?? courseID ?? manifest.courseID) else {
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
        // Its audio is gone and nothing in the library has it: fail before writing anything.
        if alreadyImported, existingRecording == nil {
            throw LectureImportError.packageAlreadyImported(package.name)
        }
        var filedLecture: Lecture?
        if alreadyImported, let lectureID = existingRecording?.lectureID {
            filedLecture = try await store.fetch(Lecture.self, id: lectureID)
        }
        let lecture: Lecture
        var committed: CommittedLecture?
        if let filedLecture {
            lecture = filedLecture
        } else {
            let plan = try await lecturePlan(
                for: target, course: course, newID: manifest.lectureID,
                title: title ?? deck?.title ?? "", heldAt: manifest.startedAt ?? now()
            )
            let store = store
            let written = try await services.database.write { db in
                try Self.commit(plan, target: target, in: db, store: store)
            }
            lecture = written.lecture
            committed = written
        }
        let createdLecture = committed?.created ?? false

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
                wasAlreadyImported: true, createdLecture: createdLecture,
                redatedLecture: committed?.redated ?? false, previousHeldAt: committed?.previousHeldAt
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
        return ImportedLecture(
            lecture: lecture, recording: result.recording, deck: deck, job: job,
            wasAlreadyImported: false, createdLecture: createdLecture,
            redatedLecture: committed?.redated ?? false, previousHeldAt: committed?.previousHeldAt
        )
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

    /// Imports an existing recording and, optionally, its slide PDF, into a new lecture or the
    /// lecture `into` names.
    ///
    /// The audio file is copied into the BlobStore unchanged and becomes a one-segment recording.
    /// Importing the same audio again returns the lecture it already belongs to (and `then` is
    /// not called). `then` runs inside the import's write transaction.
    @concurrent
    public func importRecording(
        audio url: URL,
        deck deckURL: URL? = nil,
        courseID: Course.ID,
        title: String? = nil,
        startedAt: Date? = nil,
        into target: LectureTarget = .new,
        then companion: Companion? = nil
    ) async throws -> ImportedLecture {
        let targetCourse = try await targetCourseID(target)
        guard let course = try await fetchCourse(targetCourse ?? courseID) else { throw LectureImportError.courseMissing }
        let info = try Self.audioInfo(url)
        let ref = try services.blobs.importFile(at: url, mode: .copy)

        if let existing = try await existingImport(sha256: ref.sha256) {
            return existing
        }

        let deck = try await deckURL.asyncMap { try await DeckImporter(services: services).importDeck(at: $0, courseID: course.id).0 }
        let started = startedAt ?? Self.creationDate(of: url) ?? now()
        let plan = try await lecturePlan(
            for: target, course: course, newID: nil,
            title: title ?? deck?.title ?? url.deletingPathExtension().lastPathComponent,
            heldAt: started
        )
        let store = store
        let createdAt = now()
        // The rows are built inside the transaction: a session's lecture is only known there.
        let imported = try await services.database.write { db -> ImportedLecture in
            let committed = try Self.commit(plan, target: target, in: db, store: store)
            let lecture = committed.lecture
            let recording = store.stamp(Recording(
                lectureID: lecture.id,
                courseID: course.id,
                source: .file,
                state: .finished,
                startedAt: started,
                sampleRate: info.sampleRate,
                channelCount: info.channelCount,
                duration: info.duration
            ))
            let segment = store.stamp(RecordingSegment(
                recordingID: recording.id,
                sequence: 0,
                startSample: 0,
                frameCount: info.frameCount,
                blobSHA256: ref.sha256,
                blobPath: ref.relativePath,
                byteCount: ref.byteCount ?? 0,
                fileFormat: ref.fileExtension
            ))
            let span = deck.map {
                store.stamp(LectureDeckSpan(lectureID: lecture.id, deckID: $0.id, firstPage: 1, lastPage: $0.pageCount, source: .manual))
            }
            let job = store.stamp(Job(stage: .transcribe, lectureID: lecture.id, recordingID: recording.id, createdAt: createdAt))
            try Recording.upsert { recording }.execute(db)
            try RecordingSegment.upsert { segment }.execute(db)
            if let span { try LectureDeckSpan.upsert { span }.execute(db) }
            try Job.upsert { job }.execute(db)
            let imported = ImportedLecture(
                lecture: lecture, recording: recording, deck: deck, job: job,
                wasAlreadyImported: false, createdLecture: committed.created,
                redatedLecture: committed.redated, previousHeldAt: committed.previousHeldAt
            )
            try companion?(db, imported)
            return imported
        }
        Log.importer.info(
            "Imported \(url.lastPathComponent, privacy: .public): \(info.duration, privacy: .public) s at \(info.sampleRate, privacy: .public) Hz"
        )
        return imported
    }

    /// Stores a recording that belongs to no course yet (smart import found none): the audio in
    /// the BlobStore and a `Recording` + one segment without lecture or course. With `transcribe`
    /// its transcription is queued at once (without a lecture), so what was said can file it;
    /// filing it later (`Recording.lectureID`) is the caller's.
    /// Returns the existing recording when the same audio was stored before.
    @concurrent
    public func storeRecording(audio url: URL, startedAt: Date? = nil, transcribe: Bool = false) async throws -> Recording {
        let info = try Self.audioInfo(url)
        let ref = try services.blobs.importFile(at: url, mode: .copy)
        let sha = ref.sha256
        if let existing = try await services.database.read({ db in
            try RecordingSegment.where { $0.blobSHA256.eq(sha) }.fetchOne(db)
                .flatMap { try Recording.find($0.recordingID).fetchOne(db) }
        }) {
            return existing
        }
        let recording = store.stamp(Recording(
            source: .file, state: .finished, startedAt: startedAt ?? Self.creationDate(of: url) ?? now(),
            sampleRate: info.sampleRate, channelCount: info.channelCount, duration: info.duration
        ))
        let segment = store.stamp(RecordingSegment(
            recordingID: recording.id, sequence: 0, startSample: 0, frameCount: info.frameCount,
            blobSHA256: ref.sha256, blobPath: ref.relativePath, byteCount: ref.byteCount ?? 0, fileFormat: ref.fileExtension
        ))
        let job = transcribe ? store.stamp(Job(stage: .transcribe, recordingID: recording.id, createdAt: now())) : nil
        try await services.database.write { db in
            try Recording.upsert { recording }.execute(db)
            try RecordingSegment.upsert { segment }.execute(db)
            if let job { try Job.upsert { job }.execute(db) }
        }
        return recording
    }

    // MARK: - Slides on their own

    /// Links an imported deck to the lecture `target` names (creating it when needed) with a
    /// coarse span over the whole deck, sets the deck's course, and queues `align` for the
    /// lecture's recordings that already have a transcript, all in one transaction (with `then`).
    @concurrent
    public func attachDeck(
        _ deck: Deck,
        to target: LectureTarget,
        courseID: Course.ID,
        title: String? = nil,
        then companion: (@Sendable (Database, AttachedDeck) throws -> Void)? = nil
    ) async throws -> AttachedDeck {
        let targetCourse = try await targetCourseID(target)
        guard let course = try await fetchCourse(targetCourse ?? courseID) else { throw LectureImportError.courseMissing }
        let plan = try await lecturePlan(for: target, course: course, newID: nil, title: title ?? deck.title, heldAt: nil)
        let store = store
        let now = now()
        let deckCourse = course.id
        return try await services.database.write { db in
            let committed = try Self.commit(plan, target: target, in: db, store: store)
            let lecture = committed.lecture
            let created = committed.created
            // The deck as it is now (not as the caller read it); only its course changes.
            var current = try Deck.find(deck.id).fetchOne(db) ?? deck
            let previousCourse = current.courseID
            current.courseID = deckCourse
            let stampedDeck = store.stamp(current)
            try Deck.upsert { stampedDeck }.execute(db)
            let existing = try LectureDeckSpan
                .where { $0.lectureID.eq(lecture.id) && $0.deckID.eq(stampedDeck.id) && $0.startTime.is(nil) }
                .fetchOne(db)
            let span = store.stamp(LectureDeckSpan(
                id: existing?.id ?? UUID(), lectureID: lecture.id, deckID: stampedDeck.id,
                firstPage: existing?.firstPage ?? 1, lastPage: existing?.lastPage ?? stampedDeck.pageCount,
                source: existing?.source ?? .manual
            ))
            try LectureDeckSpan.upsert { span }.execute(db)
            let jobs = try Self.alignmentJobs(lectureID: lecture.id, in: db, now: now).map(store.stamp)
            for job in jobs { try Job.upsert { job }.execute(db) }
            let attached = AttachedDeck(
                lecture: lecture, deck: stampedDeck, span: span, createdLecture: created, alignJobs: jobs,
                movedDeck: previousCourse != deckCourse, previousDeckCourseID: previousCourse
            )
            try companion?(db, attached)
            return attached
        }
    }

    /// `align` jobs (not saved) for the lecture's recordings that have a transcript and no queued
    /// or running transcription or alignment: the deck/recording pairing changed, so alignment
    /// must run again. Recordings still waiting for their transcript get alignment queued by
    /// the transcription itself. For use inside a write transaction.
    public static func alignmentJobs(lectureID: Lecture.ID, in db: Database, now: Date = Date()) throws -> [Job] {
        // mr: one rule for every writer of a lecture's slides (StudyCore `LectureSlides`).
        try LectureSlides.alignmentJobs(lectureID: lectureID, in: db, now: now)
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

    /// The course of an existing lecture or session target; nil for a new lecture.
    private func targetCourseID(_ target: LectureTarget) async throws -> Course.ID? {
        switch target {
        case .newLecture:
            return nil
        case .lecture(let id):
            guard let lecture = try await store.fetch(Lecture.self, id: id) else { throw LectureImportError.lectureMissing }
            return lecture.courseID
        case .session(let id):
            guard let session = try await store.fetch(LectureSession.self, id: id) else { throw LectureImportError.lectureMissing }
            return session.courseID
        }
    }

    private struct LecturePlan: Sendable {
        var lecture: Lecture
        /// The lecture does not exist yet.
        var isNew: Bool
        /// An existing lecture without a time takes the import's start (`heldAt`); it said
        /// `previousHeldAt` before.
        var heldAt: Date?
        var previousHeldAt: Date?
    }

    /// The lecture an import went into, as written by `commit`.
    struct CommittedLecture: Sendable {
        var lecture: Lecture
        var created: Bool
        var redated = false
        var previousHeldAt: Date?
    }

    /// Writes the planned lecture inside the import's transaction and returns it.
    ///
    /// A session's lecture is resolved here, not when planning: two imports for one session
    /// (a drop while a capture is being filed) never create two lectures, and a lecture filed
    /// before the session existed is adopted and linked (`SessionLectures`). An existing
    /// lecture's date is the only column written, and only when nobody dated it meanwhile.
    private static func commit(_ plan: LecturePlan, target: LectureTarget, in db: Database, store: RecordStore) throws -> CommittedLecture {
        if case .session(let id) = target, let lecture = try SessionLectures.resolve(sessionID: id, in: db, stamp: store.currentDate) {
            return CommittedLecture(lecture: lecture, created: false)
        }
        if plan.isNew {
            let lecture = store.stamp(plan.lecture)
            try Lecture.upsert { lecture }.execute(db)
            return CommittedLecture(lecture: lecture, created: true)
        }
        let id = plan.lecture.id
        guard let current = try Lecture.find(id).fetchOne(db) else { throw LectureImportError.lectureMissing }
        guard let heldAt = plan.heldAt, current.heldAt == plan.previousHeldAt else {
            return CommittedLecture(lecture: current, created: false)
        }
        let stamp = store.currentDate
        let dated: Date? = heldAt
        try Lecture.find(id).update { $0.heldAt = dated; $0.updatedAt = stamp }.execute(db)
        return CommittedLecture(
            lecture: try Lecture.find(id).fetchOne(db) ?? current, created: false, redated: true, previousHeldAt: current.heldAt
        )
    }

    /// The lecture an import goes into, not yet written (`commit` writes it). An existing lecture
    /// without a session whose date is unknown or only a day (a deck's title-slide date) takes
    /// `heldAt`.
    private func lecturePlan(for target: LectureTarget, course: Course, newID: Lecture.ID?, title: String, heldAt: Date?) async throws -> LecturePlan {
        func newLecture(number: Int?, heldAt: Date?, sessionID: LectureSession.ID?) async throws -> LecturePlan {
            if let newID, let existing = try await store.fetch(Lecture.self, id: newID) {
                return LecturePlan(lecture: existing, isNew: false)
            }
            return LecturePlan(
                lecture: Lecture(
                    id: newID ?? UUID(), courseID: course.id, lectureSessionID: sessionID, number: number,
                    title: title, heldAt: heldAt, language: course.language, createdAt: now()
                ),
                isNew: true
            )
        }
        func dated(_ lecture: Lecture) async throws -> LecturePlan {
            guard let heldAt, lecture.lectureSessionID == nil else {
                return LecturePlan(lecture: lecture, isNew: false)
            }
            let zone = try await SemesterRepository(store: store).semester(for: course, on: heldAt).zone
            let sameDay = lecture.heldAt.map { CalendarDay($0, in: zone) == CalendarDay(heldAt, in: zone) } ?? true
            guard lecture.heldAt == nil || (sameDay && Self.isWholeDay(lecture.heldAt, in: zone)) else {
                return LecturePlan(lecture: lecture, isNew: false)
            }
            return LecturePlan(lecture: lecture, isNew: false, heldAt: heldAt, previousHeldAt: lecture.heldAt)
        }

        switch target {
        case .newLecture(let number, let date, let sessionID):
            return try await newLecture(number: number, heldAt: date ?? heldAt, sessionID: sessionID)
        case .lecture(let id):
            guard let lecture = try await store.fetch(Lecture.self, id: id) else { throw LectureImportError.lectureMissing }
            return try await dated(lecture)
        case .session(let id):
            guard let session = try await store.fetch(LectureSession.self, id: id) else { throw LectureImportError.lectureMissing }
            // Filed to the session, or held in it before it existed; `commit` resolves it again.
            if let found = try await services.database.read({ db in try SessionLectures.lecture(forSession: id, in: db) }) {
                return LecturePlan(lecture: found.lecture, isNew: false)
            }
            return try await newLecture(number: session.number, heldAt: session.startsAt, sessionID: session.id)
        }
    }

    /// True for local midnight in `zone`: a lecture dated by day only.
    public static func isWholeDay(_ date: Date?, in zone: TimeZone) -> Bool {
        guard let date else { return false }
        return CalendarDay(date, in: zone).start(in: zone) == date
    }

    private func existingDeck(id: Deck.ID?, sha256: String?) async throws -> Deck? {
        if let id, let deck = try await store.fetch(Deck.self, id: id) { return deck }
        guard let sha256, !sha256.isEmpty else { return nil }
        return try await services.database.read { db in
            try Deck.where { $0.blobSHA256.eq(sha256) }.fetchOne(db)
        }
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
