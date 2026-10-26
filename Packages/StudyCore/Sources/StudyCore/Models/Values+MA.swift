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
    /// The student changed a "Socrates" event in another calendar app (ma: an `agent_event`).
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
    /// query_calendar (Socrates rows; other calendars read-only).
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
    /// oss: the university profile and/or the current semester set (`set_profile`).
    public static let profile: Self = "profile"
}

/// A semester's columns as an `agent_change` keeps them (`set_profile`: `before` / `after.semester`),
/// so Undo can put its name and lecture period back.
public struct SemesterValues: Hashable, Sendable, Codable {
    public var id: Semester.ID
    public var name: String
    public var lectureStart: CalendarDay
    public var lectureEnd: CalendarDay
    public var breaks: [SemesterBreak]
    public var timeZone: String

    public init(_ semester: Semester) {
        id = semester.id
        name = semester.name
        lectureStart = semester.lectureStart
        lectureEnd = semester.lectureEnd
        breaks = semester.breaks
        timeZone = semester.timeZone
    }

    /// The semester row with these values.
    public func semester(updatedAt: Date) -> Semester {
        Semester(id: id, name: name, lectureStart: lectureStart, lectureEnd: lectureEnd, breaks: breaks, timeZone: timeZone, updatedAt: updatedAt)
    }
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
    /// A `filing` row: a deck the filing advisor filed or moved (Undo puts it back).
    public static let filing: Self = "filing"
    /// oss: the `university_profile` row (`set_profile`; the semester it changed rides along).
    public static let profile: Self = "university_profile"
}

extension AgentChangeKind {
    /// A deck filed (or moved) by the filing advisor (a Haiku call), with its reason.
    public static let filing: Self = "filing"
    /// A course removed at the student's request in chat (`remove_course`), with everything that
    /// belonged to it; `before.deletion` holds the rows for Undo.
    public static let courseRemove: Self = "course_remove"
    /// A course created at the student's request in chat (`add_course`); Undo removes it while it
    /// holds none of their work.
    public static let courseAdd: Self = "course_add"
    /// A weekly slot added (`add_weekly_slot`); its sessions are planned. Undo deletes it.
    public static let slotAdd: Self = "slot_add"
    /// A weekly slot's day, time, room, kind, period or rhythm changed (`change_weekly_slot`).
    public static let slotChange: Self = "slot_change"
    /// A weekly slot removed (`remove_weekly_slot`); Undo puts it back.
    public static let slotRemove: Self = "slot_remove"
}

extension AgentChangeTarget {
    /// A `weekly_slot` row (the slot changes); `before` / `after.slot` hold its values.
    public static let slot: Self = "weekly_slot"
    /// A `lecture` row (`lecture_merge`: the lecture that kept the class meeting).
    public static let lecture: Self = "lecture"
}

extension AgentChangeKind {
    /// One class meeting filed as two lectures (one with only the slides, one with only the
    /// recordings or notes), merged into one; `before.deletion` holds Filing's `LectureMerges`
    /// (the lecture that went and what moved) for Undo, which splits them again.
    public static let lectureMerge: Self = "lecture_merge"
    /// Where a lecture sits or what it is called, at the student's request (`move_lecture`,
    /// `edit_lecture`): its class, date, number or title, with the later lectures that moved with
    /// it. `before` / `after.lectures` hold every touched lecture; Undo puts all of them back.
    public static let lectureEdit: Self = "lecture_edit"
    /// An empty lecture deleted at the student's request (`delete_lecture`); `before.deletion`
    /// holds Filing's `Deletion` for Undo.
    public static let lectureDelete: Self = "lecture_delete"
}

/// Where a lecture sits, as a `lecture_edit` change keeps it (`before` / `after.lectures`): its
/// title, number, date and class, and the class each of its filings points to.
public struct LecturePlacementValues: Hashable, Sendable, Codable {
    /// A filing of the lecture and the class it names.
    public struct FilingPlace: Hashable, Sendable, Codable {
        public var id: Filing.ID
        public var lectureSessionID: LectureSession.ID?

        public init(id: Filing.ID, lectureSessionID: LectureSession.ID?) {
            self.id = id
            self.lectureSessionID = lectureSessionID
        }
    }

    public var id: Lecture.ID
    public var title: String
    public var number: Int?
    public var heldAt: Date?
    public var lectureSessionID: LectureSession.ID?
    public var filings: [FilingPlace]

    public init(_ lecture: Lecture, filings: [FilingPlace]) {
        id = lecture.id
        title = lecture.title
        number = lecture.number
        heldAt = lecture.heldAt
        lectureSessionID = lecture.lectureSessionID
        self.filings = filings
    }

    /// Whether `lecture` holds these values (a date within a second).
    public func matches(_ lecture: Lecture) -> Bool {
        let sameDate: Bool
        switch (heldAt, lecture.heldAt) {
        case (nil, nil): sameDate = true
        case (let left?, let right?): sameDate = abs(left.timeIntervalSince(right)) < 1
        default: sameDate = false
        }
        return lecture.id == id && lecture.title == title && lecture.number == number && sameDate
            && lecture.lectureSessionID == lectureSessionID
    }
}

/// A weekly slot's columns as an `agent_change` keeps them (`before.slot`, `after.slot`), so Undo
/// can put the slot back as it was.
public struct WeeklySlotValues: Hashable, Sendable, Codable {
    public var id: WeeklySlot.ID
    public var courseID: Course.ID
    public var kind: SessionKind
    public var weekday: Int
    public var startMinute: Int
    public var durationMinutes: Int
    public var room: String
    public var timeZone: String
    public var validFrom: CalendarDay?
    public var validUntil: CalendarDay?
    public var weekInterval: Int

    public init(_ slot: WeeklySlot) {
        id = slot.id
        courseID = slot.courseID
        kind = slot.kind
        weekday = slot.weekday
        startMinute = slot.startMinute
        durationMinutes = slot.durationMinutes
        room = slot.room
        timeZone = slot.timeZone
        validFrom = slot.validFrom
        validUntil = slot.validUntil
        weekInterval = slot.weekInterval
    }

    /// The slot row with these values.
    public func slot(updatedAt: Date) -> WeeklySlot {
        WeeklySlot(
            id: id, courseID: courseID, kind: kind, weekday: weekday, startMinute: startMinute, durationMinutes: durationMinutes,
            room: room, timeZone: timeZone, validFrom: validFrom, validUntil: validUntil, weekInterval: weekInterval, updatedAt: updatedAt
        )
    }
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
    // course (mc: `course_credits`)
    public var credits: Double?
    public var selfStudyHours: Double?
    // agent_memory (mc: a `plan` memory's rule)
    public var planRule: PlanRule?
    // study_block (mc: `plan_move`)
    public var day: CalendarDay?
    public var sortOrder: Int?
    public var createdBy: Author?
    public var isAway: Bool?
    // filing (a deck the filing advisor filed or moved): where it is, and why (after)
    public var courseID: Course.ID?
    public var lectureID: Lecture.ID?
    public var lectureSessionID: LectureSession.ID?
    public var reason: String?
    // course (`course_remove`): the removed course's rows (Filing's `Deletion`, JSON), for Undo
    public var deletion: String?
    // weekly_slot (`slot_add`, `slot_change`, `slot_remove`): the slot's values
    public var slot: WeeklySlotValues?
    /// weekly_slot (`slot_change` from a date, `after` only): the new slot that takes over while
    /// `slot` ends the day before, so classes held before keep their day, time and room.
    public var successor: WeeklySlotValues?
    // lecture_deck_span (mr: `deck_link`, `deck_unlink`): a lecture's page range of a deck (with
    // `lectureID`); `exists: false` in `before` = the change made the link, in `after` = removed it
    public var deckID: Deck.ID?
    public var firstPage: Int?
    public var lastPage: Int?
    public var spanSource: SpanSource?
    /// The coarse span's `updated_at` (which of the lecture's decks is current): Undo puts it
    /// back, so a restored link of a deck that was not current does not become the current one.
    public var spanUpdatedAt: Date?
    // university_profile (oss: `set_profile`): the profile, and the semester it changed (nil: not
    // part of the change)
    public var universityProfile: UniversityProfile?
    public var semester: SemesterValues?
    // agent_memory (ln: a `preference` memory's notes length, `notes_rule`)
    public var notesRule: NotesRule?
    // course_material (mt: `material_kind`, `material_primary`) and material_coverage
    // (`material_coverage`)
    public var materialKind: MaterialKind?
    public var materialKindSource: MaterialKindSource?
    /// `material_primary`: the course's primary material before / after (nil: none).
    public var materialID: CourseMaterial.ID?
    /// `material_coverage`: the student's row (nil with `exists` false: there was none).
    public var coverage: MaterialCoverageValues?
    /// `material_coverage` of several sections at once: the student's rows (`before`: those that
    /// were there; a section missing from it had none).
    public var coverages: [MaterialCoverageValues]?
    // lecture (`lecture_edit`): every lecture the change touched, as it was or is
    public var lectures: [LecturePlacementValues]?

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
        cancelled: Bool? = nil,
        credits: Double? = nil,
        selfStudyHours: Double? = nil,
        planRule: PlanRule? = nil,
        day: CalendarDay? = nil,
        sortOrder: Int? = nil,
        createdBy: Author? = nil,
        isAway: Bool? = nil,
        courseID: Course.ID? = nil,
        lectureID: Lecture.ID? = nil,
        lectureSessionID: LectureSession.ID? = nil,
        reason: String? = nil,
        deletion: String? = nil,
        slot: WeeklySlotValues? = nil,
        successor: WeeklySlotValues? = nil,
        deckID: Deck.ID? = nil,
        firstPage: Int? = nil,
        lastPage: Int? = nil,
        spanSource: SpanSource? = nil,
        spanUpdatedAt: Date? = nil,
        universityProfile: UniversityProfile? = nil,
        semester: SemesterValues? = nil,
        notesRule: NotesRule? = nil,
        materialKind: MaterialKind? = nil,
        materialKindSource: MaterialKindSource? = nil,
        materialID: CourseMaterial.ID? = nil,
        coverage: MaterialCoverageValues? = nil,
        coverages: [MaterialCoverageValues]? = nil,
        lectures: [LecturePlacementValues]? = nil
    ) {
        self.materialKind = materialKind
        self.materialKindSource = materialKindSource
        self.materialID = materialID
        self.coverage = coverage
        self.coverages = coverages
        self.lectures = lectures
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
        self.credits = credits
        self.selfStudyHours = selfStudyHours
        self.planRule = planRule
        self.day = day
        self.sortOrder = sortOrder
        self.createdBy = createdBy
        self.isAway = isAway
        self.courseID = courseID
        self.lectureID = lectureID
        self.lectureSessionID = lectureSessionID
        self.reason = reason
        self.deletion = deletion
        self.slot = slot
        self.successor = successor
        self.deckID = deckID
        self.firstPage = firstPage
        self.lastPage = lastPage
        self.spanSource = spanSource
        self.spanUpdatedAt = spanUpdatedAt
        self.universityProfile = universityProfile
        self.semester = semester
        self.notesRule = notesRule
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
    /// A "Socrates" event the student changed in another calendar app (`detail`).
    public static let calendar: Self = "calendar"
    /// A course deck's organisational pages (how the exercises, the admission and the exam work),
    /// found in code: `detail` their numbers with a hash of their words ("2:1a2b3c4d,7:…"). One per
    /// deck version and course; a deck without new such pages gets a `skipped` row (read once).
    public static let slides: Self = "slides"
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
