import Agent
import ClaudeKit
import Foundation
import StudyCore

/// 2026-10-21: two lectures merged into one when the student asks ("there are two L2s", one class
/// meeting filed twice): a registered action only (`run_action`), student-only (quote: their words
/// asking, verified like remove_course's), through the change log (`ChangeLog.mergeLectures` →
/// `FilingService.mergeLectures`, one transaction with its `lecture_merge` row and Undo). The two
/// are named by their keys (list_lectures) or by the course and the number they share; they must
/// be of one course, and two lectures that both have recordings merge only when the student's
/// words say so (`both_recorded`). The app merges the lectures filed twice on its own at launch.
extension WriteTools {
    var mergeLectures: AgentTool {
        AgentTool(
            tool: .custom(
                name: "merge_lectures",
                description: """
                    Merges two lectures of one course into one, ONLY when the student asks (quote: their words asking), \
                    e.g. one class meeting filed twice ("there are two L2s"). Name them by their keys from list_lectures, \
                    or give the course and the number they share. Recordings, slides, the student's notes, flags, kept \
                    answers and conversations move to the one that stays (keep, else the one filed to the lecture \
                    session); Claude's notes and the study pass are written again. Two lectures that both have \
                    recordings merge only when the student's words say so (both_recorded). Undo splits them again.
                    """,
                inputSchema: Schema.object([
                    "lectures": Schema.nullable([
                        "type": "array", "items": ["type": "string"],
                        "description": "The two lectures: their keys from list_lectures (or ids). Null: course and number.",
                    ]),
                    "course": Schema.optionalString("Course token, with number: the course's two lectures with that number."),
                    "number": Schema.nullable(["type": "integer", "description": "The number the two share (\"two L2s\": 2)."]),
                    "keep": Schema.optionalString("The lecture that stays (one of the two, its key); null: the one filed to the lecture session."),
                    "both_recorded": Schema.nullable([
                        "type": "boolean", "description": "True only when the student's words ask to merge lectures that both have recordings.",
                    ]),
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
            var ids: [Lecture.ID] = []
            let references = call.strings("lectures")
            if !references.isEmpty {
                guard references.count == 2 else { return .error("Name exactly two lectures.") }
                for reference in references {
                    guard let id = try await WriteToolsLookup.lectureID(reference, services: services) else {
                        return .error("No single lecture is \"\(reference)\": use its key from list_lectures.")
                    }
                    ids.append(id)
                }
            } else {
                guard let course = try await CourseList.load(services.database).course(call.text("course")), let number = call.integer("number")
                else { return .error("Name the two lectures (keys from list_lectures), or the course and the number they share.") }
                let courseID = course.id
                ids = try await services.database.read { db in
                    try Lecture.where { $0.courseID.eq(courseID) && $0.number.eq(Int?.some(number)) }.order(by: \.createdAt).fetchAll(db).map(\.id)
                }
                guard ids.count == 2 else {
                    return .error("That course has \(ids.count) lecture(s) numbered \(number), not two: name the two by their keys from list_lectures.")
                }
            }
            var keep: Lecture.ID?
            if let reference = call.text("keep") {
                guard let id = try await WriteToolsLookup.lectureID(reference, services: services), ids.contains(id) else {
                    return .error("keep must be one of the two lectures.")
                }
                keep = id
            }
            let taskID = try await AgentTaskRepository(store: services.records).taskID(conversation: context.conversationID)
            let origin = ChangeLog.Origin(
                source: checked.source, sourceDate: context.now, model: ClaudeModel.opus55.rawValue, taskID: taskID,
                conversationID: context.conversationID
            )
            let outcome = try await changeLog.mergeLectures(
                ids[0], ids[1], keep: keep, bothRecorded: call.flag("both_recorded") ?? false, quote: checked.quote, origin: origin
            )
            switch outcome {
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
