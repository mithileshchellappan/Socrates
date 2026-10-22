import Foundation
import GRDB
import StudyCore

/// Puts back rows the Mac's first iCloud upload deleted, from the copy of the library made just
/// before it (`AppPaths.preSyncBackup`). While every table went to SQLiteData as a shareable
/// table (before 2026-10-22), a row whose table has one foreign key had that parent as its
/// CloudKit parent; iCloud refused some of them (`referenceViolation`) and SQLiteData deleted
/// them on the device like a delete of the student's, so ON DELETE CASCADE and SET NULL ran too.
/// With private tables (`SyncedTables.engine`) that path cannot run again.
///
/// Four tables are restored, each row only when nothing in the live library says it went on
/// purpose or has been replaced:
/// - `weekly_slot`: when its course exists, no `slot_remove` change (not undone) names it and no
///   live slot of the course has the same kind, weekday and start;
/// - `lecture_session.weekly_slot_id`: set again where the delete cleared it (same course, still
///   NULL), without stamping `updated_at` (the calendar event does not show the slot);
/// - `lecture_session`: generated, unedited, not cancelled, in the future, with its slot back,
///   nothing filed to it, and no live session of the course within a minute of it. Its calendar
///   fields start empty, so the calendar mirror adopts the event that still carries the
///   session's link or writes a new one (never "the event was deleted in Calendar");
/// - `slide_ink`: when its deck exists and the page has no ink;
/// - `mail_attachment`: when its message exists and has no attachment with the same part (or
///   file name); its file is fetched again when it is opened (`blob_*` empty, as for a newly
///   synced attachment).
/// Only columns both schemas have are written; the rest take their defaults. Every write is one
/// transaction through the library's own writer, so SQLiteData's triggers queue each row for
/// upload. Before writing, the library is copied once to `<name>-before-restore.sqlite`
/// (`LibraryBackup.copy`); an existing copy is kept, so a retry never replaces it.
///
/// `run()` has no once-logic (the app keeps that, `AppModel.restoreLostRowsOnce`) and is
/// idempotent: a second run finds every row present. Logs table names and counts only
/// (category "Restore").
public struct LibraryRestore: Sendable {
    public struct Outcome: Sendable, Equatable {
        /// Rows inserted, by table.
        public var restored: [String: Int] = [:]
        /// Sessions whose slot link was set again.
        public var relinkedSessions = 0
        /// Rows missing from the live library and left out, by reason.
        public var skipped: [String: Int] = [:]
        /// Courses whose slots or sessions changed (to replan).
        public var courses: Set<Course.ID> = []

        public init() {}

        public var isEmpty: Bool { restored.values.allSatisfy { $0 == 0 } && relinkedSessions == 0 }
    }

    public enum Failure: Error {
        /// Not enough free disk for the copy before restoring.
        case lowDisk
    }

    public let database: any DatabaseWriter
    /// The library copy to restore from (read-only).
    public let source: URL
    /// Where the live library is copied before the first restore.
    public let copy: URL
    private let now: @Sendable () -> Date

    public init(database: any DatabaseWriter, source: URL, copy: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.source = source
        self.copy = copy
        self.now = now
    }

    public init(services: StudyServices) {
        let paths = services.paths
        self.init(
            database: services.database,
            source: paths.preSyncBackup,
            copy: paths.databaseDirectory.appending(path: "\(paths.databaseName)-before-restore.sqlite")
        )
    }

    /// True when the copy to restore from exists.
    public var hasSource: Bool { FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) }

    @concurrent
    public func run() async throws -> Outcome {
        guard hasSource else { return Outcome() }
        do {
            if !FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) {
                guard LibraryBackup.hasRoom(for: database) else { throw Failure.lowDisk }
                try LibraryBackup.copy(database, to: copy)
            }
            let snapshot = try Snapshot.read(source)
            let stamp = now()
            let outcome = try await database.write { db in try Self.apply(snapshot, now: stamp, db: db) }
            let restored = Self.restoredTables
                .map { table -> String in
                    let count = outcome.restored[table] ?? 0
                    return table == "lecture_session" ? "\(table) \(count) (+\(outcome.relinkedSessions) relinked)" : "\(table) \(count)"
                }
                .joined(separator: ", ")
            RestoreLog.restore.notice("Restored from the copy before the first sync: \(restored, privacy: .public)")
            let reasons: [String] = outcome.skipped.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
            let skipped: String = reasons.isEmpty ? "none" : reasons.joined(separator: ", ")
            RestoreLog.restore.notice("Not restored: \(skipped, privacy: .public)")
            return outcome
        } catch {
            RestoreLog.restore.error("Restoring rows failed: \(String(describing: type(of: error)), privacy: .public)")
            throw error
        }
    }

    // MARK: - Source

    static let restoredTables = ["weekly_slot", "lecture_session", "slide_ink", "mail_attachment"]

    /// One table of the source: its columns and every row's values in that order.
    struct SourceTable: Sendable {
        let columns: [String]
        let rows: [[DatabaseValue]]
        private let index: [String: Int]

        init(columns: [String], rows: [[DatabaseValue]]) {
            self.columns = columns
            self.rows = rows
            index = Dictionary(columns.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        }

        func value(_ row: [DatabaseValue], _ column: String) -> DatabaseValue {
            guard let position = index[column], position < row.count else { return .null }
            return row[position]
        }
    }

    struct Snapshot: Sendable {
        var tables: [String: SourceTable] = [:]
        /// Session ids a lecture or a filing points to.
        var filedSessions: Set<String> = []

        /// Reads the source as a plain read-only queue: never migrated, no metadatabase.
        static func read(_ url: URL) throws -> Snapshot {
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(path: url.path(percentEncoded: false), configuration: configuration)
            defer { try? queue.close() }
            return try queue.read { db in
                var snapshot = Snapshot()
                for table in LibraryRestore.restoredTables {
                    guard try db.tableExists(table) else { continue }
                    let columns = try db.columns(in: table).map(\.name)
                    let list = columns.map(LibraryRestore.quoted).joined(separator: ", ")
                    let rows = try Row.fetchAll(db, sql: "SELECT \(list) FROM \(LibraryRestore.quoted(table))")
                        .map { Array($0.databaseValues) }
                    snapshot.tables[table] = SourceTable(columns: columns, rows: rows)
                }
                for table in ["lecture", "filing"] {
                    guard try db.tableExists(table) else { continue }
                    let ids = try String.fetchAll(
                        db,
                        sql: "SELECT \"lecture_session_id\" FROM \(LibraryRestore.quoted(table)) WHERE \"lecture_session_id\" IS NOT NULL"
                    )
                    snapshot.filedSessions.formUnion(ids)
                }
                return snapshot
            }
        }
    }

    // MARK: - Restore (one transaction)

    static func apply(_ snapshot: Snapshot, now: Date, db: Database) throws -> Outcome {
        var outcome = Outcome()
        func skip(_ reason: String) { outcome.skipped[reason, default: 0] += 1 }
        func restored(_ table: String) { outcome.restored[table, default: 0] += 1 }
        func course(_ value: DatabaseValue) {
            if let text = String.fromDatabaseValue(value), let id = UUID(uuidString: text) { outcome.courses.insert(id) }
        }

        // a) Weekly slots. slotMap: source slot id → the live slot that stands for it.
        var slotMap: [String: String] = [:]
        var slotCourse: [String: DatabaseValue] = [:]
        if let slots = snapshot.tables["weekly_slot"] {
            let columns = try sharedColumns(slots, "weekly_slot", db)
            for row in slots.rows {
                let idValue = slots.value(row, "id")
                guard let id = String.fromDatabaseValue(idValue) else { continue }
                let courseID = slots.value(row, "course_id")
                slotCourse[id] = courseID
                if try exists("weekly_slot", id: idValue, db) {
                    slotMap[id] = id
                    continue
                }
                guard try exists("course", id: courseID, db) else { skip("weekly_slot: course gone"); continue }
                let removed = try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS (SELECT 1 FROM "agent_change"
                        WHERE "kind" = 'slot_remove' AND "target_id" = ? AND "undone_at" IS NULL)
                        """,
                    arguments: [idValue]
                ) ?? false
                guard !removed else { skip("weekly_slot: removed by the agent"); continue }
                let same = try String.fetchOne(
                    db,
                    sql: """
                        SELECT "id" FROM "weekly_slot"
                        WHERE "course_id" = ? AND "kind" = ? AND "weekday" = ? AND "start_minute" = ?
                        LIMIT 1
                        """,
                    arguments: [courseID, slots.value(row, "kind"), slots.value(row, "weekday"), slots.value(row, "start_minute")]
                )
                if let same {
                    slotMap[id] = same
                    skip("weekly_slot: same slot live")
                    continue
                }
                try insert("weekly_slot", columns: columns, from: slots, row: row, db)
                slotMap[id] = id
                restored("weekly_slot")
                course(courseID)
            }
        }

        guard let sessions = snapshot.tables["lecture_session"] else { return outcome }

        // b) Sessions whose slot link the delete cleared get it again (no `updated_at` stamp: the
        // calendar event does not show the slot, so it stays in step).
        for row in sessions.rows {
            guard let slot = String.fromDatabaseValue(sessions.value(row, "weekly_slot_id")),
                let live = slotMap[slot], let slotCourseID = slotCourse[slot]
            else { continue }
            try db.execute(
                sql: """
                    UPDATE "lecture_session" SET "weekly_slot_id" = ?
                    WHERE "id" = ? AND "weekly_slot_id" IS NULL AND "course_id" = ?
                    """,
                arguments: [live, sessions.value(row, "id"), slotCourseID]
            )
            if db.changesCount > 0 {
                outcome.relinkedSessions += db.changesCount
                course(slotCourseID)
            }
        }

        // c) Generated future sessions that went with their slots.
        let sessionColumns = try sharedColumns(sessions, "lecture_session", db)
        for row in sessions.rows {
            let idValue = sessions.value(row, "id")
            guard let id = String.fromDatabaseValue(idValue), try !exists("lecture_session", id: idValue, db) else { continue }
            guard let slot = String.fromDatabaseValue(sessions.value(row, "weekly_slot_id")), let live = slotMap[slot] else {
                skip("lecture_session: no slot")
                continue
            }
            guard sessions.value(row, "edited_at").isNull, Int.fromDatabaseValue(sessions.value(row, "is_cancelled")) == 0 else {
                skip("lecture_session: edited or cancelled")
                continue
            }
            guard let startsAt = Date.fromDatabaseValue(sessions.value(row, "starts_at")), startsAt > now else {
                skip("lecture_session: past")
                continue
            }
            let courseID = sessions.value(row, "course_id")
            guard try exists("course", id: courseID, db) else { skip("lecture_session: course gone"); continue }
            guard !snapshot.filedSessions.contains(id) else { skip("lecture_session: filed"); continue }
            let starts = try DatabaseValue.fetchAll(
                db, sql: #"SELECT "starts_at" FROM "lecture_session" WHERE "course_id" = ?"#, arguments: [courseID]
            )
            let clashes = starts.contains { value in
                Date.fromDatabaseValue(value).map { abs($0.timeIntervalSince(startsAt)) < 60 } ?? false
            }
            guard !clashes else { skip("lecture_session: clash"); continue }
            try insert(
                "lecture_session", columns: sessionColumns, from: sessions, row: row,
                overrides: ["weekly_slot_id": live.databaseValue, "calendar_event_id": .null, "calendar_synced_at": .null],
                db
            )
            restored("lecture_session")
            course(courseID)
        }

        // d) Ink of a page that has none now.
        if let ink = snapshot.tables["slide_ink"] {
            let columns = try sharedColumns(ink, "slide_ink", db)
            for row in ink.rows {
                guard try !exists("slide_ink", id: ink.value(row, "id"), db) else { continue }
                let deckID = ink.value(row, "deck_id")
                guard try exists("deck", id: deckID, db) else { skip("slide_ink: deck gone"); continue }
                let inked = try Bool.fetchOne(
                    db,
                    sql: #"SELECT EXISTS (SELECT 1 FROM "slide_ink" WHERE "deck_id" = ? AND "page_number" = ?)"#,
                    arguments: [deckID, ink.value(row, "page_number")]
                ) ?? false
                guard !inked else { skip("slide_ink: page has ink"); continue }
                try insert("slide_ink", columns: columns, from: ink, row: row, db)
                restored("slide_ink")
            }
        }

        // e) Attachments of messages that still exist; their files are fetched again on open.
        if let attachments = snapshot.tables["mail_attachment"] {
            let columns = try sharedColumns(attachments, "mail_attachment", db)
            for row in attachments.rows {
                guard try !exists("mail_attachment", id: attachments.value(row, "id"), db) else { continue }
                let messageID = attachments.value(row, "mail_message_id")
                guard try exists("mail_message", id: messageID, db) else { skip("mail_attachment: message gone"); continue }
                let part = String.fromDatabaseValue(attachments.value(row, "part")) ?? ""
                let duplicate =
                    part.isEmpty
                    ? try Bool.fetchOne(
                        db,
                        sql: #"SELECT EXISTS (SELECT 1 FROM "mail_attachment" WHERE "mail_message_id" = ? AND "file_name" = ?)"#,
                        arguments: [messageID, attachments.value(row, "file_name")]
                    ) ?? false
                    : try Bool.fetchOne(
                        db,
                        sql: #"SELECT EXISTS (SELECT 1 FROM "mail_attachment" WHERE "mail_message_id" = ? AND "part" = ?)"#,
                        arguments: [messageID, part]
                    ) ?? false
                guard !duplicate else { skip("mail_attachment: already there"); continue }
                try insert(
                    "mail_attachment", columns: columns, from: attachments, row: row,
                    overrides: ["blob_sha256": "".databaseValue, "blob_path": "".databaseValue],
                    db
                )
                restored("mail_attachment")
            }
        }
        return outcome
    }

    /// The source's columns the live table also has.
    private static func sharedColumns(_ source: SourceTable, _ table: String, _ db: Database) throws -> [String] {
        let live = Set(try db.columns(in: table).map(\.name))
        return source.columns.filter { live.contains($0) }
    }

    private static func exists(_ table: String, id: DatabaseValue, _ db: Database) throws -> Bool {
        guard !id.isNull else { return false }
        return try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM \(quoted(table)) WHERE \"id\" = ?)", arguments: [id]) ?? false
    }

    /// A plain INSERT of `columns` (values from the source row unless overridden).
    private static func insert(
        _ table: String, columns: [String], from source: SourceTable, row: [DatabaseValue],
        overrides: [String: DatabaseValue] = [:], _ db: Database
    ) throws {
        let names = columns.map(quoted).joined(separator: ", ")
        let marks = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let values = columns.map { overrides[$0] ?? source.value(row, $0) }
        try db.execute(sql: "INSERT INTO \(quoted(table)) (\(names)) VALUES (\(marks))", arguments: StatementArguments(values))
    }

    static func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

enum RestoreLog {
    static let restore = Log.logger(category: "Restore")
}
