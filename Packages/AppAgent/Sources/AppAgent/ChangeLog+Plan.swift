import Filing
import Foundation
import StudyCore

/// 2026-10-23: the lecture plan through the change log. Smart import owns where a lecture sits
/// (`FilingService.editLecturePlan`, `moveRecording`): each change and its `agent_change` row in
/// one transaction, every check inside it. The log turns its refusals into one sentence the agent
/// can say, with what would do it instead.
extension ChangeLog {
    /// `move_lecture`, `edit_lecture`, `delete_lecture` (the student asked in chat).
    public func editLecturePlan(_ edit: LecturePlanEdit, quote: String, origin: Origin) async throws -> Outcome {
        let quote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return .refused("A change needs the exact words it comes from.") }
        let service = filing ?? FilingService(services: services)
        do {
            let outcome = try await service.editLecturePlan(edit, source: Self.planSource(quote, origin: origin))
            return .applied(outcome.change)
        } catch let refusal as LecturePlanRefusal {
            return try await answer(refusal)
        }
    }

    /// `move_recording`: a recording into another lecture (its transcript, stamps, notes and flags
    /// along; the study pass is built again; the lecture it leaves stays). The processor wakes
    /// for the alignment or transcription the move queued. `acrossCourses`: the student's words
    /// name the lecture's course (the tool checks it in code).
    public func moveRecording(
        _ recordingID: Recording.ID, to lectureID: Lecture.ID, acrossCourses: Bool, quote: String, origin: Origin
    ) async throws -> Outcome {
        let quote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return .refused("A change needs the exact words it comes from.") }
        let service = filing ?? FilingService(services: services)
        do {
            let change = try await service.moveRecording(
                recordingID, to: lectureID, acrossCourses: acrossCourses, source: Self.planSource(quote, origin: origin)
            )
            await wakeProcessing()
            return .applied(change)
        } catch let refusal as LecturePlanRefusal {
            if refusal == .otherCourse {
                return .refused(
                    "That lecture is another course's than the recording's. Ask the student which course it belongs to; it moves across only when their words name that course."
                )
            }
            return try await answer(refusal)
        }
    }

    /// Undo of `lecture_edit` / `lecture_delete`: smart import puts every touched lecture back
    /// (all or none) and marks the row, in one transaction.
    func undoLecturePlan(_ change: AgentChange) async throws -> Bool {
        guard change.undoneAt == nil else { return false }
        do {
            return try await (filing ?? FilingService(services: services)).undoLecturePlan(change)
        } catch FilingError.changedSince {
            throw UndoRefused.changedSince
        }
    }

    static func planSource(_ quote: String, origin: Origin) -> LecturePlanSource {
        LecturePlanSource(
            quote: String(quote.prefix(500)), sourceKind: origin.sourceKind, model: origin.model, conversationID: origin.conversationID,
            taskID: origin.taskID
        )
    }

    /// Why nothing changed, in one sentence with what would do it.
    func answer(_ refusal: LecturePlanRefusal) async throws -> Outcome {
        switch refusal {
        case .missing:
            return .refused("That lecture, class or recording is gone. Use list_lectures and query_sessions.")
        case .otherCourse:
            return .refused("That class belongs to another course; a lecture moves only within its own course.")
        case .cancelledSession:
            return .refused("That class is cancelled. If it took place after all, restore it with change_session first (only when the student says so).")
        case .recordedToFuture:
            return .refused("The lecture has recordings, so it can only go to a class that has already happened (by <now>).")
        case .bothRecorded(let mine, let theirs):
            return .refused(
                "Both that lecture and the class's lecture have recordings (\(mine) and \(theirs)). If they are one lecture, merge_lectures; if a recording sits in the wrong lecture, move_recording."
            )
        case .busy:
            return .unchanged("A recording of that lecture is being processed right now; ask again when it is done.")
        case .holdsNothing:
            return .refused(
                "It has no slides or recording of its own, so beside the class's lecture it would only be merged into it: merge_lectures, or delete_lecture when it is empty."
            )
        case .numberTaken(let id):
            let name = try await services.records.fetch(Lecture.self, id: id).map { lecture in
                lecture.number.map { "L\($0) (\(ChatCitation.key(lecture.id)))" } ?? ChatCitation.key(lecture.id)
            } ?? "another lecture"
            return .refused(
                "\(name) has that number already. Renumber it first (edit_lecture), use later_numbers, or merge_lectures if they are one lecture."
            )
        case .emptyTitle:
            return .refused("title is empty.")
        case .notEmpty(let recordings, let slides, let notes):
            return .refused(
                "It is not empty (\(recordings) recording(s), \(slides) slide link(s), \(notes) note(s), flags, practice answers or sections the student said it covered); only empty lectures are deleted. merge_lectures or move_recording moves what it holds."
            )
        case .unchanged:
            return .unchanged("It is so already.")
        }
    }
}
