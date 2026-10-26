import ClaudeKit
import Foundation
import GRDB
import StudyCore
import StudyPass

// ln (docs/plan-lecture-notes.md §5.1, "Build plan"): the task queue's `lecture_notes` runner. A
// `lecture_notes` task (queued only by `LectureNotesRepository.writeAgain` / `queueIfNeeded` /
// `queueAfterStudyPass` / `queueDueReplacement` / `requeueWaiting`) runs in code: `NotesWriter.run`, one streamed Opus call, at most one such
// task at once (`claim(…, oneAtATime: [.document, .lectureNotes])`), only with Claude Code (not
// claimed without it), quiet (never reported into the thread unless the agent queued it from the
// chat: `write_lecture_notes` gives it a parent conversation). A usage limit pauses it until the
// reset; a cancel (Previous Version, the panel, cancel_task) cancels its version; a quitting run
// writes nothing (the version stays `generating` and is resumed at the next launch). A version with
// nothing to write from waits for its material: its task ends (failed, with that sentence: only a
// task the agent queued from the chat shows it), and `watchNotesMaterial` queues a new version when
// a deck's pages or a lecture's range are written. Once a version settles (done, failed, waiting
// for its material), the replace-once rules are caught up (`queueDueReplacement`: the recording's
// synthesis landed while it was written). Every task that does not write its version says why in
// the log (`lecture-notes`; the writer logs its own reasons).
extension AgentTaskQueue {
    func runLectureNotes(_ task: AgentTask) async {
        let key = ChatCitation.key(task.id)
        guard let notesWriter else {
            Log.lectureNotes.error("Notes task \(key, privacy: .public) failed: no notes writer on this device")
            await finishRow(task.id, .failed, error: "Summaries are not written on this device.")
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
            Log.lectureNotes.notice("Notes task \(key, privacy: .public) failed: its version is gone")
            await finishRow(task.id, .failed, error: "This summary is gone.")
            return
        }
        let outcome = await notesWriter.run(notesID: notes.id)
        // Its row was cancelled (the queue stopped this work) or the app quits: nothing more,
        // except that the version of a cancelled task is cancelled too.
        if Task.isCancelled {
            if await stillOpen(task) { await Self.closeNotes(of: task, services: services) }
            return
        }
        // Settled (not paused): a synthesis that landed while this version was written is caught
        // up now (its new version waits for this task's slot).
        switch outcome {
        case .waiting: break
        case .done, .failed, .waitingForMaterial: await catchUpNotes(lectureID: notes.lectureID)
        }
        switch outcome {
        case .done:
            guard await stillOpen(task) else { return }
            // Quiet: an empty result hides the task in the thread; one the agent queued from the
            // chat (it has a parent conversation) says so.
            let name = ["Summary: ", "Notes: "].reduce(task.title) { $0.replacingOccurrences(of: $1, with: "") }
            let result = task.parentConversationID == nil ? "" : "Summary written: \(name)."
            await finishRow(task.id, .succeeded, result: result)
        case .waiting(let until):
            await wait(task, until: until)
        case .failed(let message):
            guard await stillOpen(task) else { return }
            await finishRow(task.id, .failed, error: message)
        case .waitingForMaterial:
            guard await stillOpen(task) else { return }
            await finishRow(task.id, .failed, error: LectureNotes.nothingToWriteFrom)
        }
    }

    /// The replace-once rules caught up after a version settled
    /// (`LectureNotesRepository.queueDueReplacement`).
    private func catchUpNotes(lectureID: Lecture.ID) async {
        do {
            try await LectureNotesRepository(store: services.records).queueDueReplacement(lectureID: lectureID)
        } catch {
            Log.lectureNotes.error("Catching up a lecture's notes failed: \(ReadableError.kind(of: error), privacy: .public)")
        }
    }

    /// Notes that wait for their material are queued again when it arrives: a deck's pages or a
    /// lecture's range written (filing, a link, sync), and once at launch
    /// (`LectureNotesRepository.requeueWaiting`). Only with a notes writer (the Mac).
    func watchNotesMaterial() {
        guard notesWriter != nil, materialObservation == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        materialObservation = DatabaseRegionObservation(tracking: [
            SQLRequest<Row>(sql: "SELECT * FROM deck_page"), SQLRequest<Row>(sql: "SELECT * FROM lecture_deck_span"),
        ])
        .start(
            in: services.database,
            onError: { error in Log.lectureNotes.error("Watching notes material failed: \(String(describing: error), privacy: .public)") },
            onChange: { _ in continuation.yield() }
        )
        let repository = LectureNotesRepository(store: services.records)
        materialFollower = Task(priority: .background) {
            for await _ in stream {
                do {
                    try await repository.requeueWaiting()
                } catch {
                    Log.lectureNotes.error("Queueing waiting notes failed: \(ReadableError.kind(of: error), privacy: .public)")
                }
            }
        }
        continuation.yield()
    }

    func stopWatchingNotesMaterial() {
        materialObservation?.cancel()
        materialObservation = nil
        materialFollower?.cancel()
        materialFollower = nil
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
