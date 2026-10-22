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
/// - `weekly_slot`: when its course exists and has no class times again, and no `slot_remove`
///   change (not undone) names it. A course with any live slot, or with a slot change the agent
///   logged after the copy was made (undone or not), has had its class times set since: none of
///   its slots, sessions or links come back, since an old slot beside a re-entered one at another
///   minute or of another kind would double every class (Course Settings logs no change, so only
///   the live slots show its edits). A course that kept some slots gets none of the others back;
///   both copies keep them;
/// - `lecture_session.weekly_slot_id`: set again where the delete cleared it (a slot restored
///   here, same course, still NULL), without stamping `updated_at` (the calendar event does not
///   show the slot);
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
/// upload. Before writing, the library is copied once to `AppPaths.preRestoreBackup`
/// (`LibraryCopy.copy`); an existing copy is kept, so a retry never replaces it.
///
/// Only a copy made before parent references were dropped (`parentReferencesDroppedAt`) is a
/// source: a library that first synced later lost nothing this way, and its copy would only bring
/// back what the student deleted since.
///
/// `runOnce(replan:)` restores once per library and then replans the courses it changed; `run()`
/// is idempotent: a second run finds every row present, or its course with class times again.
/// Logs table names and counts only (category "sync.restore").
public struct LibraryRestore: Sendable {
    /// Replans one course and counts the sessions it inserted, updated and deleted (the app passes
    /// Course Settings' `CourseSchedule.replan`).
    public typealias Replan = @Sendable (Course.ID) async throws -> (inserted: Int, updated: Int, deleted: Int)

    struct Outcome: Sendable {
        /// Rows inserted, by table.
        var restored: [String: Int] = [:]
        /// Sessions whose slot link was set again.
        var relinkedSessions = 0
        /// Rows missing from the live library and left out, by reason.
        var skipped: [String: Int] = [:]
        /// Courses whose slots or sessions changed (to replan).
        var courses: Set<Course.ID> = []
    }

    enum Failure: Error {
        /// Not enough free disk for the copy before restoring.
        case lowDisk
    }

    private let database: any DatabaseWriter
    /// The library copy to restore from (read-only).
    private let source: URL
    /// Where the live library is copied before the first restore.
    private let copy: URL

    public init(services: StudyServices) {
        database = services.database
        source = services.paths.preSyncBackup
        copy = services.paths.preRestoreBackup
    }

    /// The build that made every synced table private (no parent references) dates from here
    /// (2026-10-22 03:06:07 UTC); a copy made later comes from a library whose first upload
    /// deleted nothing.
    private static let parentReferencesDroppedAt = Date(timeIntervalSince1970: 1_792_638_367)

    /// Set once the rows were restored, or once a launch found no copy from before the first sync
    /// or only one made after parent references were dropped (`hasSource`: a library that syncs
    /// for the first time later never restores from that newer copy, which would bring back rows
    /// deleted since).
    private static let restoredKey = "Socrates.restoredRowsLostToFirstSync"

    /// The courses the restore changed that still wait for their replan (ids).
    private static let replanKey = "Socrates.replanAfterRestore"

    /// True when the copy to restore from exists and was made before parent references were
    /// dropped (its file date; an unknown date counts as before).
    var hasSource: Bool {
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else { return false }
        return LibraryCopy.fileDate(source).map { $0 < Self.parentReferencesDroppedAt } ?? true
    }

    /// `run()` on the first launch with it, then the courses it changed are replanned (`replan`:
    /// numbers, and sessions held by slot and day; a plan already right writes nothing). A failed
    /// restore (logged) leaves `restoredKey` unset: the next launch tries again, and rows already
    /// back are found present. The courses to replan are kept until each replan succeeds, so a
    /// failed one is tried again at the next launch.
    @concurrent
    public func runOnce(replan: Replan) async {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.restoredKey) {
            if hasSource {
                let outcome: Outcome
                do {
                    outcome = try await run()
                } catch {
                    SyncLog.restore.error("Restoring rows failed: \(String(describing: type(of: error)), privacy: .public)")
                    return
                }
                if !outcome.courses.isEmpty {
                    defaults.set(outcome.courses.map(\.uuidString), forKey: Self.replanKey)
                }
            }
            defaults.set(true, forKey: Self.restoredKey)
        }
        await Self.replanPending(replan)
    }

    /// Replans the courses `replanKey` holds; the ones whose replan failed stay for the next launch.
    private static func replanPending(_ replan: Replan) async {
        let defaults = UserDefaults.standard
        let pending = defaults.stringArray(forKey: replanKey) ?? []
        guard !pending.isEmpty else { return }
        var failed: [String] = []
        var inserted = 0, updated = 0, deleted = 0
        for text in pending {
            guard let course = Course.ID(uuidString: text) else { continue }
            do {
                let plan = try await replan(course)
                inserted += plan.inserted
                updated += plan.updated
                deleted += plan.deleted
            } catch {
                failed.append(text)
                SyncLog.restore.error("Replanning a restored course failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        let retry = failed.isEmpty ? "" : ", \(failed.count) again at the next launch"
        SyncLog.restore.notice(
            "Replanned \(pending.count - failed.count, privacy: .public) restored course(s): +\(inserted, privacy: .public) ~\(updated, privacy: .public) -\(deleted, privacy: .public)\(retry, privacy: .public)"
        )
        if failed.isEmpty {
            defaults.removeObject(forKey: replanKey)
        } else {
            defaults.set(failed, forKey: replanKey)
        }
    }

    /// Restores from `source` (`hasSource` said it is one): copies the live library first unless
    /// that copy exists, then writes in one transaction and logs the counts.
    func run() async throws -> Outcome {
        if !FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) {
            guard LibraryCopy.hasRoom(for: database) else { throw Failure.lowDisk }
            try LibraryCopy.copy(database, to: copy)
        }
        let snapshot = try Snapshot.read(source)
        let stamp = Date()
        let outcome = try await database.write { db in try Self.apply(snapshot, now: stamp, db: db) }
        let restored = Self.restoredTables
            .map { table -> String in
                let count = outcome.restored[table] ?? 0
                return table == LectureSession.tableName ? "\(table) \(count) (+\(outcome.relinkedSessions) relinked)" : "\(table) \(count)"
            }
            .joined(separator: ", ")
        SyncLog.restore.notice("Restored from the copy before the first sync: \(restored, privacy: .public)")
        let reasons: [String] = outcome.skipped.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
        let skipped: String = reasons.isEmpty ? "none" : reasons.joined(separator: ", ")
        SyncLog.restore.notice("Not restored: \(skipped, privacy: .public)")
        return outcome
    }

    // MARK: - Source

    static let restoredTables = [WeeklySlot.tableName, LectureSession.tableName, SlideInk.tableName, MailAttachment.tableName]

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
        /// When the copy was made (nil: unknown, so every logged slot change counts as later).
        var copiedAt: Date?

        /// Reads the source as a plain read-only queue: never migrated, no metadatabase.
        static func read(_ url: URL) throws -> Snapshot {
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(path: url.path(percentEncoded: false), configuration: configuration)
            defer { try? queue.close() }
            let copiedAt = LibraryCopy.fileDate(url)
            return try queue.read { db in
                var snapshot = Snapshot(copiedAt: copiedAt)
                for table in LibraryRestore.restoredTables {
                    guard try db.tableExists(table) else { continue }
                    let columns = try db.columns(in: table).map(\.name)
                    let list = columns.map(LibraryRestore.quoted).joined(separator: ", ")
                    let rows = try Row.fetchAll(db, sql: "SELECT \(list) FROM \(LibraryRestore.quoted(table))")
                        .map { Array($0.databaseValues) }
                    snapshot.tables[table] = SourceTable(columns: columns, rows: rows)
                }
                for table in [Lecture.tableName, Filing.tableName] {
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
        func parsedCourseID(_ value: DatabaseValue) -> Course.ID? { String.fromDatabaseValue(value).flatMap(Course.ID.init(uuidString:)) }
        func course(_ value: DatabaseValue) {
            if let id = parsedCourseID(value) { outcome.courses.insert(id) }
        }
        // Decided before anything is inserted: a course whose slots come back here has none yet.
        let settled = try coursesWithClassTimesSince(snapshot.copiedAt, db)

        // a) Weekly slots. slotMap: source slot id → the slot restored for it.
        var slotMap: [String: String] = [:]
        var slotCourse: [String: DatabaseValue] = [:]
        if let slots = snapshot.tables[WeeklySlot.tableName] {
            let columns = try sharedColumns(slots, WeeklySlot.tableName, db)
            for row in slots.rows {
                let idValue = slots.value(row, "id")
                guard let id = String.fromDatabaseValue(idValue) else { continue }
                let courseID = slots.value(row, "course_id")
                slotCourse[id] = courseID
                guard try !exists(WeeklySlot.tableName, id: idValue, db) else { continue }
                if let reason = parsedCourseID(courseID).flatMap({ settled[$0] }) { skip("weekly_slot: \(reason)"); continue }
                guard try exists(Course.tableName, id: courseID, db) else { skip("weekly_slot: course gone"); continue }
                let removed = try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS (SELECT 1 FROM \(quoted(AgentChange.tableName))
                        WHERE "kind" = ? AND "target_id" = ? AND "undone_at" IS NULL)
                        """,
                    arguments: [AgentChangeKind.slotRemove.rawValue, idValue]
                ) ?? false
                guard !removed else { skip("weekly_slot: removed by the agent"); continue }
                try insert(WeeklySlot.tableName, columns: columns, from: slots, row: row, db)
                slotMap[id] = id
                restored(WeeklySlot.tableName)
                course(courseID)
            }
        }

        guard let sessions = snapshot.tables[LectureSession.tableName] else { return outcome }

        // b) Sessions whose slot link the delete cleared get it again (no `updated_at` stamp: the
        // calendar event does not show the slot, so it stays in step).
        for row in sessions.rows {
            guard let slot = String.fromDatabaseValue(sessions.value(row, "weekly_slot_id")),
                let live = slotMap[slot], let slotCourseID = slotCourse[slot]
            else { continue }
            try db.execute(
                sql: """
                    UPDATE \(quoted(LectureSession.tableName)) SET "weekly_slot_id" = ?
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
        let sessionColumns = try sharedColumns(sessions, LectureSession.tableName, db)
        for row in sessions.rows {
            let idValue = sessions.value(row, "id")
            guard let id = String.fromDatabaseValue(idValue), try !exists(LectureSession.tableName, id: idValue, db) else { continue }
            guard let slot = String.fromDatabaseValue(sessions.value(row, "weekly_slot_id")), let live = slotMap[slot] else {
                let reason = parsedCourseID(sessions.value(row, "course_id")).flatMap { settled[$0] }
                skip("lecture_session: \(reason ?? "no slot")")
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
            guard try exists(Course.tableName, id: courseID, db) else { skip("lecture_session: course gone"); continue }
            guard !snapshot.filedSessions.contains(id) else { skip("lecture_session: filed"); continue }
            let starts = try DatabaseValue.fetchAll(
                db, sql: #"SELECT "starts_at" FROM \#(quoted(LectureSession.tableName)) WHERE "course_id" = ?"#, arguments: [courseID]
            )
            let clashes = starts.contains { value in
                Date.fromDatabaseValue(value).map { abs($0.timeIntervalSince(startsAt)) < 60 } ?? false
            }
            guard !clashes else { skip("lecture_session: clash"); continue }
            try insert(
                LectureSession.tableName, columns: sessionColumns, from: sessions, row: row,
                overrides: ["weekly_slot_id": live.databaseValue, "calendar_event_id": .null, "calendar_synced_at": .null],
                db
            )
            restored(LectureSession.tableName)
            course(courseID)
        }

        // d) Ink of a page that has none now.
        if let ink = snapshot.tables[SlideInk.tableName] {
            let columns = try sharedColumns(ink, SlideInk.tableName, db)
            for row in ink.rows {
                guard try !exists(SlideInk.tableName, id: ink.value(row, "id"), db) else { continue }
                let deckID = ink.value(row, "deck_id")
                guard try exists(Deck.tableName, id: deckID, db) else { skip("slide_ink: deck gone"); continue }
                let inked = try Bool.fetchOne(
                    db,
                    sql: #"SELECT EXISTS (SELECT 1 FROM \#(quoted(SlideInk.tableName)) WHERE "deck_id" = ? AND "page_number" = ?)"#,
                    arguments: [deckID, ink.value(row, "page_number")]
                ) ?? false
                guard !inked else { skip("slide_ink: page has ink"); continue }
                try insert(SlideInk.tableName, columns: columns, from: ink, row: row, db)
                restored(SlideInk.tableName)
            }
        }

        // e) Attachments of messages that still exist; their files are fetched again on open.
        if let attachments = snapshot.tables[MailAttachment.tableName] {
            let columns = try sharedColumns(attachments, MailAttachment.tableName, db)
            for row in attachments.rows {
                guard try !exists(MailAttachment.tableName, id: attachments.value(row, "id"), db) else { continue }
                let messageID = attachments.value(row, "mail_message_id")
                guard try exists(MailMessage.tableName, id: messageID, db) else { skip("mail_attachment: message gone"); continue }
                let part = String.fromDatabaseValue(attachments.value(row, "part")) ?? ""
                let duplicate =
                    part.isEmpty
                    ? try Bool.fetchOne(
                        db,
                        sql: #"SELECT EXISTS (SELECT 1 FROM \#(quoted(MailAttachment.tableName)) WHERE "mail_message_id" = ? AND "file_name" = ?)"#,
                        arguments: [messageID, attachments.value(row, "file_name")]
                    ) ?? false
                    : try Bool.fetchOne(
                        db,
                        sql: #"SELECT EXISTS (SELECT 1 FROM \#(quoted(MailAttachment.tableName)) WHERE "mail_message_id" = ? AND "part" = ?)"#,
                        arguments: [messageID, part]
                    ) ?? false
                guard !duplicate else { skip("mail_attachment: already there"); continue }
                try insert(
                    MailAttachment.tableName, columns: columns, from: attachments, row: row,
                    overrides: ["blob_sha256": "".databaseValue, "blob_path": "".databaseValue],
                    db
                )
                restored(MailAttachment.tableName)
            }
        }
        return outcome
    }

    /// Courses whose class times were set since the copy, with the reason: any live slot, or a
    /// slot the agent added, changed or removed after the copy was made (undone or not).
    static func coursesWithClassTimesSince(_ copiedAt: Date?, _ db: Database) throws -> [Course.ID: String] {
        var settled: [Course.ID: String] = [:]
        let since = copiedAt ?? .distantPast
        let changes = try Row.fetchAll(
            db,
            sql: """
                SELECT coalesce(
                    CASE WHEN json_valid("after") THEN json_extract("after", '$.courseID') END,
                    CASE WHEN json_valid("before") THEN json_extract("before", '$.courseID') END
                ) AS "course", "created_at"
                FROM \(quoted(AgentChange.tableName)) WHERE "kind" IN (?, ?, ?)
                """,
            arguments: [AgentChangeKind.slotAdd.rawValue, AgentChangeKind.slotChange.rawValue, AgentChangeKind.slotRemove.rawValue]
        )
        for change in changes {
            guard let text: String = change["course"], let id = Course.ID(uuidString: text) else { continue }
            let createdAt: Date? = change["created_at"]
            if createdAt.map({ $0 > since }) ?? true { settled[id] = "class times changed since the copy" }
        }
        for text in try String.fetchAll(db, sql: #"SELECT DISTINCT "course_id" FROM \#(quoted(WeeklySlot.tableName))"#) {
            if let id = Course.ID(uuidString: text) { settled[id] = "course has class times again" }
        }
        return settled
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
