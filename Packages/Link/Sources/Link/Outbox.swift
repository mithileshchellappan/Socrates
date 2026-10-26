import Capture
import CryptoKit
import Foundation
import LinkCore
import RecorderContract

/// The phone's outbox (`AppPaths.phoneCaptures`) as the link sees it: which captures there are,
/// which of their files may be offered now, their hashes, and their bytes. Read-only: the recorder
/// owns the packages. Its work runs off the caller's actor.
///
/// What may be offered, by package:
/// - the recording going on (`Live`): its audio segments on disk up to the snapshot's
///   `closedSegments` (a closed file never changes), never its JSON files;
/// - any other package: all of its audio, and its JSON files once it is final: it ended
///   (`endedAt`), or its last event is not a pause (a crash while recording; a recording left
///   paused may still be finished or taken up again, so it is not final);
/// - a package without `endedAt` whose files changed within `quietPeriod` is left out: it may be a
///   recording that started before its first snapshot arrived (unless the recorder said it
///   stopped: `settled`).
enum Outbox {
    /// A package without `endedAt` is offered only once its files have been still this long.
    static let quietPeriod: TimeInterval = 60

    /// The recording going on, from the recorder's snapshot.
    struct Live: Sendable, Hashable {
        var id: RecordingID
        var closedSegments: Int
        var title: String
    }

    /// One file that may be offered.
    struct File: Sendable, Hashable {
        /// Relative to the package: `audio/seg-0001.caf`, `manifest.json`.
        var path: String
        var url: URL
        var size: Int64
        var modified: Date
    }

    /// One capture that may be offered.
    struct Entry: Sendable, Hashable, Identifiable {
        var id: RecordingID
        /// "DC Lecture 2".
        var title: String
        /// Every file is listed and none will change.
        var isFinal: Bool
        var isLive: Bool
        var files: [File]

        var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    /// The outbox now: `entries` for the captures that may be offered, oldest first, leaving out
    /// those received already; `all` every capture's id.
    struct Listing: Sendable {
        var entries: [Entry] = []
        var all: Set<RecordingID> = []
    }

    /// A file's SHA-256, kept in memory while its size and date stay the same.
    struct Hash: Sendable, Hashable {
        var size: Int64
        var modified: Date
        var sha256: String
    }

    // MARK: - Listing

    @concurrent
    static func list(
        in directory: URL, live: Live?, settled: RecordingID?, skipping: Set<RecordingID>, now: Date
    ) async -> Listing {
        let packages: [LecturePackage]
        do {
            packages = try LecturePackage.all(in: directory)
        } catch {
            LinkLog.outbox.error("Listing the outbox failed: \(error.localizedDescription, privacy: .public)")
            return Listing()
        }
        var listing = Listing()
        for package in packages {
            guard let uuid = package.id else { continue }
            let id = RecordingID(uuid)
            listing.all.insert(id)
            guard !skipping.contains(id) else { continue }
            if let live, live.id == id {
                let audio = audioFiles(in: package).filter { $0.sequence <= live.closedSegments }.map(\.file)
                listing.entries.append(Entry(id: id, title: live.title, isFinal: false, isLive: true, files: audio))
                continue
            }
            if let entry = entry(for: package, id: id, isSettled: id == settled, now: now) {
                listing.entries.append(entry)
            }
        }
        return listing
    }

    private static func entry(for package: LecturePackage, id: RecordingID, isSettled: Bool, now: Date) -> Entry? {
        let contents: LecturePackageContents
        do {
            contents = try LecturePackageReader.read(package)
        } catch {
            LinkLog.outbox.notice("Skipping unreadable capture \(id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
        let manifest = contents.manifest
        guard manifest.id == id.rawValue else { return nil }
        let audio = audioFiles(in: package).filter { $0.extension == manifest.fileFormat }.map(\.file)
        let json = jsonFiles(in: package)
        if manifest.endedAt == nil, !isSettled {
            let newest = (audio + json).map(\.modified).max() ?? .distantPast
            guard now.timeIntervalSince(newest) >= quietPeriod else { return nil }
        }
        let isFinal = manifest.endedAt != nil || contents.events.last?.kind != .pause
        return Entry(
            id: id,
            title: title(of: manifest, startedAt: manifest.startedAt ?? contents.events.first?.wallClock),
            isFinal: isFinal,
            isLive: false,
            files: isFinal ? audio + json : audio
        )
    }

    /// "DC Lecture 2" (the recorder's name), else the course and the day.
    private static func title(of manifest: LectureManifest, startedAt: Date?) -> String {
        if let name = manifest.sessionName { return name }
        let course = manifest.courseShortName ?? manifest.courseName
        let day = startedAt?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return [course, day].compactMap(\.self).joined(separator: " ")
    }

    /// The package's segment files: regular files named `seg-NNNN.<ext>` in its audio folder.
    private static func audioFiles(in package: LecturePackage) -> [(sequence: Int, extension: String, file: File)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: package.audioDirectory, includingPropertiesForKeys: keys)) ?? []
        var files: [(sequence: Int, extension: String, file: File)] = []
        for url in urls {
            let name = url.lastPathComponent
            let path = "\(LecturePackage.audioFolder)/\(name)"
            let fileExtension = url.pathExtension
            guard let sequence = InboxRules.segmentSequence(path),
                  name == LecturePackage.segmentFileName(sequence: sequence, fileExtension: fileExtension),
                  let file = file(at: url, path: path)
            else { continue }
            files.append((sequence, fileExtension, file))
        }
        return files.sorted { $0.sequence < $1.sequence }
    }

    /// The package's JSON files that exist (the manifest always does once it was read).
    private static func jsonFiles(in package: LecturePackage) -> [File] {
        [("manifest.json", package.manifestURL), ("events.json", package.eventsURL), ("notes.json", package.notesURL)]
            .compactMap { file(at: $0.1, path: $0.0) }
    }

    private static func file(at url: URL, path: String) -> File? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, let size = values.fileSize
        else { return nil }
        return File(path: path, url: url, size: Int64(size), modified: values.contentModificationDate ?? .distantPast)
    }

    // MARK: - Offers

    /// The offer for `entry`, hashing each file not in `known` (by its URL, while its size and date
    /// are the same); the hashes made come back for the next time. Nil when a file can no longer be
    /// read (the capture was deleted meanwhile).
    @concurrent
    static func offer(for entry: Entry, known: [URL: Hash]) async -> (offer: Offer, hashes: [URL: Hash])? {
        var hashes: [URL: Hash] = [:]
        var files: [OfferedFile] = []
        for file in entry.files {
            let hash: Hash
            if let cached = known[file.url], cached.size == file.size, cached.modified == file.modified {
                hash = cached
            } else {
                guard let sha256 = sha256(of: file.url, size: file.size) else { return nil }
                hash = Hash(size: file.size, modified: file.modified, sha256: sha256)
            }
            hashes[file.url] = hash
            files.append(OfferedFile(path: file.path, size: file.size, sha256: hash.sha256))
        }
        return (Offer(recording: entry.id, title: entry.title, isFinal: entry.isFinal, files: files), hashes)
    }

    /// Lowercase hex of the SHA-256 of the first `size` bytes of `url` (the whole file, which must
    /// have that size).
    private static func sha256(of url: URL, size: Int64) -> String? {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            var remaining = size
            while remaining > 0 {
                guard let piece = try handle.read(upToCount: Int(min(remaining, 1 << 20))), !piece.isEmpty else { return nil }
                hasher.update(data: piece)
                remaining -= Int64(piece.count)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            LinkLog.outbox.notice("Hashing \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Sending

    /// Sends `url`'s bytes from `offset` up to `size` as chunks answering `want`, one at a time:
    /// each `send` returns once its chunk went to the network. Throws when the file cannot be read
    /// to `size` (deleted or cut short) or when sending fails.
    @concurrent
    static func stream(
        _ url: URL, from offset: Int64, size: Int64, want: UInt32, send: @Sendable (Chunk) async throws -> Void
    ) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        var position = offset
        while position < size {
            try Task.checkCancellation()
            let count = Int(min(Int64(LinkPolicy.chunkSize), size - position))
            guard let bytes = try handle.read(upToCount: count), bytes.count == count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try await send(Chunk(want: want, offset: position, bytes: bytes))
            position += Int64(count)
        }
    }
}
