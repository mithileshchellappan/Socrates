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
///       PhoneCaptures/                iPhone (M7): its recordings as `.lecture` packages until shared
///       Agent/                        the Claude Code backend (M3.5): Workspace/, state.json, Runs/
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
    public static let rootOverrideVariable = "SOCRATES_DATA_ROOT"
    /// The same variable under the app's name before the rename, still honoured when
    /// `SOCRATES_DATA_ROOT` is not set.
    public static let legacyRootOverrideVariable = "STUDYPORTAL_DATA_ROOT"

    /// The absolute folder `$SOCRATES_DATA_ROOT` (else `$STUDYPORTAL_DATA_ROOT`) names, if any.
    public static func rootOverride(in environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        for variable in [rootOverrideVariable, legacyRootOverrideVariable] {
            if let value = environment[variable], value.hasPrefix("/") {
                return URL(filePath: value, directoryHint: .isDirectory)
            }
        }
        return nil
    }

    /// The real locations for this device (or `$SOCRATES_DATA_ROOT` when set).
    public static func live(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AppPaths {
        if let override = rootOverride(in: environment) {
            return AppPaths(root: override)
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
    /// M7, the iPhone with iCloud sync: a library of its own, filled by the Mac's rows. The phone's
    /// library from before sync (its own seeded courses) stays in `database` and never uploads.
    public var syncedDatabase: URL { databaseDirectory.appending(path: "StudyPortal-synced.sqlite") }
    public var blobs: URL { root.appending(path: "Blobs", directoryHint: .isDirectory) }
    public var models: URL { root.appending(path: "Models", directoryHint: .isDirectory) }
    public var recordings: URL { root.appending(path: "Recordings", directoryHint: .isDirectory) }
    /// M7, the iPhone: the recordings made on the phone, kept as `.lecture` packages (the outbox)
    /// until the student shares them to the Mac (a capture bundle) and deletes them; never imported
    /// into the phone's library. Created by the phone's recorder when it first records, not here.
    public var phoneCaptures: URL { root.appending(path: "PhoneCaptures", directoryHint: .isDirectory) }
    /// M3.5: the Claude Code backend's folder (`ClaudeCodeConfiguration.directory`): its empty
    /// working directory, its state (usage pause) and each run's MCP config. Created by the backend.
    public var agent: URL { root.appending(path: "Agent", directoryHint: .isDirectory) }

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
