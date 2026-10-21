import Foundation
import GRDB
import StudyCore

/// A delete that can be taken back (Edit > Undo): the rows it removed or unlinked, the jobs it
/// stopped and the files it left for `removeDeletedBlobs()`. Codable, so a change the agent made
/// (`remove_course`) keeps it in its log row for Undo later (`encoded()`, `init(encoded:)`).
public struct Deletion: Sendable, Codable {
    public let item: LibraryItem
    public let summary: DeletionSummary
    let rows: DeletedRows
    /// Jobs that were queued or running for the deleted recordings: queued again on restore.
    let jobs: [Job.ID]
    /// Files the deleted rows used, removed once the undo window passes.
    let blobs: [BlobRef]

    /// The deletion as JSON (`agent_change.before.deletion`).
    public func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}

extension Deletion {
    /// A deletion `encoded()` kept.
    public init(encoded: String) throws {
        self = try JSONDecoder().decode(Deletion.self, from: Data(encoded.utf8))
    }
}

extension FilingService {
    // MARK: - Delete with Undo

    /// mr: the lectures that lose a deck when it is deleted (every lecture with a range of it), by
    /// when they were held: "DC Lecture 2", "DC Lecture 3". Reads only.
    public func lectureNames(usingDeck deckID: Deck.ID) async throws -> [String] {
        try await services.database.read { db in
            let ranges = try LectureSlides.lectures(usingDeck: deckID, in: db)
            var names: [String] = []
            for range in ranges {
                guard let lecture = try Lecture.find(range.lectureID).fetchOne(db) else { continue }
                let course = try Course.find(lecture.courseID).fetchOne(db)
                names.append(Self.lectureName(lecture, course: course))
            }
            return names
        }
    }

    /// "DC Lecture 2" (the course's short name), else the lecture's title, else "Lecture".
    static func lectureName(_ lecture: Lecture, course: Course?) -> String {
        let short = course.map { $0.shortName.isEmpty ? $0.name : $0.shortName } ?? ""
        if let number = lecture.number {
            return short.isEmpty ? String(localized: "Lecture \(number)") : String(localized: "\(short) Lecture \(number)")
        }
        if !lecture.title.isEmpty { return lecture.title }
        return String(localized: "Lecture")
    }

    /// What deleting `item` takes with it, for the confirmation. Reads only.
    public func deletionSummary(_ item: LibraryItem) async throws -> DeletionSummary {
        try await services.database.read { db in
            let plan = try Self.deletionPlan(item, in: db)
            let rows = try DeletedRows.collect(plan.selectors, in: db)
            return try Self.summary(item, rows: rows, in: db)
        }
    }

    /// Deletes a deck, a lecture, a recording or a course in one transaction and returns what Undo
    /// needs.
    ///
    /// - A deck goes with its pages, its ink and the notes pinned to its pages; the lectures it
    ///   was linked to re-align their remaining decks.
    /// - A lecture goes with its recordings (transcripts, slide stamps), notes, flags, study pass,
    ///   practice questions and their answers; its decks go too unless another lecture links them.
    /// - A recording goes with its transcript, slide stamps and timed spans (its running job is
    ///   stopped first); notes and flags on it stay on the lecture.
    /// - A course goes with its lectures (as above), its decks (unless a lecture of another course
    ///   links them), recordings, sessions and weekly slots, items, mail rules, plan blocks,
    ///   practice and search chunks. The student's notes stay, unlinked from it and its lectures.
    ///   mt: its materials (with their sections and coverage) and the role-material documents no
    ///   other course's material uses (their pages; the files wait like a deck's).
    ///
    /// Every row an `ON DELETE CASCADE` removes is kept in the result, and every `SET NULL` it
    /// clears is noted, so `restore(_:)` puts the library back exactly. Files are never removed
    /// here: they wait in the pending list until `removeDeletedBlobs()` (next session), or, with
    /// `keepsFiles` (a deletion whose Undo outlives the session), stay.
    public func delete(_ item: LibraryItem, keepsFiles: Bool = false) async throws -> Deletion {
        let recordings = try await services.database.read { db in
            try Self.deletionPlan(item, in: db).recordings
        }
        let ids: [Recording.ID?] = recordings.map { $0 }
        let unfinished: [Job] = try await services.database.read { db in
            try Job.where { $0.recordingID.in(ids) && ($0.state.eq(JobState.queued) || $0.state.eq(JobState.running)) }
                .fetchAll(db)
        }
        let running = Set(unfinished.filter { $0.state == .running }.compactMap { $0.recordingID })
        for recordingID in running.sorted(by: { $0.uuidString < $1.uuidString }) {
            await cancelJobs(recordingID)
        }
        let now = now()
        let store = store
        let deletion = try await services.database.write { db -> Deletion in
            let plan = try Self.deletionPlan(item, in: db)
            // The student's notes on a deleted course's lectures stay: unlinked before the cascade.
            let kept = try DeletedRows.unlinkNotes(of: plan.keptNotesOf, in: db)
            var rows = try DeletedRows.collect(plan.selectors, in: db)
            rows.cleared += kept
            let summary = try Self.summary(item, rows: rows, in: db)
            var blobs: [BlobRef] = []
            for deckID in plan.decks {
                if let blob = try Deck.find(deckID).fetchOne(db)?.blob { blobs.append(blob) }
            }
            // mt: the course's material documents that go with it.
            for documentID in plan.documents {
                if let blob = try StudyDocument.find(documentID).fetchOne(db)?.blob { blobs.append(blob) }
            }
            blobs += try RecordingSegment.where { $0.recordingID.in(plan.recordings) }.fetchAll(db).compactMap(\.blob)

            // Lectures that keep their other decks re-align against them.
            for (deckID, lectureID) in plan.unlinks {
                try Self.unlinkDeck(deckID, from: lectureID, in: db, store: store, now: now)
            }
            try rows.deleteRoots(in: db)
            return Deletion(item: item, summary: summary, rows: rows, jobs: unfinished.map(\.id), blobs: blobs)
        }
        if !keepsFiles { addPendingBlobs(deletion.blobs) }
        Log.importer.info("Deleted \(String(describing: item), privacy: .public): \(deletion.rows.count, privacy: .public) row(s)")
        await afterImport()
        return deletion
    }

    /// Puts back everything `delete(_:)` removed, in one transaction: the rows (parents first,
    /// foreign keys checked at commit) and the references it cleared. Jobs it stopped are queued
    /// again, and its files leave the pending list.
    public func restore(_ deletion: Deletion) async throws {
        let now = now()
        let jobs = deletion.jobs
        try await services.database.write { db in
            try deletion.rows.restore(in: db)
            // Notes linked again (a course's): their chunks are written again with the links.
            let notes = deletion.rows.cleared.filter { $0.table == "note" }.compactMap(\.keyValues.first)
            for chunk in notes.chunked(400) {
                try db.execute(
                    sql: #"DELETE FROM "search_chunk" WHERE "note_id" IN (\#(DeletedRows.placeholders(chunk.count)))"#,
                    arguments: StatementArguments(Array(chunk))
                )
            }
            let queued = JobState.queued
            try Job.where { $0.id.in(jobs) && $0.state.neq(JobState.succeeded) }
                .update { $0.state = queued; $0.updatedAt = now }
                .execute(db)
        }
        removePendingBlobs(deletion.blobs)
        Log.importer.info("Restored \(String(describing: deletion.item), privacy: .public)")
        await afterImport()
    }

    /// Removes the files of deletions that can no longer be undone (the pending list from earlier
    /// sessions) once no row uses them. Called once per launch.
    public func removeDeletedBlobs() async {
        let pending = pendingBlobs()
        guard !pending.isEmpty else { return }
        var kept: [BlobRef] = []
        for blob in pending {
            let sha = blob.sha256
            // Deleted in this session: Edit > Undo can still bring it back.
            if deletedThisSession.contains(sha) {
                kept.append(blob)
                continue
            }
            let unused = (try? await services.database.read { db in try Self.blobIsUnused(sha, in: db) }) ?? false
            guard unused else { continue }
            do {
                try services.blobs.remove(blob)
            } catch {
                Log.importer.error("Removing a deleted file failed: \(String(describing: type(of: error)), privacy: .public)")
                kept.append(blob)
            }
        }
        // A delete during this pass (the actor is reentrant at each read) added to the list.
        let processed = Set(pending.map(\.sha256))
        savePendingBlobs(kept + pendingBlobs().filter { !processed.contains($0.sha256) })
        Log.importer.info("Removed \(pending.count - kept.count, privacy: .public) deleted file(s)")
    }

    /// No row uses the file with this hash (`BlobUsage`: decks, recording segments, mail
    /// attachments, readings, question sources, kept documents, note and chat attachments).
    static func blobIsUnused(_ sha256: String, in db: Database) throws -> Bool {
        try !BlobUsage.isUsed(sha256, in: db)
    }

    // MARK: - What a delete removes

    struct DeletionPlan {
        /// The rows deleted directly; the cascade takes the rest.
        var selectors: [DeletedRows.Selector] = []
        var decks: [Deck.ID] = []
        var recordings: [Recording.ID] = []
        /// Lecture links of a deleted deck (unlinked first so the lecture re-aligns).
        var unlinks: [(Deck.ID, Lecture.ID)] = []
        /// A deleted course's lectures: the student's notes on them stay, unlinked first.
        var keptNotesOf: [Lecture.ID] = []
        /// mt: a deleted course's role-material documents no other course's material uses.
        var documents: [StudyDocument.ID] = []
    }

    static func deletionPlan(_ item: LibraryItem, in db: Database) throws -> DeletionPlan {
        var plan = DeletionPlan()
        switch item {
        case .deck(let deckID):
            guard try Deck.find(deckID).fetchCount(db) > 0 else { throw FilingError.missing }
            plan.decks = [deckID]
            let lectures = try Set(LectureDeckSpan.where { $0.deckID.eq(deckID) }.fetchAll(db).map(\.lectureID))
            plan.unlinks = lectures.sorted { $0.uuidString < $1.uuidString }.map { (deckID, $0) }
        case .lecture(let lectureID):
            guard try Lecture.find(lectureID).fetchCount(db) > 0 else { throw FilingError.missing }
            plan.selectors.append(.init(table: "lecture", column: "id", values: [lectureID]))
            plan.recordings = try Recording.where { $0.lectureID.eq(lectureID) }.order(by: \.startedAt).fetchAll(db).map(\.id)
            let linked = try Set(LectureDeckSpan.where { $0.lectureID.eq(lectureID) }.fetchAll(db).map(\.deckID))
            for deckID in linked.sorted(by: { $0.uuidString < $1.uuidString }) {
                let elsewhere = try LectureDeckSpan.where { $0.deckID.eq(deckID) && $0.lectureID.neq(lectureID) }.fetchCount(db)
                if elsewhere == 0 { plan.decks.append(deckID) }
            }
        case .recording(let recordingID):
            guard let recording = try Recording.find(recordingID).fetchOne(db) else { throw FilingError.missing }
            plan.recordings = [recordingID]
            // Its timed spans (no orphan timeline stays) and a study pass built on it.
            plan.selectors.append(.init(table: "lecture_deck_span", column: "recording_id", values: [recordingID]))
            if let lectureID = recording.lectureID {
                let built = try Annotation
                    .where { $0.lectureID.eq(lectureID) && $0.recordingID.eq(recordingID) && $0.studyUnitID.isNot(nil) }
                    .fetchCount(db)
                if built > 0 { plan.selectors.append(.init(table: "study_unit", column: "lecture_id", values: [lectureID])) }
            }
        case .course(let courseID):
            guard try Course.find(courseID).fetchCount(db) > 0 else { throw FilingError.missing }
            let id = courseID.uuidString.lowercased()
            // The course: its slots, sessions, lectures, filings, mail rules, memory, plan blocks,
            // readings and practice go through the cascade.
            plan.selectors.append(.init(table: "course", column: "id", values: [courseID]))
            // Its items (deadlines, exercises, exams, tasks), which would only lose their course.
            plan.selectors.append(.init(table: "tracked_item", column: "course_id", values: [courseID]))
            plan.keptNotesOf = try String.fetchAll(db, sql: #"SELECT "id" FROM "lecture" WHERE "course_id" = ?"#, arguments: [id])
                .compactMap(UUID.init(uuidString:))
            plan.recordings = try String.fetchAll(db, sql: """
                SELECT "id" FROM "recording"
                WHERE "course_id" = ?1 OR "lecture_id" IN (SELECT "id" FROM "lecture" WHERE "course_id" = ?1)
                ORDER BY "started_at"
                """, arguments: [id]).compactMap(UUID.init(uuidString:))
            // Its decks and those only its lectures use; a deck a lecture of another course links stays.
            plan.decks = try String.fetchAll(db, sql: """
                SELECT d."id" FROM "deck" d
                WHERE (d."course_id" = ?1 OR EXISTS (
                    SELECT 1 FROM "lecture_deck_span" s JOIN "lecture" l ON l."id" = s."lecture_id"
                    WHERE s."deck_id" = d."id" AND l."course_id" = ?1))
                  AND NOT EXISTS (
                    SELECT 1 FROM "lecture_deck_span" s JOIN "lecture" l ON l."id" = s."lecture_id"
                    WHERE s."deck_id" = d."id" AND l."course_id" <> ?1)
                ORDER BY d."imported_at"
                """, arguments: [id]).compactMap(UUID.init(uuidString:))
            // mt: its materials go through the cascade; the documents of their files and
            // snapshots go too unless a material of another course uses them.
            plan.documents = try Self.materialDocuments(ofCourse: id, in: db)
            if !plan.documents.isEmpty {
                plan.selectors.append(.init(table: "document", column: "id", values: plan.documents))
            }
        }
        if !plan.decks.isEmpty {
            plan.selectors.append(.init(table: "deck", column: "id", values: plan.decks))
            // The student's notes on the deck's pages go with it (the confirmation says so); a
            // course's stay.
            if !item.isCourse {
                plan.selectors.append(.init(table: "note", column: "deck_id", values: plan.decks))
            }
        }
        if !plan.recordings.isEmpty {
            plan.selectors.append(.init(table: "recording", column: "id", values: plan.recordings))
        }
        return plan
    }

    /// mt: the role-material documents of a course's materials that no other course's material
    /// uses (a course delete takes them with it).
    static func materialDocuments(ofCourse id: String, in db: Database) throws -> [StudyDocument.ID] {
        try String.fetchAll(db, sql: """
            SELECT DISTINCT d."id" FROM "document" d
            JOIN "course_material" m ON m."document_id" = d."id"
            WHERE m."course_id" = ?1 AND d."role" = 'material'
              AND NOT EXISTS (SELECT 1 FROM "course_material" o WHERE o."document_id" = d."id" AND o."course_id" <> ?1)
            ORDER BY d."added_at"
            """, arguments: [id]).compactMap(UUID.init(uuidString:))
    }

    /// mt: how many materials a course delete takes (the confirmation's "4 materials"); 0 for
    /// anything but a course.
    public func materialCount(_ item: LibraryItem) async throws -> Int {
        guard case .course(let courseID) = item else { return 0 }
        return try await services.database.read { db in
            try CourseMaterial.where { $0.courseID.eq(courseID) }.fetchCount(db)
        }
    }

    static func summary(_ item: LibraryItem, rows: DeletedRows, in db: Database) throws -> DeletionSummary {
        let title: String
        switch item {
        case .deck(let id):
            let deck = try Deck.find(id).fetchOne(db)
            title = deck.map { $0.title.isEmpty ? ($0.fileName as NSString).deletingPathExtension : $0.title } ?? ""
        case .lecture(let id):
            let lecture = try Lecture.find(id).fetchOne(db)
            let number = lecture?.number.map { String(localized: "Lecture \($0)") }
            let name = lecture?.title ?? ""
            let joined = [number, name.isEmpty ? nil : name].compactMap(\.self).joined(separator: " · ")
            title = joined.isEmpty ? String(localized: "Lecture") : joined
        case .recording(let id):
            let started = try Recording.find(id).fetchOne(db)?.startedAt
            title = started.map { String(localized: "Recording of \($0.formatted(date: .abbreviated, time: .shortened))") }
                ?? String(localized: "Recording")
        case .course(let id):
            let name = try Course.find(id).fetchOne(db)?.name ?? ""
            title = name.isEmpty ? String(localized: "Course") : name
        }
        let answered = Set(rows.values(of: "study_answer", column: "question_id"))
        let questions = rows.values(of: "study_question", column: "id").filter { answered.contains($0) }.count
        let slides = rows.values(of: "deck", column: "page_count").compactMap { Int.fromDatabaseValue($0) }.reduce(0, +)
        return DeletionSummary(
            title: title,
            lectures: rows.count(of: "lecture"),
            slides: slides,
            recordings: rows.count(of: "recording"),
            // A course's notes stay (the read-only summary's cascade still reaches its lectures').
            notes: item.isCourse ? 0 : rows.count(of: "note"),
            inkPages: rows.count(of: "slide_ink"),
            practisedQuestions: questions
        )
    }

    // MARK: - Pending file removals

    private var pendingBlobsURL: URL { services.paths.root.appending(path: "PendingBlobRemovals.json") }

    func pendingBlobs() -> [BlobRef] {
        guard let data = try? Data(contentsOf: pendingBlobsURL) else { return [] }
        return (try? JSONDecoder().decode([BlobRef].self, from: data)) ?? []
    }

    private func savePendingBlobs(_ blobs: [BlobRef]) {
        do {
            if blobs.isEmpty {
                if FileManager.default.fileExists(atPath: pendingBlobsURL.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: pendingBlobsURL)
                }
                return
            }
            try JSONEncoder().encode(blobs).write(to: pendingBlobsURL, options: .atomic)
        } catch {
            Log.importer.error("Saving the deleted files list failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func addPendingBlobs(_ blobs: [BlobRef]) {
        guard !blobs.isEmpty else { return }
        deletedThisSession.formUnion(blobs.map(\.sha256))
        var pending = pendingBlobs()
        let known = Set(pending.map(\.sha256))
        pending += blobs.filter { !known.contains($0.sha256) }
        savePendingBlobs(pending)
    }

    private func removePendingBlobs(_ blobs: [BlobRef]) {
        guard !blobs.isEmpty else { return }
        let restored = Set(blobs.map(\.sha256))
        savePendingBlobs(pendingBlobs().filter { !restored.contains($0.sha256) })
    }
}

// MARK: - Rows a delete removes

/// The rows a delete removes, found generically from the schema: the selected roots and,
/// through every `ON DELETE CASCADE` foreign key (`PRAGMA foreign_key_list`), everything that
/// goes with them; plus every `ON DELETE SET NULL` reference from a row that stays.
struct DeletedRows: Sendable, Codable {
    /// Rows of `table` whose `column` is one of `values`.
    struct Selector: Sendable {
        var table: String
        var column: String
        var values: [DatabaseValue]

        init(table: String, column: String, values: [UUID]) {
            self.table = table
            self.column = column
            self.values = values.map { $0.uuidString.lowercased().databaseValue }
        }

        init(table: String, column: String, databaseValues: [DatabaseValue]) {
            self.table = table
            self.column = column
            self.values = databaseValues
        }
    }

    struct Rows: Sendable {
        var table: String
        var columns: [String]
        var key: [String]
        var rows: [[DatabaseValue]]
    }

    /// A reference SQLite cleared (`SET NULL`) on a row that stays.
    struct Cleared: Sendable {
        var table: String
        var key: [String]
        var keyValues: [DatabaseValue]
        var column: String
        var value: DatabaseValue
    }

    /// Derived search rows: not kept (the search index rebuilds them for restored rows).
    static let derivedTables: Set<String> = ["search_chunk", "search_vector"]

    /// In discovery order: roots first, then what hangs off them (parents before children).
    var groups: [Rows] = []
    var cleared: [Cleared] = []
    /// The rows deleted directly.
    var roots: [Selector] = []

    var count: Int { groups.reduce(0) { $0 + $1.rows.count } }

    func count(of table: String) -> Int {
        groups.filter { $0.table == table }.reduce(0) { $0 + $1.rows.count }
    }

    func values(of table: String, column: String) -> [DatabaseValue] {
        groups.filter { $0.table == table }.flatMap { group -> [DatabaseValue] in
            guard let index = group.columns.firstIndex(of: column) else { return [] }
            return group.rows.map { $0[index] }
        }
    }

    // MARK: Collecting

    struct Edge {
        var child: String
        var from: String
        var to: String
        var onDelete: String
    }

    struct RowKey: Hashable {
        var table: String
        var key: [DatabaseValue]
    }

    static func collect(_ selectors: [Selector], in db: Database) throws -> DeletedRows {
        var result = DeletedRows()
        result.roots = selectors
        // The schema's foreign keys, by parent table (single-column keys; the schema has no others).
        var edges: [String: [Edge]] = [:]
        var keys: [String: [String]] = [:]
        let tables = try String.fetchAll(db, sql: """
            SELECT "name" FROM "sqlite_master" WHERE "type" = 'table' AND "name" NOT LIKE 'sqlite_%'
              AND "sql" NOT LIKE 'CREATE VIRTUAL TABLE%'
            """)
        func primaryKey(_ table: String) throws -> [String] {
            if let key = keys[table] { return key }
            let key = try db.primaryKey(table).columns
            keys[table] = key
            return key
        }
        for table in tables {
            let rows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table.quotedDatabaseIdentifier))")
            let byID = Dictionary(grouping: rows) { $0["id"] as Int }
            for (_, parts) in byID where parts.count == 1 {
                guard let part = parts.first else { continue }
                let parent: String = part["table"]
                let to: String? = part["to"]
                edges[parent, default: []].append(Edge(
                    child: table, from: part["from"], to: try to ?? primaryKey(parent).first ?? "rowid", onDelete: part["on_delete"]
                ))
            }
        }

        var seen = Set<RowKey>()
        var pending = selectors
        while !pending.isEmpty {
            let selector = pending.removeFirst()
            guard !derivedTables.contains(selector.table), !selector.values.isEmpty else { continue }
            let key = try primaryKey(selector.table)
            var found: [Row] = []
            for chunk in selector.values.chunked(400) {
                found += try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM \(selector.table.quotedDatabaseIdentifier) WHERE \(selector.column.quotedDatabaseIdentifier) IN (\(placeholders(chunk.count)))",
                    arguments: StatementArguments(chunk)
                )
            }
            let fresh = found.filter { row in
                seen.insert(RowKey(table: selector.table, key: key.map { row[$0] as DatabaseValue })).inserted
            }
            guard let first = fresh.first else { continue }
            result.groups.append(Rows(
                table: selector.table, columns: Array(first.columnNames), key: key, rows: fresh.map { Array($0.databaseValues) }
            ))
            for edge in edges[selector.table] ?? [] where edge.onDelete.uppercased() == "CASCADE" {
                let values = fresh.map { $0[edge.to] as DatabaseValue }.filter { !$0.isNull }
                if !values.isEmpty { pending.append(Selector(table: edge.child, column: edge.from, databaseValues: values)) }
            }
        }

        // References from rows that stay, which the delete clears.
        for group in result.groups {
            for edge in edges[group.table] ?? [] where edge.onDelete.uppercased() == "SET NULL" && !derivedTables.contains(edge.child) {
                guard let index = group.columns.firstIndex(of: edge.to) else { continue }
                let values = group.rows.map { $0[index] }.filter { !$0.isNull }
                guard !values.isEmpty else { continue }
                let key = try primaryKey(edge.child)
                let selected = (key + [edge.from]).map(\.quotedDatabaseIdentifier).joined(separator: ", ")
                for chunk in values.chunked(400) {
                    for row in try Row.fetchAll(
                        db,
                        sql: "SELECT \(selected) FROM \(edge.child.quotedDatabaseIdentifier) WHERE \(edge.from.quotedDatabaseIdentifier) IN (\(placeholders(chunk.count)))",
                        arguments: StatementArguments(chunk)
                    ) {
                        let keyValues = key.map { row[$0] as DatabaseValue }
                        guard !seen.contains(RowKey(table: edge.child, key: keyValues)) else { continue }
                        result.cleared.append(Cleared(
                            table: edge.child, key: key, keyValues: keyValues, column: edge.from, value: row[edge.from]
                        ))
                    }
                }
            }
        }
        return result
    }

    // MARK: Deleting and restoring

    /// Deletes the root rows; the schema's cascades remove the rest.
    func deleteRoots(in db: Database) throws {
        for root in roots.reversed() where !root.values.isEmpty {
            for chunk in root.values.chunked(400) {
                try db.execute(
                    sql: "DELETE FROM \(root.table.quotedDatabaseIdentifier) WHERE \(root.column.quotedDatabaseIdentifier) IN (\(Self.placeholders(chunk.count)))",
                    arguments: StatementArguments(chunk)
                )
            }
        }
    }

    /// Upserts every kept row (parents first) and puts the cleared references back where they
    /// are still empty. Foreign keys are checked when the transaction commits.
    func restore(in db: Database) throws {
        try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
        for group in groups {
            let columns = group.columns.map(\.quotedDatabaseIdentifier)
            let updates = group.columns.filter { !group.key.contains($0) }
                .map { "\($0.quotedDatabaseIdentifier) = excluded.\($0.quotedDatabaseIdentifier)" }
            let conflict = updates.isEmpty
                ? "DO NOTHING"
                : "DO UPDATE SET \(updates.joined(separator: ", "))"
            let target = group.key.map(\.quotedDatabaseIdentifier).joined(separator: ", ")
            let sql = """
                INSERT INTO \(group.table.quotedDatabaseIdentifier) (\(columns.joined(separator: ", ")))
                VALUES (\(Self.placeholders(columns.count))) ON CONFLICT (\(target)) \(conflict)
                """
            let statement = try db.cachedStatement(sql: sql)
            for row in group.rows {
                try statement.execute(arguments: StatementArguments(row))
            }
        }
        for reference in cleared {
            let condition = reference.key.map { "\($0.quotedDatabaseIdentifier) = ?" }.joined(separator: " AND ")
            try db.execute(
                sql: """
                    UPDATE \(reference.table.quotedDatabaseIdentifier) SET \(reference.column.quotedDatabaseIdentifier) = ?
                    WHERE \(condition) AND \(reference.column.quotedDatabaseIdentifier) IS NULL
                    """,
                arguments: StatementArguments([reference.value] + reference.keyValues)
            )
        }
    }

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// Clears the lecture link of the student's notes on `lectures` (a course being deleted keeps
    /// them) and returns the links, for restore.
    static func unlinkNotes(of lectures: [Lecture.ID], in db: Database) throws -> [Cleared] {
        var cleared: [Cleared] = []
        for chunk in lectures.map({ $0.uuidString.lowercased().databaseValue }).chunked(400) {
            let arguments = StatementArguments(Array(chunk))
            for row in try Row.fetchAll(
                db, sql: #"SELECT "id", "lecture_id" FROM "note" WHERE "lecture_id" IN (\#(placeholders(chunk.count)))"#, arguments: arguments
            ) {
                let id: DatabaseValue = row["id"]
                let lecture: DatabaseValue = row["lecture_id"]
                cleared.append(Cleared(table: "note", key: ["id"], keyValues: [id], column: "lecture_id", value: lecture))
            }
            try db.execute(sql: #"UPDATE "note" SET "lecture_id" = NULL WHERE "lecture_id" IN (\#(placeholders(chunk.count)))"#, arguments: arguments)
        }
        return cleared
    }
}

// MARK: - Kept deletions

/// A database value in a kept deletion: `{"i": 1}`, `{"r": 1.5}`, `{"s": "…"}`, `{"b": "<base64>"}`,
/// `{}` for NULL (the storage class survives, as STRICT tables need).
private struct StoredValue: Codable {
    var value: DatabaseValue

    init(_ value: DatabaseValue) { self.value = value }

    private enum Key: String, CodingKey { case i, r, s, b }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        if let int = try container.decodeIfPresent(Int64.self, forKey: .i) {
            value = int.databaseValue
        } else if let real = try container.decodeIfPresent(Double.self, forKey: .r) {
            value = real.databaseValue
        } else if let text = try container.decodeIfPresent(String.self, forKey: .s) {
            value = text.databaseValue
        } else if let data = try container.decodeIfPresent(Data.self, forKey: .b) {
            value = data.databaseValue
        } else {
            value = .null
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch value.storage {
        case .null: break
        case .int64(let int): try container.encode(int, forKey: .i)
        case .double(let real): try container.encode(real, forKey: .r)
        case .string(let text): try container.encode(text, forKey: .s)
        case .blob(let data): try container.encode(data, forKey: .b)
        }
    }
}

extension DeletedRows.Selector: Codable {
    private enum CodingKeys: String, CodingKey { case table, column, values }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            table: try container.decode(String.self, forKey: .table),
            column: try container.decode(String.self, forKey: .column),
            databaseValues: try container.decode([StoredValue].self, forKey: .values).map(\.value)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(table, forKey: .table)
        try container.encode(column, forKey: .column)
        try container.encode(values.map(StoredValue.init), forKey: .values)
    }
}

extension DeletedRows.Rows: Codable {
    private enum CodingKeys: String, CodingKey { case table, columns, key, rows }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            table: try container.decode(String.self, forKey: .table),
            columns: try container.decode([String].self, forKey: .columns),
            key: try container.decode([String].self, forKey: .key),
            rows: try container.decode([[StoredValue]].self, forKey: .rows).map { $0.map(\.value) }
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(table, forKey: .table)
        try container.encode(columns, forKey: .columns)
        try container.encode(key, forKey: .key)
        try container.encode(rows.map { $0.map(StoredValue.init) }, forKey: .rows)
    }
}

extension DeletedRows.Cleared: Codable {
    private enum CodingKeys: String, CodingKey { case table, key, keyValues, column, value }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            table: try container.decode(String.self, forKey: .table),
            key: try container.decode([String].self, forKey: .key),
            keyValues: try container.decode([StoredValue].self, forKey: .keyValues).map(\.value),
            column: try container.decode(String.self, forKey: .column),
            value: try container.decode(StoredValue.self, forKey: .value).value
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(table, forKey: .table)
        try container.encode(key, forKey: .key)
        try container.encode(keyValues.map(StoredValue.init), forKey: .keyValues)
        try container.encode(column, forKey: .column)
        try container.encode(StoredValue(value), forKey: .value)
    }
}

extension LibraryItem {
    var isCourse: Bool {
        if case .course = self { return true }
        return false
    }
}

extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0 ..< Swift.min($0 + size, count)] }
    }
}
