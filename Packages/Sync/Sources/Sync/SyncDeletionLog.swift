import Foundation
import GRDB
import StudyCore
import Synchronization

/// Logs the rows iCloud sync deletes on this device: one public line per transaction with table
/// names and counts ("iCloud deleted rows on this device: course 1, weekly_slot 4"), never ids or
/// content (category "SyncDeletes").
///
/// SQLiteData reports none of its local deletes (another device's deletes, deleted, purged or
/// reset zones), but it marks every write it makes with `SyncEngine.isSynchronizing`, which its
/// own triggers read while a statement runs. This observer on the library's writer counts the
/// deletes on synced tables made while it is set, including the rows ON DELETE CASCADE removes in
/// the same statement. A delete SQLiteData makes with the flag off looks like the student's own
/// and is not counted; the daily backup's row-count comparison (`LibraryBackup`) still shows it.
final class SyncDeletionLog: TransactionObserver, Sendable {
    private let tables: Set<String>
    private let counts = Mutex<[String: Int]>([:])

    init(tables: Set<String>) {
        self.tables = tables
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        guard case .delete(tableName: let table) = eventKind else { return false }
        return tables.contains(table)
    }

    func databaseDidChange(with event: DatabaseEvent) {
        guard SyncEngine.isSynchronizing else { return }
        let table = event.tableName
        counts.withLock { $0[table, default: 0] += 1 }
    }

    func databaseDidCommit(_ db: Database) {
        let deleted = counts.withLock { counts in
            defer { counts = [:] }
            return counts
        }
        guard !deleted.isEmpty else { return }
        let line = deleted.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        SyncDeletionLog.logger.notice("iCloud deleted rows on this device: \(line, privacy: .public)")
    }

    func databaseDidRollback(_ db: Database) {
        counts.withLock { $0 = [:] }
    }

    private static let logger = Log.logger(category: "SyncDeletes")
}
