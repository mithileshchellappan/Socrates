import Foundation

/// Where the app keeps its files.
///
/// Live layout (unsandboxed Mac: `~/Library/Application Support/Socrates`; iOS: the app
/// container's `Library/Application Support/Socrates`):
///
///     Socrates/
///       Database/Socrates.sqlite      SQLite (WAL)
///       Blobs/ab/abcdef….pdf          content-addressed files (BlobStore)
///       Models/                       WhisperKit and other models (excluded from backup)
///       Recordings/                   in-progress capture files before they enter Blobs
///       PhoneCaptures/                iPhone (M7): its recordings as `.lecture` packages until shared
///       Incoming/                     Mac: recordings arriving from the iPhone's link, staged per device until whole
///       Agent/                        the Claude Code backend (M3.5): Workspace/, state.json, Runs/
///
/// Before the app was renamed the folder was `StudyPortal` with `Database/StudyPortal.sqlite`.
/// The Mac moves such a library once at launch (`LibraryMove`); until then (the earlier app was
/// running, or the move failed) the library stays where it is and is used there: the live root
/// is the folder that holds a database (`Socrates` first), and a library's database keeps the
/// name it has (`databaseName`). Library copies made before the rename (parity, demo) open as
/// they are.
///
/// Caches (slide bitmaps, …) live in the system caches directory and may be purged.
/// Never use ~/Documents: it syncs to iCloud.
public struct AppPaths: Hashable, Sendable {
    public let root: URL
    public let caches: URL
    /// The database file's name without extension: "Socrates", or "StudyPortal" for a library
    /// whose database has the name from before the rename.
    public let databaseName: String

    public init(root: URL, caches: URL? = nil) {
        self.root = root
        self.caches = caches ?? root.appending(path: "Caches", directoryHint: .isDirectory)
        databaseName = Self.databaseName(in: root.appending(path: "Database", directoryHint: .isDirectory))
    }

    public static let folderName = "Socrates"
    /// The library folder's name before the app was renamed (Study Portal).
    public static let legacyFolderName = "StudyPortal"
    /// The database file's name (without extension).
    public static let defaultDatabaseName = "Socrates"
    /// The database file's name before the app was renamed.
    public static let legacyDatabaseName = "StudyPortal"

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
            root: liveRoot(in: support, fileManager: fileManager),
            caches: caches.appending(path: AppIdentity.bundleID, directoryHint: .isDirectory)
        )
    }

    /// The real library's folder in `support` (Application Support): `Socrates` when it holds a
    /// database or no library exists yet, `StudyPortal` while only that one holds a database (a
    /// library the Mac has not moved yet).
    public static func liveRoot(in support: URL, fileManager: FileManager = .default) -> URL {
        let current = support.appending(path: folderName, directoryHint: .isDirectory)
        let legacy = support.appending(path: legacyFolderName, directoryHint: .isDirectory)
        if !hasDatabase(current, fileManager: fileManager), hasDatabase(legacy, fileManager: fileManager) {
            return legacy
        }
        return current
    }

    /// The real library's folder (`liveRoot(in:)` in this user's Application Support), whatever
    /// `SOCRATES_DATA_ROOT` says: for what every library on the device shares (models).
    public static func sharedRoot(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return liveRoot(in: support, fileManager: fileManager)
    }

    /// The folders the real library can be in (`Socrates`, and `StudyPortal` from before the
    /// rename), so a tool that refuses the real library refuses both.
    public static func liveRootCandidates(fileManager: FileManager = .default) throws -> [URL] {
        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return [folderName, legacyFolderName].map { support.appending(path: $0, directoryHint: .isDirectory) }
    }

    /// True when `root` holds a library database (under either name).
    public static func hasDatabase(_ root: URL, fileManager: FileManager = .default) -> Bool {
        let directory = root.appending(path: "Database", directoryHint: .isDirectory)
        return [defaultDatabaseName, legacyDatabaseName].contains { name in
            fileManager.fileExists(atPath: directory.appending(path: "\(name).sqlite").path(percentEncoded: false))
        }
    }

    /// "Socrates", unless only a database with the name from before the rename is there.
    static func databaseName(in directory: URL, fileManager: FileManager = .default) -> String {
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: directory.appending(path: "\(name).sqlite").path(percentEncoded: false))
        }
        return !exists(defaultDatabaseName) && exists(legacyDatabaseName) ? legacyDatabaseName : defaultDatabaseName
    }

    public var databaseDirectory: URL { root.appending(path: "Database", directoryHint: .isDirectory) }
    public var database: URL { databaseDirectory.appending(path: "\(databaseName).sqlite") }
    /// M7, the iPhone with iCloud sync: a library of its own, filled by the Mac's rows. The phone's
    /// library from before sync (its own seeded courses) stays in `database` and never uploads.
    public var syncedDatabase: URL { databaseDirectory.appending(path: "\(databaseName)-synced.sqlite") }
    /// M7, the Mac: the one copy of the library made before its first sync (kept, never
    /// overwritten), next to the database.
    public var preSyncBackup: URL { databaseDirectory.appending(path: "\(databaseName)-before-sync.sqlite") }
    /// The Mac: the one copy of the library made before rows lost to its first sync were restored
    /// (`LibraryRestore`; kept, never overwritten).
    public var preRestoreBackup: URL { databaseDirectory.appending(path: "\(databaseName)-before-restore.sqlite") }
    /// The Mac: the daily copies of the library (`LibraryBackup`), `<name>-<yyyy-MM-dd>.sqlite`.
    public var backups: URL { databaseDirectory.appending(path: "Backups", directoryHint: .isDirectory) }
    public var blobs: URL { root.appending(path: "Blobs", directoryHint: .isDirectory) }
    public var models: URL { root.appending(path: "Models", directoryHint: .isDirectory) }
    public var recordings: URL { root.appending(path: "Recordings", directoryHint: .isDirectory) }
    /// M7, the iPhone: the recordings made on the phone, kept as `.lecture` packages (the outbox)
    /// until the student shares them to the Mac (a capture bundle) and deletes them; never imported
    /// into the phone's library. Created by the phone's recorder when it first records, not here.
    public var phoneCaptures: URL { root.appending(path: "PhoneCaptures", directoryHint: .isDirectory) }
    /// The Mac: recordings arriving from the iPhone over the recording link, staged per device
    /// (`Incoming/<device>/<uuid>.lecture.partial/`) until every file is whole and checked, then
    /// moved into `recordings`. Outside `recordings`, so the launch filing pass never takes half a
    /// package. Created by the link on first use, not here.
    public var linkInbox: URL { root.appending(path: "Incoming", directoryHint: .isDirectory) }
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
