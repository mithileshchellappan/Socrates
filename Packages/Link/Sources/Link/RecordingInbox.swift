import Capture
import CryptoKit
import Foundation
import LinkCore
import RecorderContract
import StudyCore

/// The Mac's only writer of recordings arriving over the link. Each phone's recordings are staged
/// apart from the library, in `Incoming/<device>/<uuid>.lecture.partial/` (outside `Recordings/`,
/// so the launch filing pass never takes half a package), one file at a time:
///
/// - only a package's files are taken (`InboxRules`: paths and caps), checked when offered;
/// - a file is written to `<path>.part` from the length already there (a reconnect resumes at it),
///   its SHA-256 computed as it grows, fully synced every `LinkPolicy.ackInterval` bytes (each
///   sync acknowledged) and at its end, and renamed to `<path>` only when the hash matches the
///   offer; a first mismatch starts the file over, a second refuses the recording;
/// - a recording is complete when its final offer's files are all checked: the package is read
///   (its manifest names this recording, every segment has its canonical path), moved into
///   `Recordings/` in one step, and handed to filing by the caller.
///
/// What the Mac holds is the staging folder itself; nothing else is persisted.
actor RecordingInbox {
    enum OfferDecision: Sendable {
        /// Taken: the arrival row (for a final offer) and the bytes already here.
        case accepted(Arrival?, held: [Stored])
        /// The Mac has this recording already: nothing is copied.
        case known
        /// Not a package the inbox takes (a path or a size the rules refuse).
        case refused
    }

    /// The next file to ask for.
    struct Next: Sendable, Hashable {
        var recording: RecordingID
        var path: String
        var from: Int64
    }

    /// What `nextWant` found.
    enum WantDecision: Sendable, Hashable {
        /// Ask the phone for this file.
        case want(Next)
        /// A file found whole failed its hash twice: the recording's staging is gone (the phone is
        /// told `refused`).
        case refused(RecordingID)
        /// Files found whole were checked and completed a recording: complete it, then look again.
        case checked
        /// Nothing to ask for now (all here, no room, or a file that cannot be kept).
        case nothing
    }

    enum WriteResult: Sendable {
        /// Written; an acknowledgement (and the arrival's progress) when one is due.
        case written(Stored?, Arrival?)
        /// The file is whole and its hash matched.
        case verified(Stored, Arrival?)
        /// The want ends without the file: ask again (from where the file now stands).
        case again
        /// The recording failed its checks twice: its staging is gone.
        case refused(RecordingID)
        /// A chunk this inbox does not wait for (a want that was dropped).
        case ignored
    }

    enum Completion: Sendable {
        /// In `Recordings/` now, at this URL.
        case kept(URL)
        /// A package of that id was in `Recordings/` already.
        case known
        /// It failed the package checks.
        case refused
        /// It could not be moved (left in staging; tried again later).
        case failed
    }

    /// Who acts on the inbox: a phone and the session it speaks through. Only the session that
    /// claimed the phone last is heard, so a replaced session's late messages never touch the
    /// files its successor writes.
    struct Sender: Hashable, Sendable {
        var device: LinkDeviceID
        var session: UUID
    }

    /// One recording being received from one phone.
    private struct Incoming {
        var offer: Offer
        /// Bytes on disk per offered path (the whole size once checked).
        var held: [String: Int64] = [:]
        /// Paths whose file is whole and checked.
        var verified: Set<String> = []

        var isComplete: Bool {
            offer.isFinal && offer.files.allSatisfy { verified.contains($0.path) }
        }

        var arrival: Arrival {
            let stored = offer.files.reduce(Int64(0)) { $0 + min(held[$1.path] ?? 0, $1.size) }
            return Arrival(id: offer.recording, title: offer.title, stored: stored, total: offer.totalBytes)
        }
    }

    /// The file a phone's want is filling.
    private struct OpenFile {
        let recording: RecordingID
        let file: OfferedFile
        let partURL: URL
        let finalURL: URL
        let handle: FileHandle
        var hasher: SHA256
        var length: Int64
        /// The length last synced and acknowledged.
        var acknowledged: Int64
    }

    private let services: StudyServices
    private var incoming: [LinkDeviceID: [RecordingID: Incoming]] = [:]
    /// Each phone's recordings in the order first offered.
    private var order: [LinkDeviceID: [RecordingID]] = [:]
    private var open: [LinkDeviceID: OpenFile] = [:]
    /// Hash mismatches per file ("<device>/<recording>/<path>").
    private var mismatches: [String: Int] = [:]
    private var lowDiskLogged: Set<RecordingID> = []
    /// The session each phone speaks through now.
    private var owners: [LinkDeviceID: UUID] = [:]

    init(services: StudyServices) {
        self.services = services
    }

    private var root: URL { services.paths.linkInbox }

    private func folder(of device: LinkDeviceID) -> URL {
        root.appending(path: device.rawValue.uuidString, directoryHint: .isDirectory)
    }

    private func staging(_ recording: RecordingID, of device: LinkDeviceID) -> URL {
        folder(of: device).appending(path: "\(recording.uuidString).\(LecturePackage.pathExtension).partial", directoryHint: .isDirectory)
    }

    private func destination(of recording: RecordingID) -> URL {
        services.paths.recordings.appending(path: "\(recording.uuidString).\(LecturePackage.pathExtension)", directoryHint: .isDirectory)
    }

    // MARK: - Lifecycle

    /// Deletes staging left untouched for `LinkPolicy.stagingLifetime`.
    func start() {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-LinkPolicy.stagingLifetime)
        let devices = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for device in devices {
            let partials = (try? fileManager.contentsOfDirectory(at: device, includingPropertiesForKeys: nil)) ?? []
            for partial in partials where newestModification(in: partial) < cutoff {
                LinkLog.inbox.notice("Deleting stale staging \(partial.lastPathComponent, privacy: .public)")
                try? fileManager.removeItem(at: partial)
            }
            if ((try? fileManager.contentsOfDirectory(atPath: device.path(percentEncoded: false))) ?? []).isEmpty {
                try? fileManager.removeItem(at: device)
            }
        }
    }

    /// `sender`'s session speaks for its phone from now on: whatever an earlier session left open
    /// is synced and closed, and the offers are forgotten until the phone offers again.
    func claim(_ sender: Sender) {
        forget(sender.device)
        owners[sender.device] = sender.session
    }

    /// `sender`'s session ended: the file being written is synced and closed (its length is where
    /// a later want starts).
    func release(_ sender: Sender) {
        guard owners[sender.device] == sender.session else { return }
        forget(sender.device)
        owners[sender.device] = nil
    }

    private func forget(_ device: LinkDeviceID) {
        close(device: device)
        incoming[device] = nil
        order[device] = nil
    }

    /// Closes every open file (the link stopped).
    func stop() {
        for device in Array(open.keys) { close(device: device) }
        incoming = [:]
        order = [:]
        owners = [:]
    }

    // MARK: - Offers

    /// Takes `offer` from `device`'s phone, unless the rules refuse it or the Mac has the
    /// recording already (filed, imported, or in `Recordings/`).
    func offer(_ offer: Offer, from sender: Sender) async -> OfferDecision {
        let device = sender.device
        guard owners[device] == sender.session else { return .accepted(nil, held: []) }
        let paths = offer.files.map(\.path)
        guard offer.files.count <= InboxRules.maximumFiles, Set(paths).count == paths.count,
              offer.files.allSatisfy(InboxRules.accepts)
        else {
            LinkLog.inbox.error("Refused an offer of \(offer.recording.uuidString, privacy: .public): files the inbox does not take")
            discard(offer.recording, of: device)
            return .refused
        }
        if await isKnown(offer.recording) {
            discard(offer.recording, of: device)
            return .known
        }
        guard owners[device] == sender.session else { return .accepted(nil, held: []) }
        var state = incoming[device]?[offer.recording] ?? Incoming(offer: offer)
        let previous = state.offer
        state.offer = offer
        let folder = staging(offer.recording, of: device)
        let writing = open[device].flatMap { $0.recording == offer.recording ? $0.file.path : nil }
        var held: [String: Int64] = [:]
        var verified: Set<String> = []
        for file in offer.files {
            if file.path == writing, let length = open[device]?.length {
                held[file.path] = length
                continue
            }
            let url = folder.appending(path: file.path, directoryHint: .notDirectory)
            let earlier = previous.files.first { $0.path == file.path }
            if earlier == file, state.verified.contains(file.path) {
                held[file.path] = file.size
                verified.insert(file.path)
                continue
            }
            if let earlier, earlier != file {
                // Offered differently than before: what is here was checked against other bytes.
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: Self.partURL(for: url))
            }
            let (bytes, isWhole) = Self.scan(url, size: file.size)
            held[file.path] = bytes
            if isWhole { verified.insert(file.path) }
        }
        state.held = held
        state.verified = verified
        incoming[device, default: [:]][offer.recording] = state
        if order[device]?.contains(offer.recording) != true {
            order[device, default: []].append(offer.recording)
        }
        let acknowledged = offer.files.compactMap { file -> Stored? in
            guard let bytes = held[file.path], bytes > 0 else { return nil }
            return Stored(recording: offer.recording, path: file.path, bytes: bytes, isVerified: verified.contains(file.path))
        }
        return .accepted(offer.isFinal ? state.arrival : nil, held: acknowledged)
    }

    /// What is on disk for one file: its whole size when the checked file is there with the size
    /// offered, else the length of its `.part` (anything larger than offered is deleted).
    private static func scan(_ url: URL, size: Int64) -> (bytes: Int64, isWhole: Bool) {
        let fileManager = FileManager.default
        if let whole = fileSize(url) {
            if whole == size { return (size, true) }
            try? fileManager.removeItem(at: url)
        }
        let part = partURL(for: url)
        guard let length = fileSize(part) else { return (0, false) }
        guard length <= size else {
            try? fileManager.removeItem(at: part)
            return (0, false)
        }
        return (length, false)
    }

    /// Keeps only `recordings` of `device`'s staging (its phone no longer offers the others: the
    /// student deleted them there).
    func keep(_ recordings: [RecordingID], from sender: Sender) {
        let device = sender.device
        guard owners[device] == sender.session else { return }
        let kept = Set(recordings)
        for recording in (incoming[device]?.keys).map(Array.init) ?? [] where !kept.contains(recording) {
            discard(recording, of: device)
        }
        let suffix = ".\(LecturePackage.pathExtension).partial"
        let partials = (try? FileManager.default.contentsOfDirectory(at: folder(of: device), includingPropertiesForKeys: nil)) ?? []
        for partial in partials {
            let name = partial.lastPathComponent
            guard name.hasSuffix(suffix), let id = RecordingID(uuidString: String(name.dropLast(suffix.count))) else { continue }
            if !kept.contains(id) {
                LinkLog.inbox.notice("Deleting staging of \(id.uuidString, privacy: .public): no longer on the phone")
                try? FileManager.default.removeItem(at: partial)
            }
        }
    }

    private func discard(_ recording: RecordingID, of device: LinkDeviceID) {
        if let file = open[device], file.recording == recording {
            try? file.handle.close()
            open[device] = nil
        }
        incoming[device]?[recording] = nil
        order[device]?.removeAll { $0 == recording }
        mismatches = mismatches.filter { !$0.key.hasPrefix("\(device)/\(recording)/") }
        try? FileManager.default.removeItem(at: staging(recording, of: device))
    }

    private func isKnown(_ recording: RecordingID) async -> Bool {
        if FileManager.default.fileExists(atPath: destination(of: recording).path(percentEncoded: false)) { return true }
        do {
            if try await FilingRepository(store: services.records).latest(recordingID: recording.rawValue) != nil { return true }
            if try await services.records.fetch(Recording.self, id: recording.rawValue) != nil { return true }
        } catch {
            LinkLog.inbox.error("Looking up \(recording.uuidString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        return false
    }

    // MARK: - Wants

    /// The next file `device`'s phone should send: final recordings first (in the order offered),
    /// then the others' closed segments. A file found whole already (an empty one, or a quit
    /// before its rename) is checked on the way and the next one looked at. Nothing is asked for
    /// when the disk would keep less than `LinkPolicy.diskReserve`.
    func nextWant(from sender: Sender) -> WantDecision {
        let device = sender.device
        guard owners[device] == sender.session, open[device] == nil else { return .nothing }
        let ids = order[device] ?? []
        let finals = ids.filter { incoming[device]?[$0]?.offer.isFinal == true }
        let others = ids.filter { incoming[device]?[$0]?.offer.isFinal != true }
        for recording in finals + others {
            // A file is looked at twice at most: once found whole (and failing its hash), once
            // more from the start; one that cannot be kept waits for a later want.
            var visits: [String: Int] = [:]
            while let state = incoming[device]?[recording],
                  let file = state.offer.files.first(where: { !state.verified.contains($0.path) }) {
                let visit = (visits[file.path] ?? 0) + 1
                visits[file.path] = visit
                guard visit <= 2 else { return .nothing }
                let from = state.held[file.path] ?? 0
                guard hasRoom(for: file.size - from) else {
                    if lowDiskLogged.insert(recording).inserted {
                        LinkLog.inbox.error("Not enough free space for \(recording.uuidString, privacy: .public); it waits")
                    }
                    return .nothing
                }
                let opened: OpenFile
                do {
                    opened = try openFile(file, of: recording, device: device)
                } catch {
                    LinkLog.inbox.error("Opening \(file.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    return .nothing
                }
                open[device] = opened
                if opened.length < file.size {
                    return .want(Next(recording: recording, path: file.path, from: opened.length))
                }
                switch finish(device: device) {
                case .verified:
                    if incoming[device]?[recording]?.isComplete == true { return .checked }
                case .refused(let refused):
                    return .refused(refused)
                case .again:
                    // Its hash failed (asked for from the start next) or it could not be kept.
                    continue
                case .written, .ignored:
                    return .nothing
                }
            }
        }
        return .nothing
    }

    private func openFile(_ file: OfferedFile, of recording: RecordingID, device: LinkDeviceID) throws -> OpenFile {
        let fileManager = FileManager.default
        let finalURL = staging(recording, of: device).appending(path: file.path, directoryHint: .notDirectory)
        let partURL = Self.partURL(for: finalURL)
        try fileManager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: partURL.path(percentEncoded: false)) {
            guard fileManager.createFile(atPath: partURL.path(percentEncoded: false), contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forUpdating: partURL)
        do {
            var length = Int64(try handle.seekToEnd())
            if length > file.size {
                try handle.truncate(atOffset: 0)
                length = 0
            }
            // The bytes already there count into the hash: read them once.
            var hasher = SHA256()
            try handle.seek(toOffset: 0)
            var read: Int64 = 0
            while read < length {
                guard let piece = try handle.read(upToCount: Int(min(length - read, 1 << 20))), !piece.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                hasher.update(data: piece)
                read += Int64(piece.count)
            }
            try handle.seek(toOffset: UInt64(length))
            return OpenFile(
                recording: recording, file: file, partURL: partURL, finalURL: finalURL,
                handle: handle, hasher: hasher, length: length, acknowledged: length
            )
        } catch {
            try? handle.close()
            throw error
        }
    }

    // MARK: - Writing

    /// Appends `chunk` to the file `device`'s want is filling.
    func write(_ chunk: Chunk, from sender: Sender) -> WriteResult {
        let device = sender.device
        guard owners[device] == sender.session, var file = open[device] else { return .ignored }
        guard chunk.offset == file.length, file.length + Int64(chunk.bytes.count) <= file.file.size else {
            LinkLog.inbox.notice("Chunk at \(chunk.offset) of \(file.file.path, privacy: .public) does not follow \(file.length); asking again")
            close(device: device)
            return .again
        }
        do {
            try file.handle.write(contentsOf: chunk.bytes)
        } catch {
            LinkLog.inbox.error("Writing \(file.file.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            close(device: device)
            return .again
        }
        file.hasher.update(data: chunk.bytes)
        file.length += Int64(chunk.bytes.count)
        incoming[device]?[file.recording]?.held[file.file.path] = file.length
        open[device] = file
        if file.length == file.file.size {
            return finish(device: device)
        }
        guard file.length - file.acknowledged >= LinkPolicy.ackInterval else { return .written(nil, nil) }
        Self.fullSync(file.handle)
        open[device]?.acknowledged = file.length
        let stored = Stored(recording: file.recording, path: file.file.path, bytes: file.length, isVerified: false)
        return .written(stored, finalArrival(file.recording, of: device))
    }

    /// The open file is whole: synced, its hash compared, renamed or started over.
    private func finish(device: LinkDeviceID) -> WriteResult {
        guard let file = open.removeValue(forKey: device) else { return .ignored }
        Self.fullSync(file.handle)
        try? file.handle.close()
        let digest = file.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let key = "\(device)/\(file.recording)/\(file.file.path)"
        let fileManager = FileManager.default
        guard digest == file.file.sha256 else {
            try? fileManager.removeItem(at: file.partURL)
            incoming[device]?[file.recording]?.held[file.file.path] = 0
            let count = (mismatches[key] ?? 0) + 1
            mismatches[key] = count
            guard count < 2 else {
                LinkLog.inbox.error("\(file.file.path, privacy: .public) of \(file.recording.uuidString, privacy: .public) failed its hash twice; refused")
                discard(file.recording, of: device)
                return .refused(file.recording)
            }
            LinkLog.inbox.notice("\(file.file.path, privacy: .public) of \(file.recording.uuidString, privacy: .public) failed its hash; starting it over")
            return .again
        }
        do {
            if fileManager.fileExists(atPath: file.finalURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: file.finalURL)
            }
            try fileManager.moveItem(at: file.partURL, to: file.finalURL)
        } catch {
            LinkLog.inbox.error("Keeping \(file.file.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return .again
        }
        mismatches[key] = nil
        incoming[device]?[file.recording]?.verified.insert(file.file.path)
        incoming[device]?[file.recording]?.held[file.file.path] = file.file.size
        let stored = Stored(recording: file.recording, path: file.file.path, bytes: file.file.size, isVerified: true)
        return .verified(stored, finalArrival(file.recording, of: device))
    }

    /// Syncs and closes the open file, keeping what it holds.
    private func close(device: LinkDeviceID) {
        guard let file = open.removeValue(forKey: device) else { return }
        Self.fullSync(file.handle)
        try? file.handle.close()
        incoming[device]?[file.recording]?.held[file.file.path] = file.length
    }

    private func finalArrival(_ recording: RecordingID, of device: LinkDeviceID) -> Arrival? {
        guard let state = incoming[device]?[recording], state.offer.isFinal else { return nil }
        return state.arrival
    }

    // MARK: - Completion

    /// A recording of `device` whose final offer's files are all whole and checked.
    func completeRecording(of sender: Sender) -> RecordingID? {
        let device = sender.device
        guard owners[device] == sender.session else { return nil }
        return (order[device] ?? []).first { incoming[device]?[$0]?.isComplete == true }
    }

    /// Checks the complete `recording` as a package and moves it into `Recordings/`.
    func complete(_ recording: RecordingID, of sender: Sender) -> Completion {
        let device = sender.device
        guard owners[device] == sender.session, let state = incoming[device]?[recording], state.isComplete else { return .failed }
        let folder = staging(recording, of: device)
        removeStrays(in: folder, keeping: Set(state.offer.files.map(\.path)))
        do {
            let contents = try LecturePackageReader.read(LecturePackage(url: folder))
            let format = contents.manifest.fileFormat
            guard contents.manifest.id == recording.rawValue, state.offer.files.contains(where: { $0.path == "manifest.json" }),
                  state.offer.files.allSatisfy({ file in
                      InboxRules.segmentSequence(file.path).map {
                          file.path == LecturePackage.segmentRelativePath(sequence: $0, fileExtension: format)
                      } ?? true
                  })
            else {
                throw LecturePackageError.missingManifest(folder.lastPathComponent)
            }
        } catch {
            LinkLog.inbox.error("\(recording.uuidString, privacy: .public) is not a whole recording; refused: \(String(describing: error), privacy: .public)")
            discard(recording, of: device)
            return .refused
        }
        let fileManager = FileManager.default
        let destination = destination(of: recording)
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            discard(recording, of: device)
            return .known
        }
        do {
            try fileManager.createDirectory(at: services.paths.recordings, withIntermediateDirectories: true)
            try fileManager.moveItem(at: folder, to: destination)
        } catch {
            LinkLog.inbox.error("Moving \(recording.uuidString, privacy: .public) into Recordings failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
        incoming[device]?[recording] = nil
        order[device]?.removeAll { $0 == recording }
        LinkLog.inbox.notice("\(recording.uuidString, privacy: .public) arrived")
        return .kept(destination)
    }

    /// Deletes anything in `folder` that is not an offered file or a folder holding one.
    private func removeStrays(in folder: URL, keeping paths: Set<String>) {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey]
        for item in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? [] {
            let name = item.lastPathComponent
            if (try? item.resourceValues(forKeys: Set(keys)).isDirectory) == true {
                for inner in (try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                where !paths.contains("\(name)/\(inner.lastPathComponent)") {
                    try? fileManager.removeItem(at: inner)
                }
            } else if !paths.contains(name) {
                try? fileManager.removeItem(at: item)
            }
        }
    }

    // MARK: - Files

    private static func partURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).part", directoryHint: .notDirectory)
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize
        else { return nil }
        return Int64(size)
    }

    /// Bytes on the storage itself, not only in the drive's cache (`F_FULLFSYNC`); a plain fsync
    /// where that is refused.
    private static func fullSync(_ handle: FileHandle) {
        if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 {
            try? handle.synchronize()
        }
    }

    private func hasRoom(for bytes: Int64) -> Bool {
        guard let values = try? services.paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return true }
        return available >= bytes + LinkPolicy.diskReserve
    }

    private func newestModification(in folder: URL) -> Date {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var newest = (try? folder.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return newest }
        while let url = enumerator.nextObject() as? URL {
            if let date = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate, date > newest {
                newest = date
            }
        }
        return newest
    }
}
