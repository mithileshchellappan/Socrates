import Documents
import Foundation
import StudyCore

// md (docs/plan-docs.md §1, §4 "The queue"): the task queue's `document` runner. A `document` task
// (queued only by `DocumentRepository.queueSummary`) runs in code: `DocumentSummarizer.run`, one
// Haiku call, at most one such task at once (`claim(…, oneAtATime: [.document])`), only with Claude
// Code (not claimed without it), quiet (never reported into the thread: `settleFinished`). A usage
// limit pauses it until the reset; a cancel (the document deleted, the panel) stops it through
// `stopCancelled`, and a cancelled or quitting run writes nothing.
extension AgentTaskQueue {
    func runDocument(_ task: AgentTask) async {
        guard let documentID = task.documentID else {
            try? await tasks.finish(task.id, .failed, error: "This task names no document.")
            return
        }
        let outcome = await DocumentSummarizer(services: services, client: client, now: now).run(documentID: documentID)
        // Its row was cancelled (the queue cancelled this work) or the app quits: nothing more.
        if Task.isCancelled { return }
        switch outcome {
        case .done(let title):
            guard await stillOpen(task) else { return }
            try? await tasks.finish(task.id, .succeeded, result: title.isEmpty ? "Read." : "Read \u{201C}\(title)\u{201D}.")
        case .waiting(let until):
            await wait(task, until: until)
        case .failed(let message):
            guard await stillOpen(task) else { return }
            try? await tasks.finish(task.id, .failed, error: message)
        }
    }
}
