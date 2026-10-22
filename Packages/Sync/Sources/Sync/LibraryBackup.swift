import Foundation
import GRDB
import StudyCore

/// One copy of the library a day, on the Mac: `Database/Backups/Socrates-<yyyy-MM-dd>.sqlite`
/// (`AppPaths.backups`). Kept: the newest seven, and the newest of each of the 4 latest weeks and
/// of the 3 latest months that have one (at most 14, about 0.3 GB at 24 MB a copy), so a loss
/// noticed weeks later still has a copy from before it. Files of the folder are matched by their
/// day whatever the name before it (a library renamed by `LibraryMove` keeps pruning and comparing
/// its older copies). The copy is SQLite's backup API reading from a pool reader in WAL snapshot
/// isolation, so the writer and the screens never wait for it; it is written to `<file>.partial`
/// and renamed when complete, so a backup is whole or absent (`LibraryCopy`). Only the main schema
/// is copied: no SQLiteData metadatabase, no sync triggers (a library put back from such a file
/// queues its rows again through `SyncedTables.queueUntracked`).
///
/// An actor: a launch, a wake and the hourly check that ask at once run one after another, and
/// the later ones find the day's file. A day that has its file costs one `stat`. A disk short of
/// room (less than twice the library plus 2 GB free) skips the day. After a new backup, every
/// synced table with fewer rows than in the previous backup gets one public log line ("Since the
/// backup of <day>: weekly_slot −4"): rows that went without anyone saying so show up a day later.
/// Logs only (category "sync.backup"): table names, counts, sizes; never ids or content.
public actor LibraryBackup {
    private let database: any DatabaseWriter
    private let directory: URL
    private let name: String

    public init(services: StudyServices) {
        database = services.database
        directory = services.paths.backups
        name = services.paths.databaseName
    }

    /// `runDaily()` now, then once an hour until the task is cancelled: a Mac kept awake
    /// (overnight runs, a recording's sleep assertion) gets its day's copy too.
    public func runHourly() async {
        runDaily()
        while (try? await Task.sleep(for: .seconds(3_600))) != nil {
            runDaily()
        }
    }

    /// Makes today's backup unless it exists, prunes (`prune()`), then compares row counts with
    /// the previous backup. Never throws: a failure is logged and the next run tries again.
    public func runDaily() {
        let day = Self.day(Date())
        let target = directory.appending(path: "\(name)-\(day).sqlite")
        guard !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { return }
        let started = ContinuousClock.now
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            removePartials()
            guard LibraryCopy.hasRoom(for: database) else {
                SyncLog.backup.notice("Daily backup skipped, low disk")
                return
            }
            try LibraryCopy.copy(database, to: target)
            let elapsed = started.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let megabytes = LibraryCopy.fileSize(target) / 1_000_000
            SyncLog.backup.notice(
                "Backed up the library for \(day, privacy: .public): \(megabytes, privacy: .public) MB in \(seconds, format: .fixed(precision: 1), privacy: .public) s"
            )
            let kept = prune()
            if let previous = kept.last(where: { $0.day < day }) {
                reportDrops(from: previous, to: target)
            }
        } catch {
            SyncLog.backup.error("Daily backup failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    // MARK: - Private

    /// `yyyy-MM-dd` in the Mac's time zone.
    private static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// One backup file and its day (`yyyy-MM-dd`).
    private struct Backup {
        let url: URL
        let day: String
    }

    /// Days, weeks and months whose newest backup `prune()` keeps.
    private static let daysKept = 7
    private static let weeksKept = 4
    private static let monthsKept = 3

    /// The backups in `directory` (any name before the day), oldest first.
    private func backups() -> [Backup] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let pattern = /^.+-(\d{4}-\d{2}-\d{2})\.sqlite$/
        return files
            .compactMap { url in
                url.lastPathComponent.wholeMatch(of: pattern).map { Backup(url: url, day: String($0.1)) }
            }
            .sorted { ($0.day, $0.url.lastPathComponent) < ($1.day, $1.url.lastPathComponent) }
    }

    /// Partial copies an earlier crash left (this backup's own copy runs after this).
    private func removePartials() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasSuffix(".sqlite.partial") {
            LibraryCopy.removeDatabaseFiles(at: file)
        }
    }

    /// Keeps the newest `daysKept` backups and the newest of each of the `weeksKept` latest weeks
    /// and `monthsKept` latest months that have one; removes the rest. Returns the ones kept,
    /// oldest first.
    private func prune() -> [Backup] {
        let all = backups()
        var kept = Set(all.suffix(Self.daysKept).map(\.url))
        let calendar = Calendar.current
        func keepNewest(of count: Int, by group: (Backup) -> String?) {
            var seen: Set<String> = []
            for backup in all.reversed() {
                guard let key = group(backup), !seen.contains(key) else { continue }
                guard seen.count < count else { break }
                seen.insert(key)
                kept.insert(backup.url)
            }
        }
        keepNewest(of: Self.weeksKept) { backup in
            Self.date(of: backup.day).map { date in
                let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
                return "\(parts.yearForWeekOfYear ?? 0)-W\(parts.weekOfYear ?? 0)"
            }
        }
        keepNewest(of: Self.monthsKept) { String($0.day.prefix(7)) }
        for backup in all where !kept.contains(backup.url) {
            LibraryCopy.removeDatabaseFiles(at: backup.url)
        }
        return all.filter { kept.contains($0.url) }
    }

    /// Noon of a `yyyy-MM-dd` day in the Mac's time zone.
    private static func date(of day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// One notice per synced table with fewer rows in `newer` than in `older` (both opened
    /// read-only; the live library is never read here). A table one of them lacks is left out.
    private func reportDrops(from older: Backup, to newer: URL) {
        do {
            let before = try Self.rowCounts(in: older.url)
            let after = try Self.rowCounts(in: newer)
            for table in SyncedTables.tableNames {
                guard let old = before[table], let new = after[table], new < old else { continue }
                SyncLog.backup.notice(
                    "Since the backup of \(older.day, privacy: .public): \(table, privacy: .public) −\(old - new, privacy: .public)"
                )
            }
        } catch {
            SyncLog.backup.error("Comparing backups failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private static func rowCounts(in url: URL) throws -> [String: Int] {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path(percentEncoded: false), configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            var counts: [String: Int] = [:]
            for table in SyncedTables.tableNames {
                guard try db.tableExists(table) else { continue }
                counts[table] = try Int.fetchOne(db, sql: "SELECT count(*) FROM \"\(table)\"") ?? 0
            }
            return counts
        }
    }
}
