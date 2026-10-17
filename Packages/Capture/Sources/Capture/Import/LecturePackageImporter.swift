import CryptoKit
import Foundation
import StudyCore

extension AnnotationKind {
    /// A moment the student flagged live (F); the body is the flag's text.
    public static let flag: Self = "flag"
}

public enum LecturePackageImportError: Error, Equatable, Sendable {
    case alreadyImported(String)
    case noAudio(String)
    /// A segment is not a regular file inside the package's `audio/` folder.
    case invalidSegment(String)
}

/// Moves a lecture package (finished or left behind by a crash) into the library: audio
/// segments into the BlobStore, and `Recording`, `RecordingSegment`, `SlideEvent`, flag
/// `Annotation`s and quick-note `Note`s into the database, in one transaction.
///
/// Row ids come from the package (the recording id is the package id), so importing the same
/// package twice updates rather than duplicates. Ids for course, lecture and deck that do not
/// exist in the database are dropped instead of failing the import.
public struct LecturePackageImporter: Sendable {
    public struct Result: Sendable, Hashable {
        public var recording: Recording
        public var segments: [RecordingSegment]
        public var slideEvents: [SlideEvent]
        public var annotations: [Annotation]
        public var notes: [Note]
        /// False when the package was recovered after a crash.
        public var wasComplete: Bool
    }

    public let database: any DatabaseWriter
    public let blobs: BlobStore
    private let now: @Sendable () -> Date

    public init(database: any DatabaseWriter, blobs: BlobStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.blobs = blobs
        self.now = now
    }

    public init(services: StudyServices) {
        self.init(database: services.database, blobs: services.blobs)
    }

    /// Imports one package. `lectureID`, `courseID` and `deckID` override the manifest's.
    ///
    /// With `removeAudioAfterImport` the package's audio files are deleted once the rows are
    /// committed (the BlobStore holds the copies; on APFS the copy is a clone); the JSON files
    /// stay as a record. With `markImported` the manifest is marked imported. Both are for
    /// packages live capture wrote into the library; a package the user picked elsewhere is
    /// never changed.
    @concurrent
    public func importPackage(
        _ package: LecturePackage,
        lectureID: Lecture.ID? = nil,
        courseID: Course.ID? = nil,
        deckID: Deck.ID? = nil,
        removeAudioAfterImport: Bool = true,
        markImported: Bool = true,
        force: Bool = false
    ) async throws -> Result {
        let contents = try LecturePackageReader.read(package)
        if contents.manifest.importedAt != nil, !force {
            throw LecturePackageImportError.alreadyImported(package.url.lastPathComponent)
        }
        guard !contents.segments.isEmpty else {
            throw LecturePackageImportError.noAudio(package.url.lastPathComponent)
        }
        // The manifest is untrusted input: only ever copy (and later delete) regular files that
        // really sit in this package's audio folder.
        let audioFiles = try contents.segments.map { segment in
            try Self.verifiedAudioFile(contents.url(for: segment), in: package)
        }

        var imported: [Int: BlobRef] = [:]
        for (segment, file) in zip(contents.segments, audioFiles) {
            imported[segment.sequence] = try blobs.importFile(at: file, mode: .copy)
        }
        let refs = imported

        let stamp = now()
        let result: Result = try await database.write { db in
            let lecture = try (lectureID ?? contents.manifest.lectureID)
                .flatMap { try Lecture.find($0).fetchOne(db)?.id }
            let course = try (courseID ?? contents.manifest.courseID)
                .flatMap { try Course.find($0).fetchOne(db)?.id }
            let deck = try (deckID ?? contents.manifest.deck?.deckID)
                .flatMap { try Deck.find($0).fetchOne(db)?.id }
            let result = Self.records(
                for: contents, blobs: refs, lectureID: lecture, courseID: course, deckID: deck, updatedAt: stamp
            )
            try Recording.upsert { result.recording }.execute(db)
            for row in result.segments { try RecordingSegment.upsert { row }.execute(db) }
            for row in result.slideEvents { try SlideEvent.upsert { row }.execute(db) }
            for row in result.annotations { try Annotation.upsert { row }.execute(db) }
            for row in result.notes { try Note.upsert { row }.execute(db) }
            return result
        }

        if removeAudioAfterImport {
            for file in audioFiles {
                try? FileManager.default.removeItem(at: file)
            }
        }
        if markImported {
            _ = try LecturePackageWriter.updateManifest(of: package) { manifest in
                manifest.importedAt = stamp
                manifest.segments = contents.segments
            }
        }
        CaptureLog.capture.info(
            "Imported \(package.url.lastPathComponent, privacy: .public): \(result.segments.count) segments, \(result.slideEvents.count) stamps"
        )
        return result
    }

    /// `url` if it is a regular file (not a link) directly inside the package's audio folder,
    /// which must not be a link either.
    static func verifiedAudioFile(_ url: URL, in package: LecturePackage) throws -> URL {
        let folderPath = package.audioDirectory.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
        let file = url.standardizedFileURL
        // Without a trailing slash, so a linked folder is seen as the link it is.
        let folder = URL(filePath: folderPath, directoryHint: .notDirectory)
        let folderIsLink = (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard !folderIsLink, values?.isRegularFile == true, values?.isSymbolicLink != true,
              file.deletingLastPathComponent().path(percentEncoded: false).trimmingSuffix("/") == folderPath
        else {
            throw LecturePackageImportError.invalidSegment(url.lastPathComponent)
        }
        return file
    }

    /// Imports every package in `directory` not imported yet, skipping `excluding` (the one being
    /// recorded). Failures are logged and skipped.
    @concurrent
    public func importPending(in directory: URL, excluding: Set<URL> = []) async -> [Result] {
        let excluded = Set(excluding.map(\.lastPathComponent))
        var results: [Result] = []
        for package in (try? LecturePackageReader.pending(in: directory)) ?? [] {
            guard !excluded.contains(package.name) else { continue }
            do {
                results.append(try await importPackage(package))
            } catch {
                CaptureLog.capture.error(
                    "Import of \(package.url.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        return results
    }

    /// The rows for a package (pure; no I/O).
    static func records(
        for contents: LecturePackageContents,
        blobs: [Int: BlobRef],
        lectureID: Lecture.ID?,
        courseID: Course.ID?,
        deckID: Deck.ID?,
        updatedAt: Date
    ) -> Result {
        let manifest = contents.manifest
        let recordingID = manifest.id
        let rate = manifest.sampleRate
        let startedAt = manifest.startedAt ?? contents.events.map(\.wallClock).min() ?? updatedAt

        let recording = Recording(
            id: recordingID,
            lectureID: lectureID,
            courseID: courseID,
            source: recordingSource(platform: manifest.platform),
            state: .finished,
            startedAt: startedAt,
            hostTimeAtStart: manifest.hostTimeAtStart.map { Int64(clamping: $0) },
            sampleRate: rate,
            channelCount: manifest.channelCount,
            duration: contents.duration,
            updatedAt: updatedAt
        )

        let segments = contents.segments.compactMap { segment -> RecordingSegment? in
            guard let ref = blobs[segment.sequence] else { return nil }
            return RecordingSegment(
                id: segment.id,
                recordingID: recordingID,
                sequence: segment.sequence - 1,
                startSample: segment.startSample,
                frameCount: segment.frameCount ?? 0,
                blobSHA256: ref.sha256,
                blobPath: ref.relativePath,
                byteCount: ref.byteCount ?? 0,
                fileFormat: ref.fileExtension.isEmpty ? manifest.fileFormat : ref.fileExtension,
                updatedAt: updatedAt
            )
        }

        var slideEvents: [SlideEvent] = []
        var annotations: [Annotation] = []
        for event in contents.events {
            if event.kind.showsSlide, let page = event.page {
                slideEvents.append(SlideEvent(
                    id: event.id, recordingID: recordingID, lectureID: lectureID, kind: .show,
                    deckID: deckID, pageNumber: page, sampleTime: event.sampleTime,
                    hostTime: Int64(clamping: event.hostTime), wallClock: event.wallClock, updatedAt: updatedAt
                ))
            } else if event.kind == .flag {
                slideEvents.append(SlideEvent(
                    id: event.id, recordingID: recordingID, lectureID: lectureID, kind: .flag,
                    deckID: deckID, pageNumber: nil, sampleTime: event.sampleTime,
                    hostTime: Int64(clamping: event.hostTime), wallClock: event.wallClock, updatedAt: updatedAt
                ))
                if let text = event.text, !text.allSatisfy(\.isWhitespace) {
                    annotations.append(Annotation(
                        id: UUID.derived(from: event.id, salt: "flag-annotation"),
                        lectureID: lectureID,
                        layer: .user,
                        kind: .flag,
                        deckID: deckID,
                        pageNumber: event.page,
                        recordingID: recordingID,
                        startTime: event.time(sampleRate: rate),
                        body: text,
                        createdAt: event.wallClock,
                        updatedAt: updatedAt
                    ))
                }
            }
        }

        let notes = contents.notes.filter { !$0.isBlank }.map { note in
            Note(
                id: note.id,
                courseID: courseID,
                lectureID: lectureID,
                deckID: deckID,
                pageNumber: note.page,
                recordingID: recordingID,
                audioTime: note.sampleTime.map { rate > 0 ? Double($0) / rate : 0 },
                blocksJSON: QuickNoteBlocks.json(for: note.text),
                createdAt: note.createdAt,
                updatedAt: updatedAt
            )
        }

        return Result(
            recording: recording,
            segments: segments,
            slideEvents: slideEvents,
            annotations: annotations,
            notes: notes,
            wasComplete: contents.isComplete
        )
    }

    static func recordingSource(platform: String) -> RecordingSource {
        switch platform {
        case "iPadOS": .iPad
        case "iOS": .iPhone
        default: .mac
        }
    }
}

/// The `note.blocks` JSON for a plain-text quick note: one paragraph block per line.
/// The rich notes editor (M6) owns this format and may extend it.
/// Quick notes become `note.blocks` in StudyCore's `NoteBlock` format: one paragraph per line.
public enum QuickNoteBlocks {
    public static func json(for text: String) -> String {
        NoteBlock.json(NoteBlock.paragraphs(from: text))
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}

extension UUID {
    /// A stable UUID (version 8) derived from `base` and `salt` with SHA-256.
    static func derived(from base: UUID, salt: String) -> UUID {
        var data = withUnsafeBytes(of: base.uuid) { Data($0) }
        data.append(Data(salt.utf8))
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
