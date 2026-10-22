import Foundation
import GRDB

/// A copy of the library as one self-contained file, and the file facts copies need. Used by the
/// daily backup (`LibraryBackup`) and by the copy made before a restore (`LibraryRestore`).
enum LibraryCopy {
    /// Copies the main schema of `database` to `url` with SQLite's backup API (one step, from a
    /// reader snapshot), through `<url>.partial`, then renames it. The copy is set to rollback
    /// journal mode (a copy of a WAL library is marked WAL), so it is one self-contained file that
    /// opens read-only without `-wal`/`-shm` files beside it. Throws, leaving nothing at `url`,
    /// when any step fails.
    static func copy(_ database: any DatabaseWriter, to url: URL) throws {
        let partial = url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".partial")
        removeDatabaseFiles(at: partial)
        do {
            let queue = try DatabaseQueue(path: partial.path(percentEncoded: false))
            try database.backup(to: queue, pagesPerStep: -1)
            try queue.writeWithoutTransaction { db in
                // The first read sees the copied header (WAL); the pragma then turns it back.
                _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master")
                try db.execute(sql: "PRAGMA journal_mode = DELETE")
            }
            try queue.close()
            removeDatabaseFiles(at: partial, keepingMain: true)
            try FileManager.default.moveItem(at: partial, to: url)
        } catch {
            removeDatabaseFiles(at: partial)
            throw error
        }
    }

    /// True when the library's volume has room for a copy: at least twice the library (its file
    /// and WAL) plus 2 GB free. Unknown capacity counts as room.
    static func hasRoom(for database: any DatabaseWriter) -> Bool {
        let file = URL(filePath: database.path)
        let size = fileSize(file) + fileSize(URL(filePath: database.path + "-wal"))
        let values = try? file.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return available >= 2 * size + 2_000_000_000
    }

    /// A file's modification date: for a copy, when it was made (`VACUUM INTO`, never written
    /// again).
    static func fileDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
    }

    static func fileSize(_ url: URL) -> Int64 {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? NSNumber
        return size?.int64Value ?? 0
    }

    /// Removes a database file the app made and its `-wal`, `-shm` and `-journal` files (or only
    /// those, `keepingMain`).
    static func removeDatabaseFiles(at url: URL, keepingMain: Bool = false) {
        let path = url.path(percentEncoded: false)
        let suffixes = keepingMain ? ["-wal", "-shm", "-journal"] : ["", "-wal", "-shm", "-journal"]
        for suffix in suffixes where FileManager.default.fileExists(atPath: path + suffix) {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }
}
