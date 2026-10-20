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
    ] }

    /// Library tables the list above lacks (empty when sync covers the schema).
    static var missingTables: [String] {
        let listed = Set(types.map { $0.tableName })
        return Schema.tableNames.filter { !excluded.contains($0) && !listed.contains($0) }
    }

    /// The sync engine over these tables, not started.
    static func engine(for database: any DatabaseWriter, container: String) throws -> SyncEngine {
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
            containerIdentifier: container,
            startImmediately: false
        )
    }
}
