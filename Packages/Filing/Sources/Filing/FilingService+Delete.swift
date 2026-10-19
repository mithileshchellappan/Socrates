import Foundation
import GRDB
import StudyCore

/// A delete that can be taken back (Edit > Undo): the rows it removed or unlinked, the jobs it
/// stopped and the files it left for `removeDeletedBlobs()`.
public struct Deletion: Sendable {
    public let item: LibraryItem
    public let summary: DeletionSummary
    let rows: DeletedRows
    /// Jobs that were queued or running for the deleted recordings: queued again on restore.
    let jobs: [Job.ID]
    /// Files the deleted rows used, removed once the undo window passes.
    let blobs: [BlobRef]
}

extension FilingService {
    // MARK: - Delete with Undo

    /// What deleting `item` takes with it, for the confirmation. Reads only.
    public func deletionSummary(_ item: LibraryItem) async throws -> DeletionSummary {
        try await services.database.read { db in
            let plan = try Self.deletionPlan(item, in: db)
            let rows = try DeletedRows.collect(plan.selectors, in: db)
            return try Self.summary(item, rows: rows, in: db)
        }
    }

    /// Deletes a deck, a lecture or a recording in one transaction and returns what Undo needs.
    ///
    /// - A deck goes with its pages, its ink and the notes pinned to its pages; the lectures it
    ///   was linked to re-align their remaining decks.
    /// - A lecture goes with its recordings (transcripts, slide stamps), notes, flags, study pass,
    ///   practice questions and their answers; its decks go too unless another lecture links them.
    /// - A recording goes with its transcript, slide stamps and timed spans (its running job is
    ///   stopped first); notes and flags on it stay on the lecture.
    ///
    /// Every row an `ON DELETE CASCADE` removes is kept in the result, and every `SET NULL` it
    /// clears is noted, so `restore(_:)` puts the library back exactly. Files are never removed
    /// here: they wait in the pending list until `removeDeletedBlobs()` (next session).
    public func delete(_ item: LibraryItem) async throws -> Deletion {
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
            let rows = try DeletedRows.collect(plan.selectors, in: db)
            let summary = try Self.summary(item, rows: rows, in: db)
            var blobs: [BlobRef] = []
            for deckID in plan.decks {
                if let blob = try Deck.find(deckID).fetchOne(db)?.blob { blobs.append(blob) }
            }
            blobs += try RecordingSegment.where { $0.recordingID.in(plan.recordings) }.fetchAll(db).compactMap(\.blob)

            // Lectures that keep their other decks re-align against them.
            for (deckID, lectureID) in plan.unlinks {
                try Self.unlinkDeck(deckID, from: lectureID, in: db, store: store, now: now)
            }
            try rows.deleteRoots(in: db)
            return Deletion(item: item, summary: summary, rows: rows, jobs: unfinished.map(\.id), blobs: blobs)
        }
        addPendingBlobs(deletion.blobs)
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
        }
        if !plan.decks.isEmpty {
            plan.selectors.append(.init(table: "deck", column: "id", values: plan.decks))
            // The student's notes on the deck's pages go with it (the confirmation says so).
            plan.selectors.append(.init(table: "note", column: "deck_id", values: plan.decks))
        }
        if !plan.recordings.isEmpty {
            plan.selectors.append(.init(table: "recording", column: "id", values: plan.recordings))
        }
        return plan
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
        }
        let answered = Set(rows.values(of: "study_answer", column: "question_id"))
        let questions = rows.values(of: "study_question", column: "id").filter { answered.contains($0) }.count
        let slides = rows.values(of: "deck", column: "page_count").compactMap { Int.fromDatabaseValue($0) }.reduce(0, +)
        return DeletionSummary(
            title: title,
            slides: slides,
            recordings: rows.count(of: "recording"),
            notes: rows.count(of: "note"),
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
struct DeletedRows: Sendable {
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
}

extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0 ..< Swift.min($0 + size, count)] }
    }
}
