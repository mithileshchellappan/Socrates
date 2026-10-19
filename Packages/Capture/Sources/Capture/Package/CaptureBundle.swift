import AppleArchive
import Foundation
import System
import UniformTypeIdentifiers

/// One lecture package as a single file, for Share / AirDrop from the iPhone to the Mac (M7,
/// docs/plan-m7.md §4): an uncompressed Apple Archive of exactly one `<uuid>.lecture` folder.
///
///     DC Lecture 2.lecturebundle      (UTType com.example.studyportal.lecture-bundle)
///       <uuid>.lecture/                directory
///       <uuid>.lecture/manifest.json   first, so the Mac reads it without unpacking
///       <uuid>.lecture/events.json
///       <uuid>.lecture/notes.json
///       <uuid>.lecture/audio/          directory
///       <uuid>.lecture/audio/seg-0001.caf, …
///
/// Entries carry only a type (`TYP`: directory or regular file), a relative path (`PAT`) and a
/// file's bytes (`DAT`): no owners, modes, links or extended attributes. Audio is LPCM already,
/// so nothing is compressed and a 90-minute recording writes and unpacks at disk speed.
///
/// Unpacking trusts nothing in the file: links and any other entry type, absolute paths, `..`
/// and `.` components, a second root or a root that is not `<uuid>.lecture` are refused, and
/// it writes into a fresh hidden folder first, so a refused bundle leaves nothing behind.
public enum CaptureBundle {
    public static let pathExtension = "lecturebundle"
    public static let typeIdentifier = "com.example.studyportal.lecture-bundle"

    /// The bundle's type (declared by the app's Info.plist).
    public static var contentType: UTType {
        UTType(exportedAs: typeIdentifier, conformingTo: .archive)
    }

    public enum BundleError: Error, Equatable, Sendable, LocalizedError {
        /// Not a `<uuid>.lecture` folder with a manifest.
        case notAPackage(String)
        /// An entry that is neither a folder nor a regular file (a link, a device, …).
        case unsupportedEntry(String)
        /// An absolute path, `..` or `.`, or a path outside the root.
        case unsafePath(String)
        /// No root, or more than one.
        case notOneRoot
        /// Unpacking: the package is in the folder already.
        case alreadyExists(String)
        /// Not an Apple Archive, or cut short.
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .notAPackage(let name): String(localized: "“\(name)” is not a recording.")
            case .unsupportedEntry(let name), .unsafePath(let name): String(localized: "“\(name)” can’t be unpacked.")
            case .notOneRoot: String(localized: "The file holds no single recording.")
            case .alreadyExists(let name): String(localized: "“\(name)” is there already.")
            case .unreadable(let name): String(localized: "“\(name)” can’t be read.")
            }
        }
    }

    /// What a bundle says about its recording, read without unpacking it (smart import's
    /// evidence while files are dragged).
    public struct Summary: Sendable, Hashable {
        /// "<uuid>.lecture".
        public var packageName: String
        public var manifest: LectureManifest
        public var events: [LectureEvent]
        /// Seconds, from the manifest's segments (0 when it knows none).
        public var duration: TimeInterval
    }

    // MARK: - Writing

    /// Writes `package` as a bundle at `url` (replacing a file there) and returns `url`. The
    /// package is only read. Links inside it are refused.
    @discardableResult
    public static func write(package: LecturePackage, to url: URL) throws -> URL {
        let fileManager = FileManager.default
        guard package.id != nil, package.url.pathExtension == LecturePackage.pathExtension,
              fileManager.fileExists(atPath: package.manifestURL.path(percentEncoded: false))
        else { throw BundleError.notAPackage(package.name) }
        let entries = try entries(of: package)

        let partial = url.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString).partial", directoryHint: .notDirectory)
        defer { try? fileManager.removeItem(at: partial) }
        do {
            try ArchiveByteStream.withFileStream(
                path: FilePath(partial.path(percentEncoded: false)),
                mode: .writeOnly,
                options: [.create, .truncate],
                permissions: FilePermissions(rawValue: 0o644)
            ) { file in
                try ArchiveStream.withEncodeStream(writingTo: file) { encoder in
                    for entry in entries {
                        try write(entry, to: encoder)
                    }
                }
            }
        } catch let error as BundleError {
            throw error
        } catch {
            throw BundleError.unreadable(url.lastPathComponent)
        }
        if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: partial, to: url)
        return url
    }

    private struct Entry {
        var path: String
        var file: URL?
        var size: Int
    }

    /// The root folder, its files (manifest, events, notes first), then each subfolder and its
    /// files, recursively. Throws on a link or any other kind of entry.
    private static func entries(of package: LecturePackage) throws -> [Entry] {
        let root = package.name
        var entries = [Entry(path: root, file: nil, size: 0)]
        let first = ["manifest.json", "events.json", "notes.json"]
        func walk(_ folder: URL, path: String) throws {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            let contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
            var files: [(name: String, url: URL, size: Int)] = []
            var folders: [(name: String, url: URL)] = []
            for item in contents {
                let name = item.lastPathComponent
                let values = try item.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true {
                    throw BundleError.unsupportedEntry(name)
                } else if values.isRegularFile == true {
                    files.append((name, item, values.fileSize ?? 0))
                } else if values.isDirectory == true {
                    folders.append((name, item))
                } else {
                    throw BundleError.unsupportedEntry(name)
                }
            }
            files.sort { lhs, rhs in
                let left = first.firstIndex(of: lhs.name) ?? first.count
                let right = first.firstIndex(of: rhs.name) ?? first.count
                return left == right ? lhs.name < rhs.name : left < right
            }
            for file in files {
                entries.append(Entry(path: "\(path)/\(file.name)", file: file.url, size: file.size))
            }
            for sub in folders.sorted(by: { $0.name < $1.name }) {
                entries.append(Entry(path: "\(path)/\(sub.name)", file: nil, size: 0))
                try walk(sub.url, path: "\(path)/\(sub.name)")
            }
        }
        try walk(package.url, path: root)
        return entries
    }

    private static func write(_ entry: Entry, to encoder: ArchiveStream) throws {
        let header = ArchiveHeader()
        guard let file = entry.file else {
            header.append(.uint(key: Key.type, value: UInt64(ArchiveHeader.EntryType.directory.rawValue)))
            header.append(.string(key: Key.path, value: entry.path))
            try encoder.writeHeader(header)
            return
        }
        header.append(.uint(key: Key.type, value: UInt64(ArchiveHeader.EntryType.regularFile.rawValue)))
        header.append(.string(key: Key.path, value: entry.path))
        header.append(.blob(key: Key.data, size: UInt64(entry.size)))
        try encoder.writeHeader(header)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var remaining = entry.size
        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: min(chunkSize, remaining)), !chunk.isEmpty else {
                throw BundleError.unreadable(file.lastPathComponent)
            }
            try chunk.withUnsafeBytes { try encoder.writeBlob(key: Key.data, from: $0) }
            remaining -= chunk.count
        }
    }

    // MARK: - Unpacking

    /// Unpacks the bundle at `url` into `directory` (which must exist) and returns the package
    /// (`directory/<uuid>.lecture`). The bundle is only read. Refuses unsafe or foreign entries
    /// (see the type's notes) and a package already in `directory`; nothing is left on failure.
    public static func unpack(_ url: URL, into directory: URL) throws -> LecturePackage {
        let fileManager = FileManager.default
        let staging = directory.appending(path: ".unpack-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }

        var root: String?
        var seen: Set<String> = []
        try decode(url) { header, decoder in
            let (type, path, components) = try validated(header, root: &root)
            guard seen.insert(path).inserted else { throw BundleError.unsafePath(path) }
            let target = components.reduce(staging) { $0.appending(path: $1, directoryHint: .inferFromPath) }
            switch type {
            case .directory:
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            default:
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fileManager.createFile(atPath: target.path(percentEncoded: false), contents: nil) else {
                    throw BundleError.unreadable(path)
                }
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                var remaining = blobSize(header)
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                while remaining > 0 {
                    let count = min(chunkSize, remaining)
                    try buffer.withUnsafeMutableBytes { raw in
                        try decoder.readBlob(key: Key.data, into: UnsafeMutableRawBufferPointer(rebasing: raw[0..<count]))
                    }
                    try handle.write(contentsOf: buffer[0..<count])
                    remaining -= count
                }
            }
            return true
        }
        guard let root else { throw BundleError.notOneRoot }
        let destination = directory.appending(path: root, directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw BundleError.alreadyExists(root)
        }
        try fileManager.moveItem(at: staging.appending(path: root, directoryHint: .isDirectory), to: destination)
        return LecturePackage(url: destination)
    }

    /// The bundle's manifest and events, read without unpacking (its first entries).
    public static func summary(of url: URL) throws -> Summary {
        var root: String?
        var manifest: LectureManifest?
        var events: [LectureEvent]?
        try decode(url) { header, decoder in
            let (type, path, _) = try validated(header, root: &root)
            guard type == .regularFile, let root else { return true }
            if path == "\(root)/manifest.json" {
                manifest = try CaptureJSON.decode(LectureManifest.self, from: readSmallBlob(header, decoder))
            } else if path == "\(root)/events.json" {
                events = try CaptureJSON.decode(LectureEventLog.self, from: readSmallBlob(header, decoder)).events
            }
            return manifest == nil || events == nil
        }
        guard let root, let manifest else { throw BundleError.notAPackage(url.lastPathComponent) }
        let end = manifest.segments.compactMap(\.endSample).max() ?? 0
        return Summary(
            packageName: root,
            manifest: manifest,
            events: (events ?? []).sorted(by: LecturePackageReader.eventOrder),
            duration: manifest.sampleRate > 0 ? Double(end) / manifest.sampleRate : 0
        )
    }

    // MARK: - Temporary bundles (Share)

    /// Where Share writes bundles: the system's temporary folder, one subfolder per share.
    public static var temporaryDirectory: URL {
        URL.temporaryDirectory.appending(path: "CaptureBundles", directoryHint: .isDirectory)
    }

    /// Removes shared bundles older than `age` seconds (0: all). Shares in flight are younger.
    public static func removeTemporaryBundles(olderThan age: TimeInterval) {
        let fileManager = FileManager.default
        let folders = (try? fileManager.contentsOfDirectory(
            at: temporaryDirectory, includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        let cutoff = Date().addingTimeInterval(-age)
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if age <= 0 || created < cutoff { try? fileManager.removeItem(at: folder) }
        }
    }

    /// "DC Lecture 2.lecturebundle" for "DC Lecture 2" (no path separators, never empty).
    public static func fileName(for title: String) -> String {
        let cleaned = title
            .replacing("/", with: "-")
            .replacing(":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return "\(cleaned.isEmpty ? "Recording" : cleaned).\(pathExtension)"
    }

    // MARK: - Private

    private enum Key {
        static var type: ArchiveHeader.FieldKey { ArchiveHeader.FieldKey("TYP") }
        static var path: ArchiveHeader.FieldKey { ArchiveHeader.FieldKey("PAT") }
        static var data: ArchiveHeader.FieldKey { ArchiveHeader.FieldKey("DAT") }
    }

    private static let chunkSize = 1 << 20
    /// Manifest and event logs are small; anything larger is not ours.
    private static let smallBlobLimit = 32 << 20

    /// Calls `body` for each entry until it returns false; Apple Archive errors become `unreadable`.
    private static func decode(_ url: URL, _ body: (ArchiveHeader, ArchiveStream) throws -> Bool) throws {
        do {
            try ArchiveByteStream.withFileStream(
                path: FilePath(url.path(percentEncoded: false)),
                mode: .readOnly,
                options: [],
                permissions: FilePermissions(rawValue: 0o644)
            ) { file in
                try ArchiveStream.withDecodeStream(readingFrom: file) { decoder in
                    while let header = try decoder.readHeader() {
                        guard try body(header, decoder) else { break }
                    }
                }
            }
        } catch let error as BundleError {
            throw error
        } catch let error as CocoaError {
            throw error
        } catch {
            throw BundleError.unreadable(url.lastPathComponent)
        }
    }

    /// The entry's type, path and path components, or a refusal: only folders and regular files,
    /// relative paths without `..` or `.`, all under one `<uuid>.lecture` root.
    private static func validated(
        _ header: ArchiveHeader, root: inout String?
    ) throws -> (ArchiveHeader.EntryType, String, [String]) {
        guard let path = header.entryPath?.string, !path.isEmpty else { throw BundleError.unsafePath("") }
        guard let type = header.entryType, type == .directory || type == .regularFile else {
            throw BundleError.unsupportedEntry(path)
        }
        guard !path.hasPrefix("/"), !path.contains("\0") else { throw BundleError.unsafePath(path) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw BundleError.unsafePath(path)
        }
        let first = components[0]
        if let root {
            guard first == root else { throw BundleError.notOneRoot }
        } else {
            let package = LecturePackage(url: URL(filePath: "/").appending(path: first, directoryHint: .isDirectory))
            guard package.id != nil, package.url.pathExtension == LecturePackage.pathExtension else {
                throw BundleError.notOneRoot
            }
            root = first
        }
        // The root is a folder: a file named like it would be a second, different root.
        if components.count == 1, type != .directory { throw BundleError.notOneRoot }
        return (type, path, components)
    }

    private static func blobSize(_ header: ArchiveHeader) -> Int {
        guard case .blob(_, let size, _)? = header.field(forKey: Key.data) else { return 0 }
        return Int(clamping: size)
    }

    private static func readSmallBlob(_ header: ArchiveHeader, _ decoder: ArchiveStream) throws -> Data {
        let size = blobSize(header)
        guard size <= smallBlobLimit else { throw BundleError.unreadable(header.entryPath?.string ?? "") }
        var data = Data(count: size)
        guard size > 0 else { return data }
        try data.withUnsafeMutableBytes { try decoder.readBlob(key: Key.data, into: $0) }
        return data
    }
}
