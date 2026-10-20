import ClaudeKit
import Foundation
import StudyCore
import StudyPass

// ln (docs/plan-lecture-notes.md §5.1, "Build plan"): the task queue's `lecture_notes` runner. A
// `lecture_notes` task (queued only by `LectureNotesRepository.queue` / `queueIfNeeded` /
// `queueAfterStudyPass`) runs in code: `NotesWriter.run`, one streamed Opus call, at most one such
// task at once (`claim(…, oneAtATime: [.document, .lectureNotes])`), only with Claude Code (not
// claimed without it), quiet (never reported into the thread unless the agent queued it from the
// chat: `write_lecture_notes` gives it a parent conversation). A usage limit pauses it until the
// reset; a cancel (Previous Version, the panel, cancel_task) cancels its version; a quitting run
// writes nothing (the version stays `generating` and is resumed at the next launch).
extension AgentTaskQueue {
    func runLectureNotes(_ task: AgentTask) async {
        guard let notesWriter else {
            await finishRow(task.id, .failed, error: "Lecture notes do not run on this device.")
            return
        }
        let notes: LectureNotes?
        do {
            notes = try await LectureNotesRepository(store: services.records).notes(taskID: task.id)
        } catch {
            AppAgentModule.log.error("Reading a notes task's version failed: \(ReadableError.kind(of: error), privacy: .public)")
            await finishRow(task.id, .failed, error: ReadableError.couldNotSave)
            return
        }
        guard let notes else {
            await finishRow(task.id, .failed, error: "These notes are gone.")
            return
        }
        let outcome = await notesWriter.run(notesID: notes.id)
        // Its row was cancelled (the queue stopped this work) or the app quits: nothing more,
        // except that the version of a cancelled task is cancelled too.
        if Task.isCancelled {
            if await stillOpen(task) { await Self.closeNotes(of: task, services: services) }
            return
        }
        switch outcome {
        case .done:
            guard await stillOpen(task) else { return }
            // Quiet: an empty result hides the task in the thread; one the agent queued from the
            // chat (it has a parent conversation) says so.
            let result = task.parentConversationID == nil ? "" : "Notes written: \(task.title.replacingOccurrences(of: "Notes: ", with: ""))."
            await finishRow(task.id, .succeeded, result: result)
        case .waiting(let until):
            await wait(task, until: until)
        case .failed(let message):
            guard await stillOpen(task) else { return }
            await finishRow(task.id, .failed, error: message)
        }
    }

    /// A `lecture_notes` task cancelled (the panel, `cancel_task`, a running one stopped): its open
    /// version is cancelled too (`LectureNotesRepository.cancel(taskID:)`).
    static func closeNotes(of task: AgentTask, services: StudyServices) async {
        guard task.kind == .lectureNotes else { return }
        do {
            try await LectureNotesRepository(store: services.records).cancel(taskID: task.id)
        } catch {
            AppAgentModule.log.error("Cancelling a task's notes failed: \(ReadableError.kind(of: error), privacy: .public)")
        }
    }
}
