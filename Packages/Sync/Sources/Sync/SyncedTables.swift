import Foundation
import StudyCore

/// The tables iCloud sync carries: every library table of `Schema.tableNames` except `job`
/// (device-local processing state: each device runs its own jobs) and the document bank
/// (`Schema.macOnlyTableNames`, md: documents never leave the Mac). The search index
/// (`Schema.localTableNames`, `Schema.virtualTableNames`) is rebuilt on each device and never
/// syncs. Blobs (decks, audio, images) are files, not rows, and do not sync in M7. The university
/// profile (`university_profile`, oss) syncs like any row; a device installs a synced profile
/// the next time it opens the library (`StudyDatabase.open`).
///
/// The record types appear twice, as a list (checked against the schema) and in the engine's
/// parameter pack; a new table goes into both.
enum SyncedTables {
    static let excluded = Set(["job"] + Schema.macOnlyTableNames)

    static var types: [any StudyRecord.Type] { [
        Course.self, WeeklySlot.self, LectureSession.self, Deck.self, DeckPage.self, Lecture.self,
        Recording.self, LectureDeckSpan.self, RecordingSegment.self, SlideEvent.self,
        TranscriptSegment.self, APICall.self, Note.self, Annotation.self, TrackedItem.self,
        Semester.self, Filing.self,
        MailAccount.self, Mailbox.self, MailRule.self, MailMessage.self, MailAttachment.self, MailDraft.self,
        TrackedItemSource.self,
        AgentConversation.self, AgentTurn.self, TranscriptExtraction.self,
        StudyUnit.self,
        AgentMemory.self,
        SlideInk.self,
        AgentTask.self, AgentChange.self, AgentEvent.self, AgentReminder.self,
        StudyReading.self, StudyQuestion.self, StudySession.self, StudyAnswer.self, StudyBlock.self,
        AgentRequest.self, AgentRequestFile.self,
        UniversityProfileRecord.self,
        LectureNotes.self, LectureNotesMark.self,
    ] }

    /// Library tables the list above lacks (empty when sync covers the schema).
    static var missingTables: [String] {
        let listed = Set(types.map { $0.tableName })
        return Schema.tableNames.filter { !excluded.contains($0) && !listed.contains($0) }
    }

    /// The schema SQLiteData attaches its metadatabase under (`Database.attachMetadatabase`).
    static let metadataSchema = "sqlitedata_icloud"

    /// True once a sync engine has started on this library (SQLiteData cached its record types
    /// at the end of that start); false before the first sync.
    static func hasSynced(_ db: Database) throws -> Bool {
        let exists = try Int.fetchOne(
            db,
            sql: """
                SELECT count(*) FROM "\(metadataSchema)".sqlite_master
                WHERE "type" = 'table' AND "name" = 'sqlitedata_icloud_recordTypes'
                """
        ) ?? 0
        guard exists > 0 else { return false }
        let cached = try Int.fetchOne(db, sql: #"SELECT count(*) FROM "\#(metadataSchema)"."sqlitedata_icloud_recordTypes""#) ?? 0
        return cached > 0
    }

    /// Rows iCloud has not received yet: never saved to the server and not deleted.
    static func unsentCount(_ db: Database) throws -> Int {
        try SyncMetadata
            .where { !$0.hasLastKnownServerRecord && !$0._isDeleted }
            .fetchCount(db)
    }

    /// Queues those rows again (a running engine only: SQLiteData's metadata triggers add each
    /// to its pending changes; already pending ones stay once). Returns how many.
    static func queueUnsent(_ db: Database) throws -> Int {
        try SyncMetadata
            .where { !$0.hasLastKnownServerRecord && !$0._isDeleted }
            .update { $0.recordPrimaryKey = $0.recordPrimaryKey }
            .execute(db)
        return db.changesCount
    }

    /// Queues the rows no engine noted (written while none was built: by a build without sync,
    /// or before this launch made its engine): their tables are touched (`SET id = id`), so
    /// SQLiteData's triggers add their metadata and queue them. Only rows without metadata are
    /// touched; a running engine sends them. Returns how many.
    static func queueUntracked(_ db: Database) throws -> Int {
        var queued = 0
        for table in types.map({ $0.tableName }) {
            try db.execute(
                sql: """
                    UPDATE "\(table)" SET "id" = "id"
                    WHERE NOT EXISTS (
                      SELECT 1 FROM "\(metadataSchema)"."sqlitedata_icloud_metadata" AS "m"
                      WHERE "m"."recordPrimaryKey" = "\(table)"."id" AND "m"."recordType" = ?
                    )
                    """,
                arguments: [table]
            )
            queued += db.changesCount
        }
        return queued
    }

    /// The sync engine over these tables, not started. `delegate` decides what an iCloud
    /// account change does (`AccountChangeGuard`: never delete the device's rows).
    static func engine(
        for database: any DatabaseWriter, container: String, delegate: any SyncEngineDelegate
    ) throws -> SyncEngine {
        try SyncEngine(
            for: database,
            tables:
                Course.self, WeeklySlot.self, LectureSession.self, Deck.self, DeckPage.self, Lecture.self,
                Recording.self, LectureDeckSpan.self, RecordingSegment.self, SlideEvent.self,
                TranscriptSegment.self, APICall.self, Note.self, Annotation.self, TrackedItem.self,
                Semester.self, Filing.self,
                MailAccount.self, Mailbox.self, MailRule.self, MailMessage.self, MailAttachment.self, MailDraft.self,
                TrackedItemSource.self,
                AgentConversation.self, AgentTurn.self, TranscriptExtraction.self,
                StudyUnit.self,
                AgentMemory.self,
                SlideInk.self,
                AgentTask.self, AgentChange.self, AgentEvent.self, AgentReminder.self,
                StudyReading.self, StudyQuestion.self, StudySession.self, StudyAnswer.self, StudyBlock.self,
                AgentRequest.self, AgentRequestFile.self,
                UniversityProfileRecord.self,
                LectureNotes.self, LectureNotesMark.self,
            containerIdentifier: container,
            startImmediately: false,
            delegate: delegate
        )
    }
}
