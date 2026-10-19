import Foundation
import SQLiteData

// Record types added in schema v11 (milestone ma: one agent across the app). docs/plan-agent.md
// §3–4, docs/schema.md.

// MARK: - Sub-agent tasks

/// One sub-agent task the app agent (or triage, or the student through the agent) queued: a goal,
/// a model, the tool groups it may use and a short input summary. Run by AppAgent's task queue in
/// the background (≤ 2 at once), each in its own `task` conversation; its result flows back into
/// the conversation that spawned it (the panel shows it, the next message carries it).
@Table("agent_task")
public struct AgentTask: StudyRecord {
    public let id: UUID
    public var kind: AgentTaskKind
    /// What the panel's task list shows ("Research: Xen and paravirtualization"), ≤ 80 characters.
    public var title: String
    /// What to achieve, ≤ `goalLimit` characters.
    public var goal: String
    /// What the spawner hands over (data, ids, findings), ≤ `inputLimit` characters; empty for a
    /// web task spawned by a run that read mail (never mail text next to the web tools).
    @Column("input_summary") public var inputSummary: String
    /// `claude-haiku-5-5` or `claude-opus-5-5`.
    public var model: String
    /// "low", "medium", "high" (always stated in the request).
    public var effort: String
    /// The tool groups of its conversation, fixed at spawn.
    @Column(as: [AgentToolGroup].JSONRepresentation.self) public var tools: [AgentToolGroup]
    public var state: AgentTaskState
    /// The `app` conversation that spawned it (its result is reported there).
    @Column("parent_conversation_id") public var parentConversationID: AgentConversation.ID?
    /// The task's own `task` conversation (set when it first runs).
    @Column("conversation_id") public var conversationID: AgentConversation.ID?
    /// The triage event an escalation decides.
    @Column("event_id") public var eventID: AgentEvent.ID?
    @Column("course_id") public var courseID: Course.ID?
    @Column("lecture_id") public var lectureID: Lecture.ID?
    /// v14 (md): the kept document a `document` task reads. No foreign key (this table syncs, the
    /// document never does): a deleted document's open task is cancelled by the bank.
    @Column("document_id") public var documentID: StudyDocument.ID?
    /// The task's answer, ≤ `resultLimit` characters.
    public var result: String?
    /// Why it failed (readable, no secrets).
    public var error: String?
    /// Runs a quit or crash interrupted (re-queued with one more; failed after `maximumAttempts`).
    /// A pause and its re-queue count nothing.
    public var attempts: Int
    /// `agent` (the app agent or triage spawned it) or `user` (the student asked for it).
    @Column("created_by") public var createdBy: Author
    /// A usage limit paused it until then.
    @Column("paused_until") public var pausedUntil: Date?
    @Column("started_at") public var startedAt: Date?
    @Column("finished_at") public var finishedAt: Date?
    /// When the spawning conversation's next user turn carried the result.
    @Column("reported_at") public var reportedAt: Date?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: AgentTaskKind,
        title: String,
        goal: String,
        inputSummary: String = "",
        model: String,
        effort: String = "medium",
        tools: [AgentToolGroup],
        state: AgentTaskState = .queued,
        parentConversationID: AgentConversation.ID? = nil,
        conversationID: AgentConversation.ID? = nil,
        eventID: AgentEvent.ID? = nil,
        courseID: Course.ID? = nil,
        lectureID: Lecture.ID? = nil,
        documentID: StudyDocument.ID? = nil,
        result: String? = nil,
        error: String? = nil,
        attempts: Int = 0,
        createdBy: Author = .agent,
        pausedUntil: Date? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        reportedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = String(title.prefix(Self.titleLimit))
        self.goal = String(goal.prefix(Self.goalLimit))
        self.inputSummary = String(inputSummary.prefix(Self.inputLimit))
        self.model = model
        self.effort = effort
        self.tools = tools
        self.state = state
        self.parentConversationID = parentConversationID
        self.conversationID = conversationID
        self.eventID = eventID
        self.courseID = courseID
        self.lectureID = lectureID
        self.documentID = documentID
        self.result = result.map { String($0.prefix(Self.resultLimit)) }
        self.error = error
        self.attempts = attempts
        self.createdBy = createdBy
        self.pausedUntil = pausedUntil
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.reportedAt = reportedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let titleLimit = 80
    public static let goalLimit = 1_000
    public static let inputLimit = 4_000
    public static let resultLimit = 4_000
    /// A task interrupted this many times (quits, crashes) fails.
    public static let maximumAttempts = 3
    /// Background tasks running at once by default (1 under memory pressure).
    public static let defaultParallel = 2
}

// MARK: - Activity log

/// One change the agent made to the app's own data on its own (triage, an escalation, a task, or
/// the app agent's verified tools): what, to which row, from which source with the exact quote, and
/// how to undo it. Written in the same transaction as the change. Nothing is deleted: Undo sets
/// `undone_at` (and puts the row back from `before`); a newer change of the same target and field
/// sets the older one's `superseded_by`. "What did you change?" is answered from these rows.
@Table("agent_change")
public struct AgentChange: StudyRecord {
    public let id: UUID
    public var kind: AgentChangeKind
    @Column("target_table") public var targetTable: AgentChangeTarget
    /// The row changed (no foreign key: the target table varies; nil once unknown).
    @Column("target_id") public var targetID: UUID?
    /// The target as Today and Calendar name it ("DC Lecture 3", "Online quiz 1"), ≤ 120.
    public var title: String
    /// What happened ("Moved to Room 5 · Wed 21 Oct", "Added · Mon 19 Oct, 12:00"), ≤ 160.
    public var summary: String
    @Column(as: AgentChangeValues?.JSONRepresentation.self) public var before: AgentChangeValues?
    @Column(as: AgentChangeValues?.JSONRepresentation.self) public var after: AgentChangeValues?
    /// Where the fact came from: mail, transcript, timetable, chat, calendar.
    @Column("source_kind") public var sourceKind: SourceRef.Kind
    @Column("mail_message_id") public var mailMessageID: MailMessage.ID?
    /// Message-ID of the mail (survives a re-sync); a timetable source's file name.
    @Column("rfc_message_id") public var rfcMessageID: String
    @Column("lecture_id") public var lectureID: Lecture.ID?
    @Column("recording_id") public var recordingID: Recording.ID?
    /// Seconds on the recording clock (a transcript source's first word).
    public var time: Double?
    /// The conversation it was made in (the app agent's, a task's).
    @Column("conversation_id") public var conversationID: AgentConversation.ID?
    @Column("task_id") public var taskID: AgentTask.ID?
    @Column("event_id") public var eventID: AgentEvent.ID?
    /// The exact text of the source it was verified against.
    public var quote: String
    /// 0…1, the deciding model's.
    public var confidence: Double
    /// Who decided: `claude-haiku-5-5`, `claude-opus-5-5`, or "" for code (a timetable diff).
    public var model: String
    @Column("api_call_id") public var apiCallID: APICall.ID?
    /// The item source written with it (items and session changes): the item's popover row.
    @Column("tracked_item_source_id") public var trackedItemSourceID: TrackedItemSource.ID?
    /// A newer change of the same target and field (conflicts: the newest authoritative source wins).
    @Column("superseded_by") public var supersededBy: AgentChange.ID?
    @Column("applied_at") public var appliedAt: Date
    @Column("undone_at") public var undoneAt: Date?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: AgentChangeKind,
        targetTable: AgentChangeTarget,
        targetID: UUID?,
        title: String,
        summary: String,
        before: AgentChangeValues? = nil,
        after: AgentChangeValues? = nil,
        sourceKind: SourceRef.Kind,
        mailMessageID: MailMessage.ID? = nil,
        rfcMessageID: String = "",
        lectureID: Lecture.ID? = nil,
        recordingID: Recording.ID? = nil,
        time: Double? = nil,
        conversationID: AgentConversation.ID? = nil,
        taskID: AgentTask.ID? = nil,
        eventID: AgentEvent.ID? = nil,
        quote: String,
        confidence: Double = 1,
        model: String = "",
        apiCallID: APICall.ID? = nil,
        trackedItemSourceID: TrackedItemSource.ID? = nil,
        supersededBy: AgentChange.ID? = nil,
        appliedAt: Date = Date(),
        undoneAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.targetTable = targetTable
        self.targetID = targetID
        self.title = String(title.prefix(Self.titleLimit))
        self.summary = String(summary.prefix(Self.summaryLimit))
        self.before = before
        self.after = after
        self.sourceKind = sourceKind
        self.mailMessageID = mailMessageID
        self.rfcMessageID = rfcMessageID
        self.lectureID = lectureID
        self.recordingID = recordingID
        self.time = time
        self.conversationID = conversationID
        self.taskID = taskID
        self.eventID = eventID
        self.quote = quote
        self.confidence = confidence
        self.model = model
        self.apiCallID = apiCallID
        self.trackedItemSourceID = trackedItemSourceID
        self.supersededBy = supersededBy
        self.appliedAt = appliedAt
        self.undoneAt = undoneAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let titleLimit = 120
    public static let summaryLimit = 160

    /// The marker an answer cites this change with (`[[change 1a2b3c4d]]`).
    public var citation: ChatCitation { .change(key: ChatCitation.key(id)) }
}

// MARK: - Triage inbox

/// One new fact waiting for triage: a mail, a finished transcript, a study pass's said-in-class
/// rows, a timetable import, a calendar edit elsewhere. Producers write it without a model call;
/// AppAgent's triage reads pending events in batches. `source_key` keeps one row per source
/// version (the repository skips a key it has).
@Table("agent_event")
public struct AgentEvent: StudyRecord {
    public let id: UUID
    public var kind: AgentEventKind
    public var state: AgentEventState
    /// One per source version: "mail:<Message-ID>:<parse version or flags hash>",
    /// "transcript:<recording id>:<newest line stamp>", "study_pass:<lecture id>:<input hash>",
    /// "timetable:<file sha256>", "calendar:<event id>:<modified>".
    @Column("source_key") public var sourceKey: String
    @Column("course_id") public var courseID: Course.ID?
    @Column("mail_message_id") public var mailMessageID: MailMessage.ID?
    @Column("lecture_id") public var lectureID: Lecture.ID?
    @Column("recording_id") public var recordingID: Recording.ID?
    /// The fact itself when no other row holds it (a timetable diff, a calendar edit), ≤ 6,000
    /// characters; nil when triage reads the source rows (mail, transcript, study pass).
    public var detail: String?
    public var attempts: Int
    public var error: String?
    /// The triage call that read it.
    @Column("api_call_id") public var apiCallID: APICall.ID?
    /// The escalation task that decides it.
    @Column("task_id") public var taskID: AgentTask.ID?
    @Column("triaged_at") public var triagedAt: Date?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: AgentEventKind,
        state: AgentEventState = .pending,
        sourceKey: String,
        courseID: Course.ID? = nil,
        mailMessageID: MailMessage.ID? = nil,
        lectureID: Lecture.ID? = nil,
        recordingID: Recording.ID? = nil,
        detail: String? = nil,
        attempts: Int = 0,
        error: String? = nil,
        apiCallID: APICall.ID? = nil,
        taskID: AgentTask.ID? = nil,
        triagedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.sourceKey = sourceKey
        self.courseID = courseID
        self.mailMessageID = mailMessageID
        self.lectureID = lectureID
        self.recordingID = recordingID
        self.detail = detail.map { String($0.prefix(Self.detailLimit)) }
        self.attempts = attempts
        self.error = error
        self.apiCallID = apiCallID
        self.taskID = taskID
        self.triagedAt = triagedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let detailLimit = 6_000
    /// After this many failed triage attempts an event is `failed`.
    public static let maximumAttempts = 3
}

// MARK: - Reminders

/// A reminder the agent scheduled (an exam-admission quiz closing, a registration window):
/// delivered as a macOS notification at `fire_at`, no UI of its own. Cancelled (never deleted) when
/// its item's change is undone, the item is done or the student says so.
@Table("agent_reminder")
public struct AgentReminder: StudyRecord {
    public let id: UUID
    /// The notification's title: the item as Today names it ("Online quiz 1"), ≤ 120.
    public var title: String
    /// Its body: "Wed 21 Oct, 23:59 · Data Centers", ≤ 200.
    public var body: String
    @Column("fire_at") public var fireAt: Date
    /// The item it is about (CASCADE: it goes with the item).
    @Column("tracked_item_id") public var trackedItemID: TrackedItem.ID?
    @Column("course_id") public var courseID: Course.ID?
    @Column("delivered_at") public var deliveredAt: Date?
    @Column("cancelled_at") public var cancelledAt: Date?
    @Column("created_by") public var createdBy: Author
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        body: String,
        fireAt: Date,
        trackedItemID: TrackedItem.ID? = nil,
        courseID: Course.ID? = nil,
        deliveredAt: Date? = nil,
        cancelledAt: Date? = nil,
        createdBy: Author = .agent,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = String(title.prefix(120))
        self.body = String(body.prefix(200))
        self.fireAt = fireAt
        self.trackedItemID = trackedItemID
        self.courseID = courseID
        self.deliveredAt = deliveredAt
        self.cancelledAt = cancelledAt
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The notification request's identifier.
    public var notificationID: String { "studyportal.reminder." + id.uuidString.lowercased() }
}
