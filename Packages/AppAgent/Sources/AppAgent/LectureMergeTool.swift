import Agent
import ClaudeKit
import Foundation
import StudyCore

/// 2026-10-21: one class meeting filed as two lectures ("there are two Lecture 2s"), merged when
/// the student asks: a registered action only (`run_action`), student-only (quote: their words
/// asking, verified like remove_course's), through the change log (`ChangeLog.mergeDuplicateLectures`
/// → `FilingService.mergeDuplicateLectures`, one transaction with its `lecture_merge` row and Undo).
/// The app ran the same merge once at launch.
extension WriteTools {
    var mergeDuplicateLectures: AgentTool {
        AgentTool(
            tool: .custom(
                name: "merge_duplicate_lectures",
                description: """
                    Merges a class meeting filed as two lectures into one, ONLY when the student asks (quote: their words \
                    asking): two lectures of the same session (an exercise right after a lecture counts as that lecture's), \
                    or the same number on the same day, where one has only the slides and the other only recordings or \
                    notes. Recordings, notes and slides move to one lecture, the empty one goes. Two lectures that both \
                    have recordings stay apart (the student moves a recording with Change… on its filing). Undo splits them.
                    """,
                inputSchema: Schema.object([
                    "course": Schema.optionalString("Course token; null: every course."),
                    "quote": quoteProperty,
                ])
            ),
            effect: .verifiedWrite
        ) { call, context in
            let checked: VerifiedQuote
            switch try await studentAsked(call, context: context) {
            case .success(let value): checked = value
            case .failure(let refusal): return .error(refusal.message)
            }
            var courseID: Course.ID?
            if let token = call.text("course"), !token.isEmpty {
                guard let course = try await CourseList.load(services.database).course(token) else {
                    return .error("No course has that token.")
                }
                courseID = course.id
            }
            let taskID = try await AgentTaskRepository(store: services.records).taskID(conversation: context.conversationID)
            let origin = ChangeLog.Origin(
                source: checked.source, sourceDate: context.now, model: ClaudeModel.opus55.rawValue, taskID: taskID,
                conversationID: context.conversationID
            )
            switch try await changeLog.mergeDuplicateLectures(courseID: courseID, quote: checked.quote, origin: origin) {
            case .applied(let change):
                return .json(["merged": true, "cite": .string(change.citation.marker), "title": .string(change.title), "summary": .string(change.summary)])
            case .unchanged(let text):
                return .json(["merged": false, "note": .string(text)])
            case .conflict(let text), .refused(let text):
                return .error(text)
            }
        }
    }
}
