import Foundation
import SQLiteData

// Values added with schema v11 (milestone ma: one agent across the app). docs/plan-agent.md §3–4,
// docs/schema.md.

// MARK: - Conversations

extension ConversationKind {
    /// The one app agent (ma): the agent panel's conversation on every screen of the main window.
    /// Every domain's tools (lectures, mail as untrusted data, notes, items, sessions, calendar,
    /// memory, the activity log, tasks), verified writes with Undo, reply drafts, sub-agent tasks;
    /// no web tools (a research task does that, never with mail). Each user turn carries the
    /// `<catalog>` and `<context>` blocks when they changed and the student's attachments.
    public static let app: Self = "app"
    /// A sub-agent task's own conversation (`agent_task.conversation_id`): the tool groups of its
    /// task row, fixed when it was spawned.
    public static let task: Self = "task"
}

// MARK: - Tracked items and sources

extension TrackedItemKind {
    /// A lecture session moved to another time (`lecture_session_id`; the new times are in the
    /// session row, the old ones in the `agent_change` row's `before`). Applied on its own with
    /// Undo (ma), status `done` once applied.
    public static let timeChange: Self = "time_change"
    /// A one-off session the course announced (a block lecture, a make-up date): the session row
    /// the change added (`lecture_session_id`). Applied on its own with Undo (ma).
    public static let extraSession: Self = "extra_session"

    /// Kinds that record a change of a lecture session (ma: applied on their own with Undo, status
    /// `done` once applied; M2's open room changes and cancellations still wait for Confirm).
    public var isSessionChange: Bool {
        self == .roomChange || self == .cancellation || self == .timeChange || self == .extraSession
    }
}

extension SourceRef.Kind {
    /// The student changed a "Study Portal" event in another calendar app (ma: an `agent_event`).
    public static let calendar: Self = "calendar"
}

// MARK: - Sub-agent tasks

/// What a sub-agent task does (`agent_task.kind`); the panel's task list names it by its title.
public struct AgentTaskKind: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Research a topic on the web (Claude Code's WebSearch / WebFetch + the lecture tools; never mail).
    public static let research: Self = "research"
    /// Re-run a lecture's study pass (queues it; the pipeline does the work).
    public static let studyPass: Self = "study_pass"
    /// Triage a backlog of mail (Haiku, mail as data).
    public static let mailTriage: Self = "mail_triage"
    /// Prepare a practice exam from the lectures (Opus, effort medium).
    public static let practiceExam: Self = "practice_exam"
    /// Reconcile a timetable change with the sessions and items.
    public static let timetable: Self = "timetable"
    /// A decision triage escalated (Opus 5.5, effort medium): ambiguous, conflicting or high impact.
    public static let escalation: Self = "escalation"
    public static let other: Self = "other"
}

/// Where a sub-agent task is (`agent_task.state`).
public enum AgentTaskState: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// Waits for a background slot (≤ 2 run at once, 1 under memory pressure).
    case queued
    /// Its `claude` process runs.
    case running
    /// A usage limit stopped it until `paused_until`; it queues again then.
    case paused
    case succeeded
    case failed
    /// The student or the agent cancelled it.
    case cancelled

    /// Queued, running or paused: shown in the panel's task line.
    public var isOpen: Bool { self == .queued || self == .running || self == .paused }

    /// The states the panel's task line counts and lists.
    public static let open: [Self] = [.queued, .running, .paused]
}

/// A group of tools a sub-agent task may use (`agent_task.tools`), chosen when it is spawned and
/// fixed for its conversation. `web` is never given together with `mail` (`ToolSet` refuses it:
/// the web agent never sees mail).
public struct AgentToolGroup: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// list_lectures, search_lectures, read_slide, read_transcript_span, list_study_items.
    public static let lectures: Self = "lectures"
    /// search_mail, read_mail: untrusted content, delimited as data.
    public static let mail: Self = "mail"
    /// search_notes, read_note.
    public static let notes: Self = "notes"
    /// query_items (deadlines, exercises, exams, tasks, events).
    public static let items: Self = "items"
    /// query_sessions (the courses' lecture sessions).
    public static let sessions: Self = "sessions"
    /// query_calendar (Study Portal rows; other calendars read-only).
    public static let calendar: Self = "calendar"
    /// query_memory.
    public static let memory: Self = "memory"
    /// Claude Code's WebSearch / WebFetch (never with `mail`).
    public static let web: Self = "web"
    /// The verified writes through the change log (items, sessions, course facts, tasks, memory,
    /// reminders), each with an exact quote and Undo.
    public static let apply: Self = "apply"
}

// MARK: - Activity log

/// What one automatic change did (`agent_change.kind`).
public struct AgentChangeKind: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// A session moved to another time.
    public static let sessionTime: Self = "session_time"
    /// A session moved to another room.
    public static let sessionRoom: Self = "session_room"
    /// A session cancelled.
    public static let sessionCancel: Self = "session_cancel"
    /// A cancelled session takes place after all.
    public static let sessionRestore: Self = "session_restore"
    /// A one-off session added.
    public static let sessionExtra: Self = "session_extra"
    /// A deadline, exercise, exam, event or task added.
    public static let itemAdd: Self = "item_add"
    /// An item's date or time changed.
    public static let itemMove: Self = "item_move"
    /// An item marked done.
    public static let itemDone: Self = "item_done"
    /// An item's title, details, room or relevance changed.
    public static let itemUpdate: Self = "item_update"
    /// A course fact (lecturers, exam admission, exam form, bonus, attendance) set.
    public static let courseFact: Self = "course_fact"
    /// The agent memory written, revised or forgotten.
    public static let memory: Self = "memory"
    /// Blocks appended to a note (only when the student asked).
    public static let noteAppend: Self = "note_append"
    /// A reminder scheduled.
    public static let reminder: Self = "reminder"
}

/// The table an automatic change wrote (`agent_change.target_table`); `target_id` is that row.
public struct AgentChangeTarget: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let session: Self = "lecture_session"
    public static let item: Self = "tracked_item"
    public static let course: Self = "course"
    public static let memory: Self = "agent_memory"
    public static let note: Self = "note"
    public static let reminder: Self = "agent_reminder"
}

/// The fields of the target an automatic change touched, before or after it (`agent_change.before`
/// / `.after`, JSON). Only the fields of the change's target are set; `exists == false` in
/// `before` means the change created the row (Undo removes or dismisses it).
public struct AgentChangeValues: Hashable, Sendable, Codable {
    /// The row existed before (false: the change created it).
    public var exists: Bool?
    // lecture_session
    public var startsAt: Date?
    public var endsAt: Date?
    public var room: String?
    public var isCancelled: Bool?
    // tracked_item (Undo of an item goes through its `tracked_item_source.previous` as in M3)
    public var item: TrackedItemSnapshot?
    // course
    public var professors: [String]?
    public var rules: [CourseRule]?
    // agent_memory
    public var memoryText: String?
    public var forgotten: Bool?
    // note: the blocks the change appended (Undo removes exactly these while they are unchanged)
    public var noteBlocks: [NoteBlock]?
    public var noteCreated: Bool?
    // agent_reminder
    public var fireAt: Date?
    public var cancelled: Bool?

    public init(
        exists: Bool? = nil,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        room: String? = nil,
        isCancelled: Bool? = nil,
        item: TrackedItemSnapshot? = nil,
        professors: [String]? = nil,
        rules: [CourseRule]? = nil,
        memoryText: String? = nil,
        forgotten: Bool? = nil,
        noteBlocks: [NoteBlock]? = nil,
        noteCreated: Bool? = nil,
        fireAt: Date? = nil,
        cancelled: Bool? = nil
    ) {
        self.exists = exists
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.room = room
        self.isCancelled = isCancelled
        self.item = item
        self.professors = professors
        self.rules = rules
        self.memoryText = memoryText
        self.forgotten = forgotten
        self.noteBlocks = noteBlocks
        self.noteCreated = noteCreated
        self.fireAt = fireAt
        self.cancelled = cancelled
    }

    /// The values of a session's changeable columns.
    public static func session(_ session: LectureSession) -> AgentChangeValues {
        AgentChangeValues(exists: true, startsAt: session.startsAt, endsAt: session.endsAt, room: session.room, isCancelled: session.isCancelled)
    }
}

// MARK: - Triage inbox

/// Where a new fact came from (`agent_event.kind`).
public struct AgentEventKind: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// A routed course or University mail, new or changed (`mail_message_id`).
    public static let mail: Self = "mail"
    /// A recording's transcript finished (`recording_id`, `lecture_id`).
    public static let transcript: Self = "transcript"
    /// A lecture's study pass synthesis with said-in-class admin or deadline rows (`lecture_id`).
    public static let studyPass: Self = "study_pass"
    /// A timetable import (`detail`: its diff).
    public static let timetable: Self = "timetable"
    /// A "Study Portal" event the student changed in another calendar app (`detail`).
    public static let calendar: Self = "calendar"
}

/// Where an event is in triage (`agent_event.state`).
public enum AgentEventState: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// Waits for the next triage batch.
    case pending
    /// Read: its verified actions were applied (possibly none).
    case triaged
    /// Handed to an escalation task (`task_id`).
    case escalated
    /// Nothing to read (no model call was made).
    case skipped
    /// Gave up after `AgentEvent.maximumAttempts`.
    case failed
}
