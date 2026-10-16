import Foundation

/// Where the app keeps its files.
///
/// Live layout (unsandboxed Mac: `~/Library/Application Support/StudyPortal`; iOS: the app
/// container's `Library/Application Support/StudyPortal`):
///
///     StudyPortal/
///       Database/StudyPortal.sqlite   SQLite (WAL)
///       Blobs/ab/abcdef….pdf          content-addressed files (BlobStore)
///       Models/                       WhisperKit and other models (excluded from backup)
///       Recordings/                   in-progress capture files before they enter Blobs
///
/// Caches (slide bitmaps, …) live in the system caches directory and may be purged.
/// Never use ~/Documents: it syncs to iCloud.
public struct AppPaths: Hashable, Sendable {
    public let root: URL
    public let caches: URL

    public init(root: URL, caches: URL? = nil) {
        self.root = root
        self.caches = caches ?? root.appending(path: "Caches", directoryHint: .isDirectory)
    }

    public static let folderName = "StudyPortal"

    /// Environment variable that relocates all app data to an absolute directory, so test runs
    /// and parallel agents never touch the real library.
    public static let rootOverrideVariable = "STUDYPORTAL_DATA_ROOT"

    /// The real locations for this device (or `$STUDYPORTAL_DATA_ROOT` when set).
    public static func live(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AppPaths {
        if let override = environment[rootOverrideVariable], override.hasPrefix("/") {
            return AppPaths(root: URL(filePath: override, directoryHint: .isDirectory))
        }
        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let caches = try fileManager.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return AppPaths(
            root: support.appending(path: folderName, directoryHint: .isDirectory),
            caches: caches.appending(path: Log.subsystem, directoryHint: .isDirectory)
        )
    }

    public var databaseDirectory: URL { root.appending(path: "Database", directoryHint: .isDirectory) }
    public var database: URL { databaseDirectory.appending(path: "StudyPortal.sqlite") }
    public var blobs: URL { root.appending(path: "Blobs", directoryHint: .isDirectory) }
    public var models: URL { root.appending(path: "Models", directoryHint: .isDirectory) }
    public var recordings: URL { root.appending(path: "Recordings", directoryHint: .isDirectory) }

    /// Creates all directories. Models and caches are excluded from device backups.
    public func createDirectories(fileManager: FileManager = .default) throws {
        for directory in [root, databaseDirectory, blobs, models, recordings, caches] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for directory in [models, caches] {
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        }
    }
}
