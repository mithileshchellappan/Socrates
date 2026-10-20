import CryptoKit
import Foundation

/// A downloaded (or partly downloaded) model repo.
public struct InstalledTranslationModel: Hashable, Sendable {
    public var repository: String
    /// Bytes on disk, partial files included.
    public var bytes: Int64
    /// Every file is there and verified.
    public var isComplete: Bool
}

/// Where the OPUS-MT models live and how they get there.
///
/// `~/Library/Application Support/StudyPortal/Models/Translation/<owner>/<repo>/` (iOS: the app
/// container's equivalent), excluded from backups. Like `WhisperModelStore.shared()`, it ignores
/// `STUDYPORTAL_DATA_ROOT`: models are a shared, re-downloadable cache, not library data. Each repo
/// folder holds the six files the engine reads, `manifest.json` (the revision and each file's
/// size and hash) and a `.complete` marker written last.
public struct TranslationModelStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var sharedDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "StudyPortal", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
            .appending(path: "Translation", directoryHint: .isDirectory)
    }

    public static let shared = TranslationModelStore(directory: sharedDirectory)

    static let encoderFile = "onnx/encoder_model_quantized.onnx"
    static let decoderFile = "onnx/decoder_model_merged_quantized.onnx"
    /// What a repo needs on disk. Not fetched: `tokenizer.json` (it segments differently from
    /// `source.spm`), `target.spm` (decoding goes through `vocab.json`), other precisions.
    static let files: [String] = [
        "config.json", "generation_config.json", "vocab.json", "source.spm", encoderFile, decoderFile,
    ]
    /// Revisions checked when the plan was written (docs/plan-translation.md §3.2); other repos
    /// follow `main`.
    static let pinnedRevisions: [String: String] = [
        "Xenova/opus-mt-de-en": "399dfd68706739fffd503f876093e455ae268a06",
        "Xenova/opus-mt-en-de": "1ca130c44c4c5441ef16d48aae521a424ab644f7",
    ]
    static let manifestName = "manifest.json"
    static let completeMarker = ".complete"
    static let bufferSize = 1 << 20
    /// Free space kept beyond the download itself.
    static let spareBytes: Int64 = 50 * 1024 * 1024

    /// No URL cache (the files are 50 MB each), 60 s per request.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }()

    public func folder(for repository: String) -> URL {
        directory.appending(path: repository, directoryHint: .isDirectory)
    }

    func fileURL(_ path: String, in repository: String) -> URL {
        folder(for: repository).appending(path: path, directoryHint: .notDirectory)
    }

    // MARK: State

    /// The repo can be loaded without the network: the marker exists and every file of the
    /// manifest is there with its size.
    public func isReady(_ repository: String) -> Bool {
        let folder = folder(for: repository)
        let marker = folder.appending(path: Self.completeMarker, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) else { return false }
        guard let manifest = readManifest(in: folder) else { return false }
        var paths: Set<String> = []
        for file in manifest.files {
            let url = folder.appending(path: file.path, directoryHint: .notDirectory)
            guard let size = Self.fileSize(url), size == file.size else { return false }
            paths.insert(file.path)
        }
        return Self.files.allSatisfy { paths.contains($0) }
    }

    /// Forgets that the repo finished downloading (a model ONNX Runtime could not open), so the
    /// next download checks every file against the manifest, offline, and fetches only those
    /// that fail.
    public func invalidate(_ repository: String) {
        let marker = folder(for: repository).appending(path: Self.completeMarker, directoryHint: .notDirectory)
        try? FileManager.default.removeItem(at: marker)
    }

    public func remove(_ repository: String) throws {
        let folder = folder(for: repository)
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Every repo folder on disk, complete or not, with its bytes.
    public func installed() -> [InstalledTranslationModel] {
        let manager = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        guard let owners = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: options) else {
            return []
        }
        var models: [InstalledTranslationModel] = []
        for owner in owners where Self.isDirectory(owner) {
            guard let repos = try? manager.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil, options: options) else {
                continue
            }
            for repo in repos where Self.isDirectory(repo) {
                let name = "\(owner.lastPathComponent)/\(repo.lastPathComponent)"
                let model = InstalledTranslationModel(repository: name, bytes: Self.directorySize(repo), isComplete: isReady(name))
                models.append(model)
            }
        }
        return models.sorted { $0.repository < $1.repository }
    }

    /// Creates the directory and marks it as excluded from backups.
    public func createDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    // MARK: Download

    /// Fetches whatever the repo still misses, verifies it and writes the manifest and marker.
    /// `progress(done, total)` gets the repo's bytes, never going backwards, at most about 10
    /// times a second; a repo that only needed checking (offline) reports nothing. Partial files
    /// resume with a `Range` request.
    public func download(_ repository: String, progress: @Sendable (Int64, Int64) -> Void) async throws {
        if isReady(repository) { return }
        do {
            try await fetchMissing(repository, progress: progress)
        } catch let error as TranslationError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            TranslationLog.logger.error("Model download failed: \(error.localizedDescription, privacy: .public)")
            throw TranslationError.downloadFailed(error.localizedDescription)
        }
    }

    /// Makes the repo complete again. When `manifest.json` already lists every file's size and
    /// hash (a repo invalidated after a load error, or an interrupted download), the files on
    /// disk are checked against it first, offline: if all verify, the marker is written back and
    /// no request is made. Otherwise only the files that fail are fetched (the file list is asked
    /// for again only when there is no usable manifest, or it follows a branch, not a commit).
    private func fetchMissing(_ repository: String, progress: @Sendable (Int64, Int64) -> Void) async throws {
        let folder = folder(for: repository)
        var revision = Self.pinnedRevisions[repository] ?? "main"
        // Each file is hashed at most once per attempt.
        var checked: [TranslationManifest.File: Bool] = [:]
        func verifies(_ file: TranslationManifest.File) throws -> Bool {
            if let known = checked[file] { return known }
            let result = try Self.verifiesOnDisk(file, in: folder)
            checked[file] = result
            return result
        }

        var files: [TranslationManifest.File] = []
        if let manifest = usableManifest(for: repository, in: folder) {
            var allVerify = true
            for file in manifest.files {
                let verified: Bool = try verifies(file)
                if !verified { allVerify = false }
            }
            if allVerify {
                try writeMarker(revision: manifest.revision, in: folder)
                TranslationLog.logger.info("Verified \(repository, privacy: .public) offline")
                return
            }
            if Self.isCommit(manifest.revision) {
                revision = manifest.revision
                files = manifest.files
            }
        }
        if files.isEmpty {
            TranslationLog.logger.info("Listing \(repository, privacy: .public) at \(revision, privacy: .public)")
            let entries = try await Self.withRetry {
                try await fetchTree(repository, revision: revision)
            }
            files = try Self.listedFiles(entries, repository: repository)
        }

        try createDirectory()
        try FileManager.default.createDirectory(
            at: folder.appending(path: "onnx", directoryHint: .isDirectory), withIntermediateDirectories: true
        )
        invalidate(repository)

        // What verifies stays; the space needed is only what is still missing.
        var total: Int64 = 0
        var completed: Int64 = 0
        var pending: [TranslationManifest.File] = []
        for file in files {
            total += file.size
            if try verifies(file) {
                completed += file.size
            } else {
                pending.append(file)
            }
        }
        removeLeftovers(pending: pending, in: folder)
        var missing: Int64 = 0
        for file in pending {
            let destination = folder.appending(path: file.path, directoryHint: .notDirectory)
            let resumable: Int64 = Self.fileSize(Self.partialURL(for: destination)) ?? 0
            missing += max(0, file.size - resumable)
        }
        try checkSpace(needed: missing + Self.spareBytes)
        TranslationLog.logger.info("Downloading \(pending.count) files of \(repository, privacy: .public) (\(missing) bytes)")

        var reported: Int64 = -1
        var lastReport = ContinuousClock.now - .seconds(1)
        func report(_ fileBytes: Int64) {
            let done: Int64 = min(total, completed + fileBytes)
            guard done > reported else { return }
            let now = ContinuousClock.now
            guard done == total || now - lastReport >= .milliseconds(100) else { return }
            reported = done
            lastReport = now
            progress(done, total)
        }
        report(0)

        for file in pending {
            try Task.checkCancellation()
            let destination = folder.appending(path: file.path, directoryHint: .notDirectory)
            try await Self.withRetry {
                try await fetch(file, repository: repository, revision: revision, to: destination, onBytes: report)
            }
            completed += file.size
            report(0)
        }

        let manifest = TranslationManifest(repository: repository, revision: revision, files: files)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: folder.appending(path: Self.manifestName, directoryHint: .notDirectory), options: .atomic)
        try writeMarker(revision: revision, in: folder)
        TranslationLog.logger.info("Downloaded \(repository, privacy: .public) (\(missing) of \(total) bytes)")
    }

    /// The manifest on disk when it can stand in for the file list: this repo, every file the
    /// engine reads with a size and a hash, and the pinned revision when there is one. Its files
    /// come in `files` order.
    private func usableManifest(for repository: String, in folder: URL) -> TranslationManifest? {
        guard var manifest = readManifest(in: folder), manifest.repository == repository else { return nil }
        if let pinned = Self.pinnedRevisions[repository], manifest.revision != pinned { return nil }
        var files: [TranslationManifest.File] = []
        for path in Self.files {
            guard let file = manifest.files.first(where: { $0.path == path }), file.size > 0 else { return nil }
            let hash = file.sha256 ?? file.gitOID ?? ""
            guard !hash.isEmpty else { return nil }
            files.append(file)
        }
        manifest.files = files
        return manifest
    }

    /// The engine's files from the Hugging Face file list, with their sizes and hashes.
    private static func listedFiles(_ entries: [TreeEntry], repository: String) throws -> [TranslationManifest.File] {
        var files: [TranslationManifest.File] = []
        for path in Self.files {
            guard let entry = entries.first(where: { $0.path == path && $0.type == "file" }) else {
                throw TranslationError.modelUnreadable("\(repository) has no \(path)")
            }
            let file: TranslationManifest.File
            if let lfs = entry.lfs {
                file = TranslationManifest.File(path: path, size: lfs.size, sha256: lfs.oid.lowercased(), gitOID: nil)
            } else {
                file = TranslationManifest.File(path: path, size: entry.size, sha256: nil, gitOID: entry.oid?.lowercased())
            }
            files.append(file)
        }
        return files
    }

    /// The file is in place with its listed size and hash.
    private static func verifiesOnDisk(_ file: TranslationManifest.File, in folder: URL) throws -> Bool {
        let destination = folder.appending(path: file.path, directoryHint: .notDirectory)
        guard let size = fileSize(destination), size == file.size else { return false }
        var verifier = FileVerifier(file)
        try verifier.absorb(contentsOf: destination)
        return verifier.matches()
    }

    /// Clears what a failed download left behind: the files that did not verify, and every
    /// `.partial` file that cannot resume (its file is no longer pending, or it is longer than
    /// the file). A partial download of a pending file stays and resumes.
    private func removeLeftovers(pending: [TranslationManifest.File], in folder: URL) {
        let manager = FileManager.default
        var resumable: [String: Int64] = [:]
        for file in pending {
            let destination = folder.appending(path: file.path, directoryHint: .notDirectory)
            if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try? manager.removeItem(at: destination)
            }
            resumable[Self.pathKey(Self.partialURL(for: destination))] = file.size
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = manager.enumerator(at: folder, includingPropertiesForKeys: keys) else { return }
        var orphans: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent.hasSuffix(".partial") else { continue }
            if let expected = resumable[Self.pathKey(url)], let size = Self.fileSize(url), size <= expected { continue }
            orphans.append(url)
        }
        for url in orphans {
            TranslationLog.logger.info("Removing the leftover \(url.lastPathComponent, privacy: .public)")
            try? manager.removeItem(at: url)
        }
    }

    private func writeMarker(revision: String, in folder: URL) throws {
        let marker = folder.appending(path: Self.completeMarker, directoryHint: .notDirectory)
        try Data(revision.utf8).write(to: marker, options: .atomic)
    }

    /// Where a file downloads to before it verifies.
    static func partialURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appending(path: "\(destination.lastPathComponent).partial", directoryHint: .notDirectory)
    }

    /// A path to compare files by, whatever symlinks led to it.
    private static func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    /// A 40-digit commit hash, which never moves (unlike a branch such as `main`).
    static func isCommit(_ revision: String) -> Bool {
        revision.count == 40 && revision.allSatisfy { $0.isHexDigit }
    }

    private func fetchTree(_ repository: String, revision: String) async throws -> [TreeEntry] {
        let address = "https://huggingface.co/api/models/\(repository)/tree/\(revision)?recursive=1"
        guard let url = URL(string: address) else { throw TranslationError.downloadFailed("Bad address for \(repository)") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslationError.downloadFailed("No HTTP response") }
        guard http.statusCode == 200 else { throw DownloadStatusError(status: http.statusCode) }
        do {
            return try JSONDecoder().decode([TreeEntry].self, from: data)
        } catch {
            throw TranslationError.modelUnreadable("\(repository): unexpected file list")
        }
    }

    /// Streams one file into `<path>.partial` (resuming one that exists), verifies it and moves it
    /// into place. `onBytes` gets the bytes of this file on disk so far.
    private func fetch(
        _ file: TranslationManifest.File, repository: String, revision: String, to destination: URL, onBytes: (Int64) -> Void
    ) async throws {
        let manager = FileManager.default
        let partial = Self.partialURL(for: destination)
        let partialPath = partial.path(percentEncoded: false)
        let address = "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)"
        guard let url = URL(string: address) else { throw TranslationError.downloadFailed("Bad address for \(file.path)") }

        var verifier = FileVerifier(file)
        var offset: Int64 = 0
        if let size = Self.fileSize(partial) {
            if size > file.size {
                try? manager.removeItem(at: partial)
            } else {
                try verifier.absorb(contentsOf: partial)
                offset = size
            }
        }
        onBytes(offset)

        if offset < file.size {
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            let (bytes, response) = try await Self.session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw TranslationError.downloadFailed("No HTTP response") }
            let status = http.statusCode
            if status == 200 {
                // The server sent the whole file: start over.
                offset = 0
                verifier = FileVerifier(file)
            } else if status != 206 || offset == 0 {
                throw DownloadStatusError(status: status)
            }
            if !manager.fileExists(atPath: partialPath) {
                guard manager.createFile(atPath: partialPath, contents: nil) else {
                    throw TranslationError.downloadFailed("Could not create \(file.path).partial")
                }
            }
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            if offset == 0 {
                try handle.truncate(atOffset: 0)
            } else {
                try handle.seek(toOffset: UInt64(offset))
            }
            var written = offset
            var buffer: [UInt8] = []
            buffer.reserveCapacity(Self.bufferSize)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= Self.bufferSize {
                    try handle.write(contentsOf: buffer)
                    verifier.update(buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    guard written <= file.size else { throw TranslationError.downloadFailed("\(file.path) is larger than listed") }
                    onBytes(written)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                verifier.update(buffer)
                written += Int64(buffer.count)
                onBytes(written)
            }
            if written < file.size {
                // The connection ended early: a transient failure, resumed by the retry.
                throw DownloadStatusError(status: 0)
            }
        }

        guard Self.fileSize(partial) == file.size, verifier.matches() else {
            try? manager.removeItem(at: partial)
            throw TranslationError.downloadFailed("\(file.path) did not verify")
        }
        if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: partial, to: destination)
    }

    private func checkSpace(needed: Int64) throws {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        if available < needed { throw TranslationError.notEnoughSpace }
    }

    private func readManifest(in folder: URL) -> TranslationManifest? {
        let url = folder.appending(path: Self.manifestName, directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TranslationManifest.self, from: data)
    }

    // MARK: Helpers

    /// Retries transient network failures 5 times, waiting 1, 2, 4 and 8 s (local-translate's
    /// `withRetry`).
    static func withRetry<Value>(_ operation: () async throws -> Value) async throws -> Value {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                attempt += 1
                guard attempt < 5, isTransient(error) else { throw error }
                let delay = 1 << (attempt - 1)
                TranslationLog.logger.info("Network error (attempt \(attempt)/5): \(error.localizedDescription, privacy: .public)")
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    static func isTransient(_ error: any Error) -> Bool {
        if let status = error as? DownloadStatusError { return status.isTransient }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .resourceUnavailable, .badServerResponse, .secureConnectionFailed,
             .cannotLoadFromNetwork, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize else { return nil }
        return Int64(size)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        while let item = enumerator.nextObject() as? URL {
            if let size = fileSize(item) { total += size }
        }
        return total
    }
}

/// What `manifest.json` records for a repo.
struct TranslationManifest: Codable, Sendable {
    struct File: Codable, Hashable, Sendable {
        var path: String
        var size: Int64
        /// LFS files: the SHA-256 of the content.
        var sha256: String?
        /// Plain git blobs: the blob's SHA-1 (`"blob <size>\0"` + content).
        var gitOID: String?
    }

    var repository: String
    var revision: String
    var files: [File]
}

/// One entry of the Hugging Face tree API.
struct TreeEntry: Decodable, Sendable {
    struct LFS: Decodable, Sendable {
        var oid: String
        var size: Int64
    }

    var type: String
    var oid: String?
    var size: Int64
    var path: String
    var lfs: LFS?
}

/// An HTTP status other than the one expected (0: the body ended early).
struct DownloadStatusError: Error, LocalizedError {
    var status: Int

    var isTransient: Bool {
        status == 0 || status == 408 || status == 429 || status >= 500
    }

    var errorDescription: String? {
        status == 0 ? "The connection ended early" : "HTTP \(status)"
    }
}

/// SHA-256 for LFS files, git blob SHA-1 for the small ones.
struct FileVerifier {
    private var sha256: SHA256?
    private var sha1: Insecure.SHA1?
    private let expected: String

    init(_ file: TranslationManifest.File) {
        if let digest = file.sha256 {
            sha256 = SHA256()
            sha1 = nil
            expected = digest
        } else {
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(file.size)\0".utf8))
            sha1 = hasher
            sha256 = nil
            expected = file.gitOID ?? ""
        }
    }

    mutating func update<Bytes: DataProtocol>(_ bytes: Bytes) {
        sha256?.update(data: bytes)
        sha1?.update(data: bytes)
    }

    /// Hashes a partial file already on disk, 1 MB at a time.
    mutating func absorb(contentsOf url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: TranslationModelStore.bufferSize), !chunk.isEmpty {
            update(chunk)
        }
    }

    func matches() -> Bool {
        guard !expected.isEmpty else { return false }
        if let sha256 { return Self.hex(sha256.finalize()) == expected }
        if let sha1 { return Self.hex(sha1.finalize()) == expected }
        return false
    }

    private static func hex<Digest: Sequence>(_ digest: Digest) -> String where Digest.Element == UInt8 {
        let digits: [Character] = Array("0123456789abcdef")
        var text = ""
        for byte in digest {
            let high = Int(byte >> 4)
            let low = Int(byte & 0x0F)
            text.append(digits[high])
            text.append(digits[low])
        }
        return text
    }
}
