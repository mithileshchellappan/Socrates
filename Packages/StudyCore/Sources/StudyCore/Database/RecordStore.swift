import Foundation
import SQLiteData

/// Generic create/read/update/delete for any `StudyRecord`.
///
/// `save` is an upsert (`INSERT … ON CONFLICT(id) DO UPDATE`), never `INSERT OR REPLACE`,
/// so saving a parent row does not cascade-delete its children.
public struct RecordStore: Sendable {
    public let database: any DatabaseWriter
    private let now: @Sendable () -> Date

    public init(database: any DatabaseWriter, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.now = now
    }

    /// Inserts or updates `record`, stamping `updatedAt`. Returns the stamped record.
    @discardableResult
    public func save<Record: StudyRecord>(_ record: Record) async throws -> Record {
        let stamped = stamp(record)
        try await database.write { db in
            try Record.upsert { stamped }.execute(db)
        }
        return stamped
    }

    /// Saves all records in one transaction.
    @discardableResult
    public func save<Record: StudyRecord>(_ records: [Record]) async throws -> [Record] {
        let stamped = records.map(stamp)
        try await database.write { db in
            for record in stamped {
                try Record.upsert { record }.execute(db)
            }
        }
        return stamped
    }

    public func fetch<Record: StudyRecord>(_ type: Record.Type, id: UUID) async throws -> Record? {
        try await database.read { db in
            try Record.find(id).fetchOne(db)
        }
    }

    public func fetchAll<Record: StudyRecord>(_ type: Record.Type) async throws -> [Record] {
        try await database.read { db in
            try Record.all.fetchAll(db)
        }
    }

    public func count<Record: StudyRecord>(_ type: Record.Type) async throws -> Int {
        try await database.read { db in
            try Record.all.fetchCount(db)
        }
    }

    public func delete<Record: StudyRecord>(_ type: Record.Type, id: UUID) async throws {
        try await database.write { db in
            try Record.find(id).delete().execute(db)
        }
    }

    func stamp<Record: StudyRecord>(_ record: Record) -> Record {
        var record = record
        record.updatedAt = now()
        return record
    }
}
