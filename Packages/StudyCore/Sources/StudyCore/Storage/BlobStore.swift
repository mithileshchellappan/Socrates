import CryptoKit
import Foundation

/// A reference to a file in the `BlobStore`. The database stores `sha256` and `relativePath`.
public struct BlobRef: Hashable, Sendable, Codable {
    /// Lowercase hex SHA-256 of the file contents.
    public let sha256: String
    /// Path relative to the store root: `ab/abcdef….ext`.
    public let relativePath: String
    public let byteCount: Int64?

    public init(sha256: String, relativePath: String, byteCount: Int64? = nil) {
        self.sha256 = sha256
        self.relativePath = relativePath
        self.byteCount = byteCount
    }

    public var fileExtension: String { (relativePath as NSString).pathExtension }
}

public enum BlobStoreError: Error, Equatable, Sendable {
    case notAFile(String)
    case missing(String)
}

/// Content-addressed file store: identical contents are stored once, under their SHA-256.
///
/// Files are written to a temporary name and atomically moved into place, so readers never
/// see a partial blob. Methods do blocking file I/O; call them off the main actor for large
/// files (audio, video).
public struct BlobStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Stores `data`, returning its reference. Idempotent.
    public func put(_ data: Data, fileExtension: String = "") throws -> BlobRef {
        let digest = Self.hex(SHA256.hash(data: data))
        let ref = Self.ref(digest: digest, fileExtension: fileExtension, byteCount: Int64(data.count))
        let destination = url(for: ref)
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            return ref
        }
        let temporary = try temporaryURL()
        try data.write(to: temporary, options: .atomic)
        try moveIntoPlace(temporary, destination: destination)
        return ref
    }

    public enum ImportMode: Sendable {
        /// Leave the source file where it is.
        case copy
        /// Move the source file into the store (same volume: no copy).
        case move
    }

    /// Stores the file at `source`, hashing it in chunks (safe for multi-GB recordings).
    /// The extension of `source` is kept so players can infer the container type.
    public func importFile(at source: URL, mode: ImportMode = .copy) throws -> BlobRef {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw BlobStoreError.notAFile(source.path(percentEncoded: false))
        }
        let digest = try Self.sha256(of: source)
        let ref = Self.ref(
            digest: digest,
            fileExtension: source.pathExtension,
            byteCount: values.fileSize.map(Int64.init)
        )
        let destination = url(for: ref)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            if mode == .move { try fileManager.removeItem(at: source) }
            return ref
        }
        let temporary = try temporaryURL(fileExtension: source.pathExtension)
        switch mode {
        case .copy: try fileManager.copyItem(at: source, to: temporary)
        case .move: try fileManager.moveItem(at: source, to: temporary)
        }
        try moveIntoPlace(temporary, destination: destination)
        return ref
    }

    public func url(for ref: BlobRef) -> URL {
        url(forRelativePath: ref.relativePath)
    }

    public func url(forRelativePath relativePath: String) -> URL {
        root.appending(path: relativePath, directoryHint: .notDirectory)
    }

    public func contains(_ ref: BlobRef) -> Bool {
        FileManager.default.fileExists(atPath: url(for: ref).path(percentEncoded: false))
    }

    public func data(for ref: BlobRef) throws -> Data {
        guard contains(ref) else { throw BlobStoreError.missing(ref.relativePath) }
        return try Data(contentsOf: url(for: ref), options: .mappedIfSafe)
    }

    /// Removes a blob. Callers must make sure no row references it any more.
    public func remove(_ ref: BlobRef) throws {
        let target = url(for: ref)
        if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: target)
        }
    }

    // MARK: - Hashing

    /// Streaming SHA-256 of a file, lowercase hex.
    public static func sha256(of url: URL, chunkSize: Int = 4 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func ref(digest: String, fileExtension: String, byteCount: Int64?) -> BlobRef {
        let ext = fileExtension.lowercased()
        let name = ext.isEmpty ? digest : "\(digest).\(ext)"
        return BlobRef(sha256: digest, relativePath: "\(digest.prefix(2))/\(name)", byteCount: byteCount)
    }

    // MARK: - Private

    private func temporaryURL(fileExtension: String = "") throws -> URL {
        let directory = root.appending(path: ".tmp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = fileExtension.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(fileExtension)"
        return directory.appending(path: name)
    }

    private func moveIntoPlace(_ temporary: URL, destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch CocoaError.fileWriteFileExists {
            // Another writer stored the same contents first; ours is redundant.
            try? fileManager.removeItem(at: temporary)
        }
    }
}
