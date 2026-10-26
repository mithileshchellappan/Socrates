import Foundation
import SQLiteData

// Record types and values added in schema v16 (ln: lecture notes). docs/plan-lecture-notes.md
// §2–5 and its "Build plan", docs/schema.md. The format of `lecture_notes.body` is
// `LectureNotesFormat` (LectureNotesFormat.swift).

// MARK: - Values

/// Where a version of a lecture's notes is (`lecture_notes.state`).
public enum LectureNotesState: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// Waits for its `agent_task` (kind `lecture_notes`) to be claimed: the outline (`sections`,
    /// from the topic rows) is there, the body is empty.
    case queued
    /// The call streams into `body` (at most every 100 ms).
    case generating
    /// A usage limit stopped it until `paused_until` (the task is paused too); what came stays.
    /// It goes on from its last complete section at the reset.
    case paused
    /// Validated: `body` is the checked text, `sections` the checked outline.
    case done
    /// It could not be written (`error`, one readable sentence); what came stays. Write Again.
    case failed
    /// The student or the agent cancelled it (Undo of write_lecture_notes, Cancel in the panel's
    /// task list); never the current notes.
    case cancelled

    /// Queued, generating or paused: a notes task is open for it.
    public var isOpen: Bool { self == .queued || self == .generating || self == .paused }
    public static let open: [Self] = [.queued, .generating, .paused]
}

/// What a version was written from (`lecture_notes.source`).
public enum LectureNotesSource: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// The slides alone (a lecture whose deck came before its recording, mockup 33): shorter, no
    /// professor quotes. Replaced once, automatically, when the recording's study pass lands.
    case slides
    /// The study pass's outputs: corrected transcript, topics, exam hints, highlights, said in
    /// class, slide summaries.
    case recording
}

/// How long the student wants their notes (`lecture_notes.length`, `NotesRule.length`): a
/// preference set through the agent ("shorter notes for this course"), never a setting.
public enum NotesLength: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    case concise
    case standard
    case thorough

    /// The factor on the target length (25 words per recorded minute, docs/plan-lecture-notes.md §2.3).
    public var factor: Double {
        switch self {
        case .concise: 0.6
        case .standard: 1
        case .thorough: 1.4
        }
    }
}

/// The instruction a new version is written with (`lecture_notes.request`).
public enum NotesInstruction: Sendable, Hashable {
    /// The student's standing instruction for the lecture's Summary (`LectureNotes.instruction(of:)`):
    /// every version that is not the student's new word carries it on.
    case standing
    /// Write Again's popover or the student's words through the agent: the new standing
    /// instruction (trimmed, at most `LectureNotes.requestLimit`); empty clears it.
    case new(String)

    /// The `request` of a new version among `versions`.
    public func request(after versions: [LectureNotes]) -> String? {
        switch self {
        case .standing:
            return LectureNotes.instruction(of: versions)
        case .new(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(LectureNotes.requestLimit))
        }
    }
}

/// A mark the student keeps on the notes (`lecture_notes_mark.kind`).
public enum LectureNotesMarkKind: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// The student's yellow highlight under a passage.
    case highlight
    /// A kept Ask exchange (Keep): `question` (the student's words) and `answer` (Claude's), drawn as
    /// a callout under the paragraph where the passage ends.
    case answer
}

/// One section of a version (`lecture_notes.sections`, JSON): a topic of the lecture in lecture
/// order. Written at queue time from the topic rows (so the outline shows before the text), refined
/// by the writer when the version is done (its exam hints, notes and questions). The overview
/// before the first section is not a section (its marks use `LectureNotesFormat.overviewKey`).
public struct LectureNotesSection: Hashable, Sendable, Codable {
    /// `LectureNotesFormat.sectionKey(topicTitle:)`: 8 hex, stable across study pass re-runs (the
    /// body's `<!-- section key -->` marker; marks anchor by it).
    public var key: String
    /// The heading (the topic's title).
    public var title: String
    /// The `annotation` ai · topic row (nil once the study pass replaced it; the key stays).
    public var topicID: Annotation.ID?
    /// Its slides (deck pages); Review's Follow scrolls the Summary tab to the section whose
    /// range holds the slide on screen.
    public var firstPage: Int?
    public var lastPage: Int?
    /// Seconds on `recordingID`'s clock where it is explained (the heading's `TimeChip`), and
    /// where the next section starts when it is on the same recording.
    public var startTime: Double?
    public var endTime: Double?
    /// The recording those times are on (2026-10-21: a lecture's notes cover every recording of
    /// it); nil: the lecture's first (versions written before).
    public var recordingID: Recording.ID?
    /// The section holds a verified exam hint (the amber star after the heading).
    public var hasExamHint: Bool
    /// Its share of the target length (words).
    public var targetWords: Int?
    /// Its Check yourself questions as `study_question` rows (origin `notes`), in order.
    public var questionIDs: [StudyQuestion.ID]
    /// The student's notes the writer placed in it (`note` fences), in order. Written empty since nl
    /// (the notes sit beside the text, in Your notes); older versions keep theirs.
    public var noteIDs: [Note.ID]
    /// The professor's exam hints and highlights it quotes (`quote` fences), in order.
    public var quoteIDs: [Annotation.ID]

    public init(
        key: String,
        title: String,
        topicID: Annotation.ID? = nil,
        firstPage: Int? = nil,
        lastPage: Int? = nil,
        startTime: Double? = nil,
        endTime: Double? = nil,
        hasExamHint: Bool = false,
        targetWords: Int? = nil,
        questionIDs: [StudyQuestion.ID] = [],
        noteIDs: [Note.ID] = [],
        quoteIDs: [Annotation.ID] = [],
        recordingID: Recording.ID? = nil
    ) {
        self.key = key
        self.title = title
        self.topicID = topicID
        self.firstPage = firstPage
        self.lastPage = lastPage
        self.startTime = startTime
        self.endTime = endTime
        self.hasExamHint = hasExamHint
        self.targetWords = targetWords
        self.questionIDs = questionIDs
        self.noteIDs = noteIDs
        self.quoteIDs = quoteIDs
        self.recordingID = recordingID
    }

    /// Whether the slide `page` lies in the section's slides.
    public func covers(page: Int) -> Bool {
        guard let first = firstPage else { return false }
        return page >= first && page <= (lastPage ?? first)
    }

    /// The section slide `page` belongs to (Review's Follow, the page's Your notes column): the
    /// first whose slides hold it, else the last that starts at or before it; nil before the first.
    public static func holding(page: Int, in sections: [LectureNotesSection]) -> LectureNotesSection? {
        sections.first { $0.covers(page: page) } ?? sections.last { ($0.firstPage ?? .max) <= page }
    }

    /// The section a moment belongs to (a note without a slide, at its `audio_time`): the one whose
    /// `startTime ..< endTime` holds it (no end: up to the next section's start, or on). With
    /// `recording` (the moment's), only the sections on that recording (or on none named).
    public static func holding(time: Double, recording: Recording.ID? = nil, in sections: [LectureNotesSection]) -> LectureNotesSection? {
        let timed = sections
            .filter { $0.startTime != nil && (recording == nil || $0.recordingID == nil || $0.recordingID == recording) }
            .sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
        for (index, section) in timed.enumerated() {
            guard let start = section.startTime, time >= start else { continue }
            let end = section.endTime ?? (index + 1 < timed.count ? timed[index + 1].startTime : nil) ?? .infinity
            if time < end { return section }
        }
        return nil
    }
}

/// The student's length for lecture notes (`agent_memory.notes_rule`, JSON, on a `preference`
/// memory written by `set_notes_length`): per course, or for all courses (`courseID` nil). The
/// newest rule for the course wins over the newest for all. Forgetting the memory drops it.
public struct NotesRule: Hashable, Sendable, Codable {
    public var length: NotesLength
    public var courseID: Course.ID?

    public init(length: NotesLength, courseID: Course.ID? = nil) {
        self.length = length
        self.courseID = courseID
    }
}

/// The calls of lecture notes: `api_call.purpose` values (always with `lecture_id`) and the models.
/// The model per call sits here, so moving a call to another model is one line.
public enum LectureNotesCalls {
    /// Writing a version: one streamed one-shot call (`claude -p --tools "" --safe-mode
    /// --no-session-persistence`), background priority.
    public static let write = "notes.write"
    /// Ask about a passage: one streamed one-shot call, interactive priority (it shares the one
    /// interactive process with the agent panel).
    public static let ask = "notes.ask"
    /// Repairing figure blocks that failed validation (one call per version at most).
    public static let repair = "notes.repair"

    public static let writeModel = "claude-opus-5-5"
    public static let writeEffort = "medium"
    public static let writeMaxTokens = 20_000
    public static let askModel = "claude-opus-5-5"
    public static let askEffort = "low"
    public static let askMaxTokens = 2_000
    public static let repairModel = "claude-haiku-5-5"
    public static let repairEffort = "low"
}

// MARK: - Records

/// One version of a lecture's notes (docs/plan-lecture-notes.md): one study text per lecture that
/// Claude writes after the study pass (or from the slides alone), read on the course's Lectures
/// page and in Review's Summary tab. Read-only Claude text (AI provenance); the student adds
/// marks (`lecture_notes_mark`) and their own notes show in place (live, from `note`).
///
/// Rows are never deleted: Write Again adds a version (`version` + 1), Previous Version sets
/// `discarded_at` on the newest (Redo clears it). The current notes are the newest version neither
/// discarded nor cancelled (`LectureNotesRepository.current`). Synced (no document-bank text goes
/// in), so the iPhone can read them later.
@Table("lecture_notes")
public struct LectureNotes: StudyRecord {
    public let id: UUID
    @Column("course_id") public var courseID: Course.ID
    @Column("lecture_id") public var lectureID: Lecture.ID
    /// 1, 2, … per lecture.
    public var version: Int
    public var state: LectureNotesState
    public var source: LectureNotesSource
    /// The student's instruction it was written with ("shorter, more formulas"), ≤ `requestLimit`;
    /// nil without one. Write Again's popover sets it; every later version, automatic or not,
    /// carries it on until the student changes it (`LectureNotes.instruction(of:)`).
    public var request: String?
    /// The length it was written at (the student's rule when it started); nil while queued.
    public var length: NotesLength?
    /// The whole text's target in words (Check yourself not counted).
    @Column("target_words") public var targetWords: Int?
    /// The Markdown source (`LectureNotesFormat`), streamed while `generating`; the checked text
    /// once `done`.
    public var body: String
    /// The outline: one entry per section in order (from the topic rows at queue time; the
    /// writer's checked outline once `done`).
    @Column(as: [LectureNotesSection].JSONRepresentation.self) public var sections: [LectureNotesSection]
    /// SHA-256 (hex) of the writer's input pack + its prompt version: staleness (nothing rewrites
    /// notes on its own because of it).
    @Column("input_hash") public var inputHash: String?
    @Column("prompt_version") public var promptVersion: Int?
    public var model: String?
    public var effort: String?
    /// The writing call (SET NULL).
    @Column("api_call_id") public var apiCallID: APICall.ID?
    /// Notional dollars of its calls (writing, resumes and the repair), summed.
    @Column("cost_usd") public var costUSD: Double?
    /// Figure blocks fixed by the repair call.
    public var repairs: Int
    /// Why it failed: one readable sentence.
    public var error: String?
    /// Its `agent_task` (kind `lecture_notes`; SET NULL).
    @Column("task_id") public var taskID: AgentTask.ID?
    /// `user` (first open of a lecture, Write Again…) or `agent` (after the study pass, the agent's
    /// write_lecture_notes).
    @Column("created_by") public var createdBy: Author
    /// While `paused`: when writing goes on ("Paused until 17:20").
    @Column("paused_until") public var pausedUntil: Date?
    /// Previous Version (Undo of Write Again) discarded it; Redo clears it.
    @Column("discarded_at") public var discardedAt: Date?
    @Column("created_at") public var createdAt: Date
    @Column("finished_at") public var finishedAt: Date?
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        courseID: Course.ID,
        lectureID: Lecture.ID,
        version: Int = 1,
        state: LectureNotesState = .queued,
        source: LectureNotesSource = .recording,
        request: String? = nil,
        length: NotesLength? = nil,
        targetWords: Int? = nil,
        body: String = "",
        sections: [LectureNotesSection] = [],
        inputHash: String? = nil,
        promptVersion: Int? = nil,
        model: String? = nil,
        effort: String? = nil,
        apiCallID: APICall.ID? = nil,
        costUSD: Double? = nil,
        repairs: Int = 0,
        error: String? = nil,
        taskID: AgentTask.ID? = nil,
        createdBy: Author = .agent,
        pausedUntil: Date? = nil,
        discardedAt: Date? = nil,
        createdAt: Date = Date(),
        finishedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.courseID = courseID
        self.lectureID = lectureID
        self.version = version
        self.state = state
        self.source = source
        self.request = request
        self.length = length
        self.targetWords = targetWords
        self.body = body
        self.sections = sections
        self.inputHash = inputHash
        self.promptVersion = promptVersion
        self.model = model
        self.effort = effort
        self.apiCallID = apiCallID
        self.costUSD = costUSD
        self.repairs = repairs
        self.error = error
        self.taskID = taskID
        self.createdBy = createdBy
        self.pausedUntil = pausedUntil
        self.discardedAt = discardedAt
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.updatedAt = updatedAt
    }

    /// Write Again's sentence is at most this long.
    public static let requestLimit = 300
}

/// A mark the student keeps on a lecture's notes: a highlight, or a kept Ask exchange (Keep). It
/// anchors by quoted text (a text-quote selector: `exact` with `prefix` and `suffix` inside its
/// section), so it survives a new version: the view finds `exact` again in the current version
/// (`LectureNotesText`), else it is orphaned (a kept answer moves to its section's end with its
/// passage quoted, a highlight hides; both come back with Previous Version).
///
/// Never deleted: Remove sets `removed_at`, Edit ▸ Undo clears it.
@Table("lecture_notes_mark")
public struct LectureNotesMark: StudyRecord {
    public let id: UUID
    @Column("lecture_id") public var lectureID: Lecture.ID
    /// The version it was made on (SET NULL).
    @Column("notes_id") public var notesID: LectureNotes.ID?
    public var kind: LectureNotesMarkKind
    /// The section it is in (`LectureNotesSection.key`, or `LectureNotesFormat.overviewKey`).
    @Column("section_key") public var sectionKey: String
    /// The passage as the student selected it (plain text), ≤ `exactLimit` characters.
    public var exact: String
    /// Up to `contextLength` characters before and after it, for finding it again.
    public var prefix: String
    public var suffix: String
    /// Where it was in that version's displayed text (a hint only; characters).
    @Column("start_offset") public var startOffset: Int?
    @Column("end_offset") public var endOffset: Int?
    /// A kept answer: the student's question as they typed it (or the quick choice: "Why?").
    public var question: String?
    /// A kept answer: Claude's answer (`LectureNotesFormat` Markdown; chips checked as the notes').
    public var answer: String?
    public var model: String?
    @Column("api_call_id") public var apiCallID: APICall.ID?
    @Column("cost_usd") public var costUSD: Double?
    /// `user` (the capsule, the menu, Keep) or `agent` (keep_notes_answer).
    @Column("created_by") public var createdBy: Author
    /// The current version no longer holds the passage (set by whoever noticed; cleared when it
    /// is found again).
    @Column("orphaned_at") public var orphanedAt: Date?
    /// Removed (Remove Highlight, Remove from Notes); Edit ▸ Undo clears it.
    @Column("removed_at") public var removedAt: Date?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        lectureID: Lecture.ID,
        notesID: LectureNotes.ID? = nil,
        kind: LectureNotesMarkKind,
        sectionKey: String,
        exact: String,
        prefix: String = "",
        suffix: String = "",
        startOffset: Int? = nil,
        endOffset: Int? = nil,
        question: String? = nil,
        answer: String? = nil,
        model: String? = nil,
        apiCallID: APICall.ID? = nil,
        costUSD: Double? = nil,
        createdBy: Author = .user,
        orphanedAt: Date? = nil,
        removedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.lectureID = lectureID
        self.notesID = notesID
        self.kind = kind
        self.sectionKey = sectionKey
        self.exact = String(exact.prefix(Self.exactLimit))
        self.prefix = String(prefix.suffix(Self.contextLength))
        self.suffix = String(suffix.prefix(Self.contextLength))
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.question = question
        self.answer = answer
        self.model = model
        self.apiCallID = apiCallID
        self.costUSD = costUSD
        self.createdBy = createdBy
        self.orphanedAt = orphanedAt
        self.removedAt = removedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let exactLimit = 2_000
    public static let contextLength = 32
}

// MARK: - Values of existing columns (v16)

extension AgentTaskKind {
    /// Write a version of a lecture's notes (`lecture_notes.task_id` points back; `lecture_id`
    /// set): run in code by the task queue, one at a time, queued only by `LectureNotesRepository`
    /// (`writeAgain`, `queueIfNeeded`, `queueAfterStudyPass`, `queueDueReplacement`,
    /// `requeueWaiting`).
    public static let lectureNotes: Self = "lecture_notes"
}

extension StudyQuestionOrigin {
    /// A Check yourself question of a lecture's notes (pool `round`; its version's
    /// `LectureNotesSection.questionIDs`). A new version retires the previous version's
    /// unanswered ones.
    public static let notes: Self = "notes"
}

extension AgentChangeKind {
    /// The agent queued a version of a lecture's notes (write_lecture_notes); Undo cancels the
    /// task or discards the version.
    public static let lectureNotes: Self = "lecture_notes"
    /// The agent kept an answer on the notes (keep_notes_answer); Undo removes the mark.
    public static let notesAnswer: Self = "notes_answer"
    /// The agent set the student's notes length (set_notes_length); Undo forgets the memory.
    public static let notesRule: Self = "notes_rule"
}

extension AgentChangeTarget {
    public static let lectureNotes: Self = "lecture_notes"
    public static let lectureNotesMark: Self = "lecture_notes_mark"
}

extension NoteInline.Mark {
    /// ln (Edit as Note): Claude's words copied from lecture notes, drawn grey with one sparkle per
    /// block (DESIGN 5.1: grey becomes normal when the student takes it). An edit inside such a
    /// run drops the mark from the words the student typed or changed.
    public static let ai: Self = "ai"
}

extension Note {
    /// An Edit as Note copy of a lecture's notes: some run still carries the `ai` mark (Claude's
    /// words the student has not taken over). The lecture page's Your notes column and Review's
    /// Whole lecture "Your notes" leave such notes out (nl: Claude's words never twice); Notes
    /// lists them as usual.
    public var isLectureNotesCopy: Bool {
        blocks.contains { block in (block.inlines ?? []).contains { $0.marks?.contains(.ai) == true } }
    }
}

/// What a notes passage the student took to the agent panel carries (`AgentContext.notesPassage`,
/// Continue in Chat): the passage and the Ask exchange so far, as data for the agent.
public struct NotesPassageContext: Hashable, Sendable, Codable {
    public var lectureID: Lecture.ID
    public var notesID: LectureNotes.ID
    public var sectionKey: String
    /// The selected passage (plain text, ≤ `ChatSource.textLimit` characters).
    public var exact: String
    /// The popover's exchange in order (the student's question, Claude's answer), at most 3.
    public var exchange: [NotesAskExchange]

    public init(lectureID: Lecture.ID, notesID: LectureNotes.ID, sectionKey: String, exact: String, exchange: [NotesAskExchange] = []) {
        self.lectureID = lectureID
        self.notesID = notesID
        self.sectionKey = sectionKey
        self.exact = String(exact.prefix(ChatSource.textLimit))
        self.exchange = Array(exchange.suffix(3))
    }
}

// MARK: - Ask (the contract between the notes view and the asker)

/// One question and its answer in an Ask popover.
public struct NotesAskExchange: Hashable, Sendable, Codable {
    public var question: String
    public var answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// The popover's three quick choices, sent at once (docs/plan-lecture-notes.md §3).
public enum NotesAskStyle: String, Hashable, Sendable, Codable, CaseIterable {
    /// "Explain simpler": an analogy, no new notation.
    case simpler
    /// "Example": a concrete example with small numbers from the lecture's setting.
    case example
    /// "Why?": the problem it solves and what it builds on.
    case why
}

/// An Ask about a passage of a lecture's notes.
public struct NotesAskRequest: Hashable, Sendable {
    public var lectureID: Lecture.ID
    public var notesID: LectureNotes.ID
    /// The section the passage is in (its material grounds the answer).
    public var sectionKey: String
    /// The selected passage (plain text).
    public var passage: String
    /// The student's words; empty for a quick choice alone.
    public var question: String
    public var style: NotesAskStyle?
    /// Earlier exchanges in the same popover (follow-ups), oldest first.
    public var earlier: [NotesAskExchange]

    public init(
        lectureID: Lecture.ID, notesID: LectureNotes.ID, sectionKey: String, passage: String, question: String,
        style: NotesAskStyle? = nil, earlier: [NotesAskExchange] = []
    ) {
        self.lectureID = lectureID
        self.notesID = notesID
        self.sectionKey = sectionKey
        self.passage = passage
        self.question = question
        self.style = style
        self.earlier = earlier
    }
}

/// The answer as it streams (about ten times a second), then once more when it ends.
public struct NotesAskUpdate: Hashable, Sendable {
    /// The answer so far (`LectureNotesFormat` Markdown; chips already checked once `isFinished`).
    public var text: String
    public var isFinished: Bool
    /// Waiting for the interactive slot (the agent panel answers) or for Claude Code: the
    /// popover keeps its skeleton line.
    public var isWaiting: Bool
    /// A usage limit: "Paused until 17:20".
    public var pausedUntil: Date?
    /// Why it failed: one readable sentence (what came stays).
    public var error: String?
    public var model: String?
    public var apiCallID: APICall.ID?
    public var costUSD: Double?

    public init(
        text: String = "", isFinished: Bool = false, isWaiting: Bool = false, pausedUntil: Date? = nil, error: String? = nil,
        model: String? = nil, apiCallID: APICall.ID? = nil, costUSD: Double? = nil
    ) {
        self.text = text
        self.isFinished = isFinished
        self.isWaiting = isWaiting
        self.pausedUntil = pausedUntil
        self.error = error
        self.model = model
        self.apiCallID = apiCallID
        self.costUSD = costUSD
    }
}

/// Answers a doubt about a passage of a lecture's notes (StudyPass's `NotesAsker`; the app installs
/// it as `\.lectureNotesAsker`, StudyUI). Grounded in the section's material, never the web; it
/// writes nothing (Keep does, through `LectureNotesRepository.keepAnswer`).
public protocol LectureNotesAsking: Sendable {
    /// The answer as it streams; the stream ends after the update with `isFinished` (or an error).
    /// Cancelling the consuming task stops the call.
    func ask(_ request: NotesAskRequest) -> AsyncStream<NotesAskUpdate>
}

/// Checks a figure block of the notes (`math`, `diagram`, `chart`; StudyPage's checker, installed
/// by the app into the writer): nil when it renders, else why not in one short line for the repair
/// call ("diagram: unknown arrow '-->>>' on line 4").
public protocol NotesFigureChecking: Sendable {
    func problem(in fence: NotesFence) -> String?
}
