import Darwin
import Foundation
import SQLiteData

/// The Mac's one-time move of a library from before the app was renamed: `Application Support/
/// StudyPortal` becomes `Application Support/Socrates`, its `Database/StudyPortal.sqlite` (with
/// `-wal`, `-shm`, the sync metadatabase and the pre-sync copy) `Socrates.sqlite`. Runs at
/// launch before the database opens, for the real library only.
///
/// - Nothing is copied: the folder and each file are renamed in place (`rename(2)`, same volume,
///   atomic), so the library is never in two places and never half copied.
/// - Not this launch (the library is used where it is): while an app with the earlier bundle ID
///   runs (it has the library open), while the database is busy (its WAL could not be emptied),
///   or when a `Socrates` folder is already there.
/// - All or none: a file that cannot be renamed puts back the ones renamed before it and the
///   folder; any failure leaves the library where it was, and the app uses it there
///   (`AppPaths.liveRoot(in:)`), trying again at the next launch.
public enum LibraryMove {
    public enum Outcome: Equatable, Sendable {
        /// No library from before the rename (or it moved earlier).
        case notNeeded
        case moved
        /// Not this launch; the library is used where it is.
        case deferred(String)
        /// The move failed and was undone; the library is used where it is.
        case failed(String)
    }

    /// Moves the library (see the type). `legacyBundleID`: the earlier build's bundle ID, whose
    /// caches folder moves along (`AppPaths.live`'s caches); `isLegacyAppRunning` is asked once,
    /// before anything is touched.
    public static func run(
        legacyBundleID: String?,
        isLegacyAppRunning: () -> Bool,
        fileManager: FileManager = .default
    ) -> Outcome {
        guard let support = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else {
            return .notNeeded
        }
        let legacy = support.appending(path: AppPaths.legacyFolderName, directoryHint: .isDirectory)
        let current = support.appending(path: AppPaths.folderName, directoryHint: .isDirectory)
        guard AppPaths.hasDatabase(legacy, fileManager: fileManager), !AppPaths.hasDatabase(current, fileManager: fileManager) else {
            return .notNeeded
        }
        let outcome = move(legacy, to: current, isLegacyAppRunning: isLegacyAppRunning, fileManager: fileManager)
        switch outcome {
        case .moved:
            Log.app.notice("Moved the library to \(current.path(percentEncoded: false), privacy: .public)")
            if let legacyBundleID { moveCaches(from: legacyBundleID, fileManager: fileManager) }
        case .deferred(let reason):
            Log.app.notice("The library stays in \(legacy.lastPathComponent, privacy: .public) this launch: \(reason, privacy: .public)")
        case .failed(let reason):
            Log.app.error("Moving the library failed, it stays in \(legacy.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
        case .notNeeded:
            break
        }
        return outcome
    }

    private static func move(_ legacy: URL, to current: URL, isLegacyAppRunning: () -> Bool, fileManager: FileManager) -> Outcome {
        if isLegacyAppRunning() { return .deferred("the app is open under its earlier name") }
        if fileManager.fileExists(atPath: current.path(percentEncoded: false)) {
            return .deferred("a \(AppPaths.folderName) folder is already there")
        }
        // An empty WAL: its frames are in the database file, so no file below can lose any. A
        // busy database (another process has it open) is not moved.
        do {
            try emptyWAL(of: AppPaths(root: legacy).database)
        } catch {
            return .deferred("the database is in use (\(error.localizedDescription))")
        }
        do {
            try rename(legacy, to: current)
        } catch {
            return .failed(error.localizedDescription)
        }
        let database = current.appending(path: "Database", directoryHint: .isDirectory)
        do {
            try renameDatabaseFiles(in: database, fileManager: fileManager)
        } catch {
            do {
                try rename(current, to: legacy)
            } catch let back {
                // Still a working library: `AppPaths` finds the database in the new folder under
                // its old name, so nothing is lost; the next launch finishes the renames.
                return .failed("\(error.localizedDescription); the folder stays moved: \(back.localizedDescription)")
            }
            return .failed(error.localizedDescription)
        }
        return .moved
    }

    /// Checkpoints the database's WAL into the file and truncates it (`PRAGMA wal_checkpoint(TRUNCATE)`),
    /// then closes. Throws when another connection keeps it from finishing.
    private static func emptyWAL(of database: URL) throws {
        guard FileManager.default.fileExists(atPath: database.path(percentEncoded: false)) else { return }
        let queue = try DatabaseQueue(path: database.path(percentEncoded: false))
        do {
            try queue.writeWithoutTransaction { db in
                _ = try db.checkpoint(.truncate)
            }
        } catch {
            try? queue.close()
            throw error
        }
        try queue.close()
    }

    /// Renames every file of the database (`StudyPortal.sqlite`, its `-wal` and `-shm`, the
    /// synced and pre-sync copies, SQLiteData's `.StudyPortal.metadata-…` files) to the new
    /// name; all or none.
    static func renameDatabaseFiles(in directory: URL, fileManager: FileManager) throws {
        let old = AppPaths.legacyDatabaseName
        let new = AppPaths.defaultDatabaseName
        let names = try fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        let renames: [(from: URL, to: URL)] = names.compactMap { name in
            for prefix in ["", "."] where name.hasPrefix(prefix + old + ".") || name.hasPrefix(prefix + old + "-") {
                let renamed = prefix + new + String(name.dropFirst(prefix.count + old.count))
                return (from: directory.appending(path: name), to: directory.appending(path: renamed))
            }
            return nil
        }
        for rename in renames where fileManager.fileExists(atPath: rename.to.path(percentEncoded: false)) {
            throw MoveError("\(rename.to.lastPathComponent) is already there")
        }
        var done: [(from: URL, to: URL)] = []
        do {
            for item in renames {
                try self.rename(item.from, to: item.to)
                done.append(item)
            }
        } catch {
            for item in done.reversed() {
                try? self.rename(item.to, to: item.from)
            }
            throw error
        }
    }

    /// `~/Library/Caches/<earlier bundle ID>` to this build's caches folder, when that one is
    /// not there yet (slide bitmaps and other caches; rebuilt when missing, so a failure only
    /// costs time).
    private static func moveCaches(from legacyBundleID: String, fileManager: FileManager) {
        guard let caches = try? fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        let old = caches.appending(path: legacyBundleID, directoryHint: .isDirectory)
        let new = caches.appending(path: AppIdentity.bundleID, directoryHint: .isDirectory)
        guard old != new,
              fileManager.fileExists(atPath: old.path(percentEncoded: false)),
              !fileManager.fileExists(atPath: new.path(percentEncoded: false))
        else { return }
        do {
            try rename(old, to: new)
        } catch {
            Log.app.notice("The caches stay behind: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `rename(2)`: atomic on one volume, and never a copy (it fails across volumes).
    private static func rename(_ source: URL, to destination: URL) throws {
        let from = source.path(percentEncoded: false)
        let to = destination.path(percentEncoded: false)
        guard Darwin.rename(from, to) == 0 else {
            let code = errno
            throw MoveError("\(source.lastPathComponent) → \(destination.lastPathComponent): \(String(cString: strerror(code)))")
        }
    }

    struct MoveError: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}
