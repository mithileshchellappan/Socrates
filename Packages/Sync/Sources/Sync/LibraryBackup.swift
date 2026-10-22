import Foundation
import GRDB
import StudyCore
import Synchronization

/// One copy of the library a day, on the Mac: `Database/Backups/Socrates-<yyyy-MM-dd>.sqlite`,
/// the newest seven kept. The copy is SQLite's backup API reading from a pool reader in WAL
/// snapshot isolation, so the writer and the screens never wait for it; it is written to
/// `<file>.partial` and renamed when complete, so a backup is whole or absent. Only the main
/// schema is copied: no SQLiteData metadatabase, no sync triggers (a library put back from such a
/// file queues its rows again through `SyncedTables.queueUntracked`).
///
/// A day that has its file costs one `stat`. A disk short of room (less than twice the library
/// plus 2 GB free) skips the day. After a new backup, every synced table with fewer rows than in
/// the previous backup gets one public log line ("Since the backup of <day>: weekly_slot
/// −4"): rows that went without anyone saying so show up a day later. Logs only (category
/// "Backup"): table names, counts, sizes; never ids or content.
public struct LibraryBackup: Sendable {
    public let database: any DatabaseWriter
    public let directory: URL
    public let name: String
    public let keep: Int
    private let now: @Sendable () -> Date

    public init(
        database: any DatabaseWriter, directory: URL, name: String, keep: Int = 7,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.directory = directory
        self.name = name
        self.keep = keep
        self.now = now
    }

    public init(services: StudyServices) {
        self.init(
            database: services.database,
            directory: services.paths.databaseDirectory.appending(path: "Backups", directoryHint: .isDirectory),
            name: services.paths.databaseName
        )
    }

    /// Makes today's backup unless it exists, prunes to `keep`, then compares row counts with the
    /// previous backup. Never throws: a failure is logged and the next launch or wake tries again.
    @concurrent
    public func runDaily() async {
        let day = Self.day(now())
        let target = directory.appending(path: "\(name)-\(day).sqlite")
        guard !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { return }
        // A launch and a wake at the same moment: one of them copies.
        guard Self.running.withLock({ running in
            if running { return false }
            running = true
            return true
        }) else { return }
        defer { Self.running.withLock { $0 = false } }
        let started = ContinuousClock.now
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            removePartials()
            guard Self.hasRoom(for: database) else {
                BackupLog.backup.notice("Daily backup skipped, low disk")
                return
            }
            try Self.copy(database, to: target)
            let elapsed = started.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let megabytes = Self.fileSize(target) / 1_000_000
            BackupLog.backup.notice(
                "Backed up the library for \(day, privacy: .public): \(megabytes, privacy: .public) MB in \(seconds, format: .fixed(precision: 1), privacy: .public) s"
            )
            let kept = prune()
            if let previous = kept.last(where: { $0.lastPathComponent < target.lastPathComponent }) {
                reportDrops(from: previous, to: target)
            }
        } catch {
            BackupLog.backup.error("Daily backup failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    // MARK: - The copy (shared with `LibraryRestore`)

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

    // MARK: - Private

    private static let running = Mutex(false)

    /// `yyyy-MM-dd` in the Mac's time zone.
    private static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? NSNumber
        return size?.int64Value ?? 0
    }

    /// Removes a database file the app made and its `-wal`, `-shm` and `-journal` files (or only
    /// those, `keepingMain`).
    private static func removeDatabaseFiles(at url: URL, keepingMain: Bool = false) {
        let path = url.path(percentEncoded: false)
        let suffixes = keepingMain ? ["-wal", "-shm", "-journal"] : ["", "-wal", "-shm", "-journal"]
        for suffix in suffixes where FileManager.default.fileExists(atPath: path + suffix) {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// The backups in `directory`, oldest first (by name: the day).
    private func backups() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let pattern = /^(.+)-\d{4}-\d{2}-\d{2}\.sqlite$/
        return files
            .filter { url in
                guard let match = url.lastPathComponent.wholeMatch(of: pattern) else { return false }
                return match.1 == name
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Partial copies an earlier crash left (this backup's own copy runs after this).
    private func removePartials() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(name + "-") && file.lastPathComponent.hasSuffix(".sqlite.partial") {
            Self.removeDatabaseFiles(at: file)
        }
    }

    /// Removes all but the newest `keep` backups; returns the ones kept, oldest first.
    private func prune() -> [URL] {
        let all = backups()
        let excess = max(0, all.count - max(1, keep))
        for file in all.prefix(excess) {
            Self.removeDatabaseFiles(at: file)
        }
        return Array(all.dropFirst(excess))
    }

    /// One notice per synced table with fewer rows in `newer` than in `older` (both opened
    /// read-only; the live library is never read here). A table one of them lacks is left out.
    private func reportDrops(from older: URL, to newer: URL) {
        do {
            let before = try Self.rowCounts(in: older)
            let after = try Self.rowCounts(in: newer)
            let day = older.lastPathComponent.dropFirst(name.count + 1).prefix(10)
            for table in SyncedTables.types.map({ $0.tableName }) {
                guard let old = before[table], let new = after[table], new < old else { continue }
                BackupLog.backup.notice(
                    "Since the backup of \(String(day), privacy: .public): \(table, privacy: .public) −\(old - new, privacy: .public)"
                )
            }
        } catch {
            BackupLog.backup.error("Comparing backups failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private static func rowCounts(in url: URL) throws -> [String: Int] {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path(percentEncoded: false), configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            var counts: [String: Int] = [:]
            for table in SyncedTables.types.map({ $0.tableName }) {
                guard try db.tableExists(table) else { continue }
                counts[table] = try Int.fetchOne(db, sql: "SELECT count(*) FROM \"\(table)\"") ?? 0
            }
            return counts
        }
    }
}

enum BackupLog {
    static let backup = Log.logger(category: "Backup")
}
