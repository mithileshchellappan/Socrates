import Deadlines
import Foundation
import StudyCore

// ln (docs/plan-lecture-notes.md §5.6): the change rows of the agent's lecture notes actions and
// their Undo.
// - write_lecture_notes: a new version queued (`LectureNotesRepository.writeAgain`, created by
//   the agent: Write Again's rules, from whatever there is to write from), kind `lecture_notes`,
//   target the version. Undo cancels it while it is open, else
//   discards that version (Previous Version's way), so the one before is current again.
// - set_notes_length: a `preference` memory with its `notes_rule` (kind `notes_rule`, target the
//   memory); an older rule of the same scope is forgotten and its change superseded. Undo forgets
//   it (and brings the older rule back), as any memory change.
// - keep_notes_answer: a kept answer (`lecture_notes_mark`, kind `answer`, created by the agent),
//   kind `notes_answer`, target the mark. Undo removes the mark.
extension ChangeLog {
    /// write_lecture_notes: queues a version of the lecture's notes and logs it. `request`: the
    /// student's words, their new standing instruction; nil keeps the standing one. `.refused`
    /// when one is being written already or there is nothing to write from. The version's task
    /// reports into `origin.conversationID` when it is done.
    public func queueNotes(lectureID: Lecture.ID, request: String?, quote: String, origin: Origin) async throws -> Outcome {
        let quote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return .refused("A change needs the exact words it comes from.") }
        let repository = LectureNotesRepository(store: services.records)
        let versions = try await repository.versions(lectureID: lectureID)
        if versions.contains(where: { $0.state.isOpen }) { return .unchanged("Its summary is being written already.") }
        let instruction: NotesInstruction = request.map { .new($0) } ?? .standing
        guard let notes = try await repository.writeAgain(lectureID: lectureID, instruction: instruction, createdBy: .agent) else {
            return .refused("There is nothing to write its summary from yet (no slides and no transcript).")
        }
        let store = services.records
        let date = now()
        do {
            let lecture = try await store.fetch(Lecture.self, id: lectureID)
            let name = lecture.map { lecture in
                lecture.number.map { "Lecture \($0)" + (lecture.title.isEmpty ? "" : " · \(lecture.title)") } ?? lecture.title
            } ?? "Lecture"
            let summary = notes.request.map { "Writing again: \($0)" } ?? "Writing again"
            var change = AgentChange(
                kind: .lectureNotes, targetTable: .lectureNotes, targetID: notes.id, title: String("Summary: \(name)".prefix(AgentChange.titleLimit)),
                summary: String(summary.prefix(AgentChange.summaryLimit)), before: AgentChangeValues(exists: false),
                after: AgentChangeValues(exists: true), sourceKind: origin.sourceKind, taskID: origin.taskID, eventID: origin.eventID, quote: quote,
                confidence: 1, model: origin.model, apiCallID: origin.apiCallID, appliedAt: date, createdAt: date, updatedAt: date
            )
            ItemChangeRows.apply(origin.source, to: &change)
            change = Self.finalize(change, origin: origin, store: store)
            let row = change
            let conversation = origin.conversationID
            try await services.database.write { db in
                try AgentChangeRepository.insert(row, db: db)
                // The version's task reports into the conversation that asked for it.
                if let taskID = notes.taskID, let conversation {
                    try AgentTask.find(taskID).update {
                        $0.parentConversationID = AgentConversation.ID?.some(conversation)
                        $0.updatedAt = date
                    }
                    .execute(db)
                }
            }
            return .applied(change)
        } catch {
            // Not logged: not queued either (no change without its Undo).
            _ = try? await repository.cancel(notes.id)
            throw error
        }
    }

    /// Undo of write_lecture_notes: the version is cancelled while it is open, else discarded.
    func undoLectureNotes(_ change: AgentChange, at date: Date) async throws -> Bool {
        guard change.undoneAt == nil else { return false }
        if let notesID = change.targetID {
            let cancelled = try await LectureNotesRepository(store: services.records).cancel(notesID)
            if !cancelled {
                try await services.database.write { db in
                    try LectureNotes.where { $0.id.eq(notesID) && $0.discardedAt.is(nil) }
                        .update { $0.discardedAt = Date?.some(date); $0.updatedAt = date }
                        .execute(db)
                }
            }
        }
        let id = change.id
        try await services.database.write { db in try AgentChangeRepository.markUndone(id, at: date, db: db) }
        return true
    }

    // MARK: Inside the caller's transaction

    /// set_notes_length: the rule as a `preference` memory (its text the memory's), the older rule
    /// of the same scope forgotten.
    static func rememberNotesRule(
        _ rule: NotesRule, text: String, quote: String, origin: Origin, db: Database, store: RecordStore, now: Date
    ) throws -> Outcome {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(AgentMemory.textLimit))
        guard !text.isEmpty else { return .refused("The rule needs a text.") }
        let active = try AgentMemory.where { $0.forgottenAt.is(nil) }.fetchAll(db)
        let replaced = active.filter { $0.notesRule != nil && $0.notesRule?.courseID == rule.courseID }
        if replaced.contains(where: { $0.notesRule == rule }) { return .unchanged("Summaries are written that long already.") }
        guard active.count - replaced.count < AgentMemory.activeLimit else {
            return .refused("\(AgentMemory.activeLimit) memories are kept at most. Forget one first.")
        }
        let memory = store.stamp(AgentMemory(
            kind: .preference, courseID: rule.courseID, text: text, quote: quote, conversationID: origin.conversationID, createdBy: .agent,
            createdAt: now, updatedAt: now, notesRule: rule
        ))
        try AgentMemory.upsert { memory }.execute(db)
        var change = AgentChange(
            kind: .notesRule, targetTable: .memory, targetID: memory.id, title: String(text.prefix(AgentChange.titleLimit)), summary: "Remembered",
            before: AgentChangeValues(exists: false), after: AgentChangeValues(exists: true, memoryText: text, forgotten: false, notesRule: rule),
            sourceKind: origin.sourceKind, taskID: origin.taskID, eventID: origin.eventID, quote: quote, confidence: 1, model: origin.model,
            apiCallID: origin.apiCallID, appliedAt: now, createdAt: now, updatedAt: now
        )
        ItemChangeRows.apply(origin.source, to: &change)
        change = finalize(change, origin: origin, store: store)
        try AgentChangeRepository.insert(change, db: db)
        // The older rule of the same scope is forgotten; its change row points at this one, so
        // Undo of this change brings it back.
        for old in replaced {
            let oldID = old.id
            try AgentMemory.find(oldID).update {
                $0.forgottenAt = Date?.some(now)
                $0.updatedAt = now
            }
            .execute(db)
            let rows = try AgentChange
                .where { $0.targetTable.eq(AgentChangeTarget.memory) && $0.targetID.eq(UUID?.some(oldID)) && $0.undoneAt.is(nil) && $0.supersededBy.is(nil) }
                .fetchAll(db)
            for row in rows { try AgentChangeRepository.supersede(row.id, by: change.id, at: now, db: db) }
        }
        return .applied(change)
    }

    /// keep_notes_answer: the kept answer and its change row.
    static func keepNotesAnswer(_ mark: LectureNotesMark, quote: String, origin: Origin, db: Database, store: RecordStore, now: Date) throws -> Outcome {
        guard mark.kind == .answer, let question = mark.question, !question.isEmpty, let answer = mark.answer, !answer.isEmpty else {
            return .refused("A kept answer needs its question and answer.")
        }
        var kept = mark
        kept.createdAt = now
        kept.updatedAt = now
        let row = store.stamp(kept)
        try LectureNotesMark.upsert { row }.execute(db)
        var change = AgentChange(
            kind: .notesAnswer, targetTable: .lectureNotesMark, targetID: row.id, title: String(question.prefix(AgentChange.titleLimit)),
            summary: "Kept on the lecture's summary", before: AgentChangeValues(exists: false), after: AgentChangeValues(exists: true),
            sourceKind: origin.sourceKind, taskID: origin.taskID, eventID: origin.eventID, quote: quote, confidence: 1, model: origin.model,
            apiCallID: origin.apiCallID, appliedAt: now, createdAt: now, updatedAt: now
        )
        ItemChangeRows.apply(origin.source, to: &change)
        change = finalize(change, origin: origin, store: store)
        try AgentChangeRepository.insert(change, db: db)
        return .applied(change)
    }

    /// Undo of keep_notes_answer: the mark is removed (as Remove from Notes does).
    static func undoNotesMark(_ change: AgentChange, db: Database, now: Date) throws {
        guard let markID = change.targetID else { return }
        try LectureNotesMark.where { $0.id.eq(markID) && $0.removedAt.is(nil) }
            .update { $0.removedAt = Date?.some(now); $0.updatedAt = now }
            .execute(db)
    }
}
