# AppAgent

Workstream A of milestone ma: the ONE app agent. Logic only, no SwiftUI. Depends on StudyCore, ClaudeKit, Agent (`Agent`, `Deadlines`), MailIntelligence, Tutor, Search, Courses (`Courses` only), StudyPass and GRDB. Nothing here can send mail (no `Mail` dependency), write a calendar other than the app's own (the calendar mirror writes from the rows), or delete the student's notes or recordings. No automated test suite at present; verified by building; the integrator makes one live check.

## Checklist (resumable after a usage limit)

- [x] 1. ClaudeKit: `ClaudeCodeSlots` (1 interactive + `ClaudeCodeConfiguration.backgroundSlots` = 2 background), `ClaudeClient.setBackgroundSlotLimit(_:)`; interactive callers never wait behind background holders; the usage pause unchanged; nested tool calls bypass the slots.
- [x] 2. Agent: `MemoryTools.kinds` += `.app` (its writes log `agent_change` rows), `ToolEffect.delegate`, `RunTrace` (mail read by a run), `ConversationSpec.priority`, `AgentRuntime(conversationSpecs:)` (per-conversation specs: `task`), `start/send(…, turnContext:)` (+ `id:`, `title:`), `DeadlineMemory.recordSessionChange` (settled `done`), no new M2 proposals, in-transaction `update/complete/undo/restore/addSource`, `FactAction`/`FactDecision`, `ItemChangeRows`, `ChangeSummary`, `TranscriptCues`, `AgentToolSupport`.
- [x] 3. AppAgent: `AgentCatalog`, `AgentContextBlock`, `AppAgentChat` (`app`, `task`), `ChangeLog`, `FactApplier`, `FactTriage`, `AgentTaskQueue`, `ReminderCenter`, `AttachmentBlocks`, the `AppAgent` facade.
- [x] 4. Producers: MailExtractor (decided `mail` events: session changes, course facts, escalate; item changes logged), TranscriptItemPipeline (`transcript` events; item changes logged), StudyPassPipeline (`study_pass` events, `rerun(lectureID:)`), TimetableImporter (`sessionChange:` recorder, `timetable` event), CalendarMirror (`calendar` events), CourseSchedule (`setTime`, `restore`, `addExtra`, in-transaction `edit` / `insertSession`).
- [x] 5. This README.
- [x] Built: `taskpolicy -b swift build -j 4 --package-path Packages/AppAgent`, and `--package-path Packages/Courses --target CalendarSync`.

## Entry points

```swift
public actor AppAgent {
    public init(services: StudyServices, client: ClaudeClient, runtime: AgentRuntime, memory: DeadlineMemory,
                schedule: CourseSchedule, studyPass: StudyPassPipeline?, now: @escaping @Sendable () -> Date = { Date() })
    public struct Specs { additional: [ConversationKind: AgentRuntime.SpecProvider]; perConversation: [ConversationKind: AgentRuntime.ConversationSpecProvider] }
    public static func specs(services:, search: SearchEngine, drafter: ReplyDrafter?, memory: DeadlineMemory, now:) -> Specs   // .app, .task
    public func send(_ text: String, context: AgentContext, attachments: [AgentAttachment], to: AgentConversation.ID?) async throws -> AgentConversation.ID
    public func stop(_ id: AgentConversation.ID) async
    public nonisolated func liveReplies(_ id: AgentConversation.ID) -> AsyncStream<LiveReply?>
    public func cancelTask(_ id: AgentTask.ID) async
    public func undo(_ change: AgentChange.ID) async throws
    public func undo(sourceID: TrackedItemSource.ID) async throws        // session changes through the log, else DeadlineMemory
    public func start() async; public func wake() async; public func stop() async   // triage, tasks, reminders
    public func record(_ event: AgentEvent) async                                    // producers outside A's packages (none planned)
    public func setBackgroundLimit(_ limit: Int?) async                              // memory pressure: 1; nil: 2 (queue + ClaudeKit slots)
    public nonisolated let changeLog: ChangeLog
    public nonisolated var timetableRecorder: TimetableSessionChangeRecorder        // TimetableImporter.apply(…, sessionChange:)
}
public struct ChangeLog { apply(_:quote:confidence:origin:) -> Outcome; undo(_:); undo(sourceID:); static timetableRecorder(store:) }
public struct AgentCatalog { static build(services:now:) -> AgentCatalog }       // text, revision
public struct AgentContextBlock { static build(_ context:, services:) }          // text, revision, label, glyph
public enum AppAgentChat { static spec(_:); static taskSpec(_:conversationID:) }
public enum AppAgentModule { enum Purpose { app = "agent.app", task = "agent.task", triage = "agent.triage" } }
```

`send` builds the user turn as: the runtime's `<memory>` (when it changed), the attachments (image / document blocks), `<catalog revision>` and `<context revision>` (each only when its revision differs from the last one the conversation's user turns carry), one `<task_result>` per finished task of the conversation no turn has carried (then `reported_at`), the student's words. `agent_turn.context` = `AgentTurnContext(context, label/glyph only when `context.settled` differs from the previous user turn's, attachments)`. The text may be empty when files are attached. A new conversation's title is the first words (or the first file's name).

## The `app` conversation

Opus 5.5, effort medium, adaptive thinking, ≤ 12,000 output tokens, ≤ 14 calls per run, `.interactive`. The system prompt is fixed at the conversation's start (when it started in the university's time zone, `CourseList.promptLines`, the block and tool rules); the runtime appends the memory rules, and every user turn carries the time now as a `<now>` block (`AgentClock`, 2026-10-23: "today" and whether a class has happened go by it). **mr**: the writes below other than add_item, move_item, complete_item, update_item, set_reminder, append_note, undo_change, the memory tools, draft_reply, spawn_task and cancel_task are registered actions reached through find_actions / run_action (same handlers; "mr" section at the end).

| Tool | Effect | Does |
|---|---|---|
| list_lectures, search_lectures, read_slide, read_transcript_span, list_study_items | read | Tutor's lecture tools (cite markers `[[key S13]]`, `[[key 37:59]]`) |
| search_mail, read_mail, list_mail | read, untrusted | MailIntelligence's Q&A tools (`MailChat.mailTools`), `<mail>` envelopes |
| search_notes, read_note | read | the student's notes (Search scope `notes`; plain text ≤ 3,000) |
| query_items | read | items with ids (`untrusted_title` for mail/lecture-made titles) |
| query_sessions | read | sessions (≤ 62 days) with the change markers applied to them |
| query_calendar | read | the "Socrates" rows: sessions of shown courses, items in the calendar, reminders (other calendars are not read) |
| query_memory, list_changes, check_tasks | read | memory with ids; the activity log with `[[change 1a2b3c4d]]` markers; open and own tasks with results |
| add_item, move_item, complete_item, update_item | verified write | `ChangeLog` item changes |
| change_session {room / time / cancel / restore}, add_session | verified write | `ChangeLog` session changes (settled) |
| set_course_fact, set_reminder | verified write | course rules / lecturers; `agent_reminder` |
| append_note | verified write | only with a quote of the student's request; appends blocks (never edits or deletes) |
| remove_course | verified write | only with a quote of the student's request; never a course with recordings or notes (`ChangeLog.removeCourse`, Undo restores it) |
| add_course | verified write | only with a quote of the student's request: `ChangeLog.Request.courseAdd` → `CourseLibrary.insert` (New Course…'s colour, semester, mail rules; recording off), `course_add`; returns the token; Undo deletes it while it holds no lectures, slides, recordings or notes (`CourseTools.swift`) |
| add_weekly_slot, change_weekly_slot, remove_weekly_slot | verified write | only with a quote of the student's request: `.slotAdd` / `.slotChange` / `.slotRemove` → `CourseSchedule.saveSlot` / `deleteSlot` (Course Settings' path: sessions planned, the calendar synced by `onChange`); slots named by the catalog's `[slot 1a2b3c4d]`; a class change on a slot with classes held ends it the day before and adds the slot that takes over (`after.successor`); Undo deletes (with its unfiled sessions), restores the fields written, or puts back the slot |
| undo_change | verified write | `ChangeLog.undo`, only with a quote of the student's request |
| remember, update_memory, forget | verified write | the runtime's memory tools (`logsChanges` for `app`) |
| draft_reply | draft | `ReplyDrafter.writeAgentDraft` (never sends) |
| spawn_task, cancel_task, rerun_study_pass | delegate | `agent_task` rows the queue runs |
| plan_query | read | mc: the study plan, budgets, Ready, the rules with memory ids (`PlanTools`, `CoachCatalog.report`) |
| plan_adjust, mark_away_days, set_course_credits | verified write | mc: `plan` memories with a `PlanRule`, a block moved (`created_by = user`), `course_credits`, through `ChangeLog`; then the coach replans (`Packages/Coach/README.md`) |
| set_profile | verified write | oss: the student's university profile (`university_profile`: university, city, programme, time zone, learning platform, hours per credit) and the current semester's name and lecture period (every course replanned), one `profile` change with Undo (`ProfileTools.swift`); only from the student's own words |

No web tool (the conversation reads mail; web goes through a research task), no send, no other calendar, no delete of the student's notes or recordings. Every write's `quote` + `source` (`chat` / `mail` + id / `lecture` + key / `event` + id) is checked in code (`WriteTools.verified`).

## Sub-agent tasks (`task` conversations)

`AppAgentChat.taskSpec`: the row's model and effort, ≤ 8,000 tokens, ≤ 14 calls, `.background`; tools by group: `lectures` (Tutor's five), `mail` (the three mail tools), `notes`, `items`, `sessions`, `calendar`, `memory` (the query tools), `web` (Claude Code's WebSearch / WebFetch as `ToolSet.webTools`), `apply` (the verified item / session / fact / reminder writes with sources mail (only with `mail`), lecture, event; never chat). `ToolSet` refuses web beside mail. First message: `<task kind title>goal</task>` + `<input>summary</input>` (escaped data). `study_pass` tasks run in code (`StudyPassPipeline.rerun`). mc: `plan` (plan_query) is a tool group too; `question_draft` tasks (`QuestionDrafter.run`) and `practice_exam` tasks holding an old exam (`OldExamReader.read`) run in code, claimed only with Claude Code, paused on a usage limit.

**Queue** (`AgentTaskQueue`): follows `agent_task` (`DatabaseRegionObservation`), so a spawn or cancel anywhere starts or stops work. `claim(slots: limit)` (FIFO, the student's / the panel's — `created_by = user` — before triage's escalations), ≤ `limit` (2; `setBackgroundLimit(1)` under memory pressure). Each runs `runtime.start(.task, …, id:)` with the id set on the row first (the spec provider finds the row by `conversation_id`), awaits `runtime.outcome`, stores the last answer (≤ 4,000) with `finish(.succeeded)`. A usage pause → `pause(until:)` and a wake at the reset; Claude Code missing → back to `queued` without an attempt; cancel → `runtime.stop` (the child is killed) and `cancelled`; a quit leaves `running` rows, `requeueInterrupted()` at the next `start()` (failed after 3), and the conversation continues with "Continue the task…".

## Triage (`FactTriage`)

| Event (producer) | What triage reads | Quote check |
|---|---|---|
| `mail` (`MailExtractor`, decided) | `FactDecision.decided(in: detail)`: the extraction's actions, no call | `MailChat.verifyQuote` (QuoteVerifier + InjectionGuard), dates relative to the mail's Date |
| `transcript` (`TranscriptItemPipeline.recordEvent`) | `TranscriptCues` windows (±2 lines around room/cancel/moved/extra/exam/rule cues, ≤ 120 lines, ≤ 6,000 characters) | `TranscriptQuote.locate` (window, named line or the one before), the first word's time |
| `study_pass` (`StudyPassPipeline.run`, synthesis with said-in-class admin/deadline rows) | the `<said category t summary>quote</said>` rows | an exact span of one of those professor quotes |
| `timetable` (`TimetableImporter.apply`, re-import of existing courses) | the diff (`detail`) | an exact span of the detail |
| `calendar` (`CalendarMirror.keepsEditElsewhere`) | "was … now …" (`detail`) | an exact span of the detail |
| `slides` (`SlideEvents.record`, at launch and after a deck is imported, filed to a course or given its pages: the `deck` / `deck_page` observation) | a course deck's organisational pages found in code (a rule family such as Klausur, Zulassung, exam, admission, bonus, Übungsblatt, Abgabe, attendance, with cue families to a score of 3, 2 under an organisational heading; ≤ 8 pages, ≤ 1,500 characters each) as `<slides deck day><page n>` data; a page that talks to a model (`UntrustedText`) is left out and makes the event untrusted | an exact span (≥ 8 characters) of one page, the page `line` names first; dates relative to the lecture showing it now (else the deck's import) |

One Haiku 5.5 call per batch (≤ 8 events, ≤ 24,000 characters), effort low, ≤ 8,000 tokens, `--json-schema`, `.background`, purpose `agent.triage`: `Today`, the `<catalog>`, `<state>` (the touched courses' facts, sessions ±3 weeks with ids, open items with ids and `by`), the events as `<event id="e1" kind course>` data. Schema: `{events: [{event, actions: [{kind, course, session, session_day, session_kind, item, item_kind, title, details, due, all_day, starts_at, ends_at, room, fact, text, relevance, quote, line, confidence}], escalate, reason}]}` (closed, all required, optional values nullable).

Checks in code (`FactTriage.decide`, `FactApplier`): the quote (above); the dates (`DateMentions` on the quote: the session's day or week, a time change's new day and time, an item's due day; unverified → dropped); ids (the session of the course; the item exists); a room change's room must be in the quote; lecturers must be named in it. **Escalated** (an `escalation` task: Opus 5.5, effort medium, the event's read tools + `apply`, `mail` only for a mail event, never web; the event `escalated` with `task_id`; nothing of the event applied) when: `escalate`, any confidence < 0.7, > 3 actions, an exam moved / done / changed, several sessions fit, or the change log answers `.conflict` (a stronger or newer source stands, or the student's own edit). Otherwise each action → `ChangeLog.apply` (`triaged`, `api_call_id`). Service trouble leaves events `pending` (no attempt) and wakes at the reset; an unusable answer counts an attempt per event (`failed` after 3).

**Slides** (docs/plan-course-rules.md): one `slides` event per course deck version and course (`slides:<deck>:<sha256>:<course>`, `detail` the pages as `<number>:<hash of their words>`), recorded once every page row of the deck is there. A deck gets a `skipped` row, so it is read once, when it has no organisational pages (a scanned deck without text too), when its course's lecture period ended more than 150 days ago (without a semester: its import), or when an earlier event of its course read the same pages already (a weekly deck repeating its organisational slide). Triage skips an event whose deck was filed to another course since (that course's own event reads it). A slides event may give only `course_fact` (never the lecturers) and `item_add` with a verified date that has not passed; `FactApplier.request` refuses the rest for any slide quote, the escalation's too, and takes the course from the deck (an action naming another course is refused); `set_course_credits` refuses slide quotes. It is exempt from the "> 3 actions" escalation; an exam it adds on a day none of the course's open exams has (±1 day) escalates (`FactTriage.addsAnotherExam`). An escalation of slides gets only `items` and `apply` (the pages are in its input). A rule from a slide is a **proposal**: `provenance .ai`, `confirmed_at` nil, its source the deck page (`deck_id`, `page_number`; the lecture showing it is read where the rule is shown: the rule's "S3" chip opens it there, else the deck in Quick Look), Confirm in Course Settings; it stays out of the catalog, triage's `<state>`, reply drafts and the practice exam until confirmed. It fills a missing or empty rule or replaces its own waiting proposal; a rule that stands stays (`.unchanged`), the student's own rule is a `.conflict` (escalated); another source stating the proposal word for word confirms it. Items carry `.external(.slide, reference: "<deck>:<page>")`; their source popover and the activity list read the lecture showing the page when shown (`SourceTrailEntry.readSlide`). Memory is untouched.

## The change log (`ChangeLog`)

`apply(_:quote:confidence:origin:)`: one transaction per change; `Outcome` `.applied(AgentChange)`, `.unchanged` (already so: the source is added to the change's item), `.conflict`, `.refused`. Summaries as DESIGN 9: "Moved to Room 5 · Mon 19 Oct", "Moved to Tue 20 Oct, 12:15", "Cancelled · Thu 5 Nov", "Restored", "Extra session · Fri 6 Nov, 10:15", "Added · Mon 19 Oct, 12:00", "Done", "Updated", "Remembered", "Added to notes", "Reminder · Tue 20 Oct, 23:59". The change's `title` is the target as Today / Calendar name it (`SessionText.title`, the item's title, the course name).

| Request | Writes (one transaction) | Undo (`undo(_:)`) |
|---|---|---|
| sessionRoom / sessionTime / sessionCancel / sessionRestore | `CourseSchedule.edit` (`edited_at`, replan, renumber) + `DeadlineMemory.recordSessionChange` (item `room_change` / `time_change` / `cancellation`, `done`, `lecture_session_id`, its source) + `agent_change` (before/after = `AgentChangeValues.session`) + supersedes the older change of that field | the session's columns from `before` (when no newer change superseded it), the item's source undone (dismissed), the superseded changes stand again |
| sessionExtra | `CourseSchedule.insertSession` (no slot, `edited_at`) + `extra_session` item + change (`before.exists = false`) | the session is cancelled (nothing is deleted) |
| itemAdd / itemMove / itemDone / itemUpdate | `DeadlineMemory.record` / `update` / `complete` (dedup, the calendar rule, `previous`) + `ItemChangeRows` | `DeadlineMemory.undo(sourceID)`; an added item's reminders are cancelled |
| courseFact | `course.rules` (a rule per kind, provenance `ai`, confirmed, its `SourceRef`) or `course.professors` | `professors` / `rules` from `before` |
| noteAppend | the note's blocks + the appended ones (or a new note of the course / lecture) | removes exactly the appended blocks while they are unchanged at the end (a note the change created and that is empty again goes) |
| reminder | `agent_reminder` | `cancelled_at` |
| (memory, `MemoryTools.logged` in Agent) | `agent_memory` + change | forget a created one; text / forgotten from `before` |

`undo(sourceID:)`: the change written with that source; for a second source of an applied session change (no change row of its own) that session change's Undo; else `DeadlineMemory.undo` (M3 items, M2 proposals). Undo writes back only what the change wrote (a session's room, times or cancellation by its kind; the one course rule, or the lecturers), only while the target still holds it; a superseded change only marks its row and its item source undone (`DeadlineMemory.retire`). `timetableRecorder`: logs the import's cancellations as settled changes (source `timetable`, the file's name, model "").

## §4 rules and the functions that enforce them

| Rule (plan §4) | Enforced by |
|---|---|
| Catalog ≤ 8,000 characters, only when changed, never whole lectures / mailboxes / notes | `AgentCatalog.build` (whole lines up to the limit, counts and 3 titles only), `AgentCatalog.lastRevision` in `AppAgent.send` |
| Context with names resolved, sent when changed; the turn's label | `AgentContextBlock.build`, `AgentContextBlock.lastRevision`, `AppAgent.send` (label/glyph when `context.settled` changed) |
| `app` tools: no web, no send, no other calendars, no deletes | `AppAgentChat.spec` (the tools do not exist); `ToolSet` refuses `.write` beside mail readers and web beside mail |
| Verified writes: mail span + dates in it | `WriteTools.verified` / `FactApplier.verify` → `MailChat.verifyQuote`; `FactApplier.request` (`DateMentions` verdicts) |
| …chat: exact span of the student's message, ≥ 3 words | `FactApplier.verify(.chat)` (`AgentToolSupport.span`) |
| …transcript: exact span with its first word's time | `TranscriptQuote.locate` (triage), `LectureQuote.locate` (tools) |
| `append_note` only when the student asks; appends only | `WriteTools.appendNote` (chat quote required; `ChangeLog.appendNote` only appends) |
| Every write in one transaction with its `agent_change` (+ `tracked_item_source`) | `ChangeLog.apply` (static, in `database.write`), `ChangeLog.logSession`, `ItemChangeRows.change`, `MemoryTools.logged`, MailExtractor's `ItemWriter.write`, `TranscriptItemPipeline.apply` |
| Session changes `done` once applied; session row changed, calendar re-synced; Undo restores, dismisses, stamps | `ChangeLog.changeSession` → `CourseSchedule.edit` + `DeadlineMemory.recordSessionChange`; `ChangeLog.init(memory:)` → `memory.didChange()` (the app's calendar sync); `ChangeLog.undo` |
| M2's open proposals stay; no new ones | `MemoryWriter.record` (a proposal finding without a match → announcement); `DeadlineTools.proposeSessionChange` (only an existing open proposal); `ExtractionPrompt.kinds` (no room_change / cancellation items) |
| Conflicts: newest authoritative source wins (Haiku; Opus may overrule), older superseded and kept | `ChangeLog.outranks` checked for `Origin.isHaiku` only (`rank(of:)`: chat > mail > transcript > timetable > calendar; equal rank: `sourceDate(of:)`), `AgentChangeRepository.supersede` in `logSession` / `changeItem` |
| Never let Haiku revert the student's own edit (escalate) | `ChangeLog.editedByStudent`, `item.createdBy == .user`, a user rule → `.conflict` when `Origin.isHaiku` → `FactTriage.decide` escalates |
| Triage: producers write events without a model | `MailExtractor.factDecision` (inside the extraction call), `TranscriptItemPipeline.recordEvent`, `StudyPassPipeline.run`, `TimetableImporter.apply` / `diff`, `CalendarMirror.keepsEditElsewhere`, `SlideEvents.record` (the `deck` / `deck_page` observation, once at launch) |
| Rules from slides are proposals; never over a rule that stands or the student's own; never the lecturers | `ChangeLog.setFact` (`confirmedAt` nil for a slide origin; lecturers refused), `FactApplier.request` (the deck's course, lecturers refused), `RuleRow` (Confirm), `AgentCatalog` / `FactTriage.stateBlock` / `ReplyDrafter` / `PracticeExamSheet` (`isConfirmed`) |
| One Haiku call per batch (≤ 8 / ≤ 24,000), `--json-schema`, effort low | `FactTriage.batches`, `FactTriage.request`, `FactTriage.schema` |
| Escalation (confidence < 0.7, escalate, conflict, exam move/cancel or a slide's exam on another day, > 3 actions except from slides) → Opus medium task, never web | `FactTriage.decide`, `FactTriage.touchesExam`, `FactTriage.addsAnotherExam`, `FactTriage.escalate` |
| Tasks FIFO, the student's first, ≤ 2 running (1 under pressure), `.background` | `AgentTaskRepository.claim`, `AgentTaskQueue.wake` / `setLimit`, `AppAgent.setBackgroundLimit`, `AppAgentChat.taskSpec` (`priority = .background`), `ClaudeCodeSlots` |
| `web` only beside `lectures`, whose tools then leave out the student's notes (never notes, memory, calendar, items, sessions, plan, mail, documents or apply); a web task's result is untrusted text for its parent | `AppAgentChat.webCompanions` / `webRefusal` in `DelegateTools.spawnTask` and `taskSpec` (`TaskToolsError`; `TutorChat.lectureTools(…, includeNotes: false)`: search_lectures on scope `.materialWithoutNotes`, read_slide without `note`), `ToolSet(webTools:)` (`webToolsBeside`; a `.task` set: no `.verifiedWrite` beside web), `AppAgent.carriesUntrustedResult` |
| A web task spawned by a conversation that read mail: no input summary, the goal is a verified quote of the student's words | `RunTrace` (seeded by `AgentRuntime.send` from the conversation's earlier turns: an open mail, a mail tool call; by `AppAgent.send` for a mail task's result; set by `AgentRuntime.launch` for an open mail, by `ToolSet.handler` for mail tools, by `check_tasks` returning a mail task's result), `DelegateTools.spawnTask` |
| Result ≤ 4,000; unreported results in the parent's next user turn | `AgentTaskQueue.lastAnswer`, `AgentTaskRepository.finish`, `AppAgent.send` (`<task_result>`, `markReported`) |
| Usage limit → paused; cancel ends the process; re-queue at launch; model tasks never claimed without Claude Code | `AgentTaskQueue.runConversation` (`pause`), `AgentTaskQueue.cancel` / `stopCancelled` (`runtime.stop`), `AgentTaskQueue.start` (`requeueInterrupted`), `AgentTaskRepository.claim(kinds:)` |
| A quit writes no failure: tasks stay `running`, triage batches `pending` | `AppAgent.prepareForQuit` (in `willTerminate` before `ClaudeCodeEngine.terminateRunningProcesses`), `QuitSignal` in `AgentTaskQueue.runConversation` / `FactTriage.triage` |
| Activity log of every automatic change; "what did you change?" from it with Undo | the writers above; `QueryTools.listChanges` (markers); `AppAgent.undo` → `ChangeLog.undo` |
| Reminders: exam admission 24 h and 2 h before, registration windows the day before; notifications; authorization on the first; Undo cancels; never stale | `ReminderCenter.planAutomatic`, `deliverDue` / `isStale` (> 1 h late, item not open, moved), `authorize`, `scheduleNext` (the next one, however far); `AppAgent.start` follows `agent_reminder`; `ChangeLog.undo` (`.reminder`, `cancelReminders`), `ChangeLog.changeItem` (a move cancels) |
| Attachments as content blocks before the words; images ≤ 1,568 px (HEIC → JPEG); PDFs; text as a titled text document; ≤ 5. An image or a PDF names the bytes it sends in the BlobStore (`BlockSource.blob`, 2026-10-27; a re-encoded image's JPEG is kept when made and listed as the attachment's `sentBlob` in the turn's context), so the turn stays under iCloud's record size | `AttachmentBlocks.block` / `image` (limits from `AgentAttachment`) |
| Processes: interactive never waits behind background | `ClaudeCodeSlots` (ClaudeKit) |

## Requests for the integrator

1. **project.yml**: link `AppAgent` (package `Packages/AppAgent`) to the macOS and iOS app targets (and `tools/ParityRender` if it builds the app's wiring). Nothing else new: UserNotifications and ImageIO are system frameworks.
2. **AppModel** (plan §8.2):
   ```swift
   let specs = AppAgent.specs(services: services, search: engine, drafter: mailPipeline.drafter, memory: memory)
   let runtime = AgentRuntime(services: services, client: client, memory: memory,
       additionalSpecs: [.mailChat: { … }, .tutor: { … }].merging(specs.additional) { $1 },
       conversationSpecs: specs.perConversation)
   let agent = AppAgent(services: services, client: client, runtime: runtime, memory: memory,
                        schedule: CourseSchedule(services: services), studyPass: studyPassPipeline)
   await runtime.recoverInterrupted()     // as before (app conversations a quit left running → failed)
   await agent.start()                     // in startBackgroundWork, after the pipelines
   ```
   `wake()` on new mail, finished transcriptions, study pass units, timetable imports, calendar changes and Claude Code turning available (it also follows `agent_event` and `agent_task` itself; a wake is a nudge). `NSApplication.willTerminateNotification` → `await agent.stop()` (before `ClaudeCodeEngine.terminateRunningProcesses()`). Memory pressure (`memory_pressure` < 25 % free) → `await agent.setBackgroundLimit(1)`, back → `nil`.
3. **The panel** (`AgentPanelActions`, ChatUI): `send` → `agent.send(text, context:, attachments:, to:)`; `stop` → `agent.stop(id)`; `liveReply` → `agent.liveReplies(id)` mapped to `ChatLiveReply(afterTurns:text:)`; `cancelTask` → `agent.cancelTask`; `undoChange` → `agent.undo(_:)`; `isAvailable` / `pausedUntil` from `client.availability()`.
4. **Undo elsewhere**: `DeadlineActions.undo` and Mail's Undo → `agent.undo(sourceID:)` (session changes through the log, else the deadline memory).
5. **Timetable import**: pass `sessionChange: agent.timetableRecorder` to `TimetableImporter.apply` (else the import's cancellations are not in the activity log; they are still applied).
6. **Calendar**: edits made in Calendar.app are seen by full syncs (`CalendarMirror.sync(full: true)`, at launch). Call it on `EKEventStoreChanged` too if edits should be noticed while the app runs.
7. **Notifications**: `ReminderCenter` asks for authorization the first time a reminder is due (`UNUserNotificationCenter`; no entitlement for an unsandboxed Mac app). Never `start()` the agent in a process without a bundle (parity tools): `UNUserNotificationCenter.current()` needs one.
8. **Purposes**: `api_call.purpose` = `agent.app`, `agent.task`, `agent.triage` (with `billing = subscription`). `AgentCostGuard` (the transcript extraction's $0.50/day gate) sums every `agent.*` purpose, so the panel's and tasks' notional costs now count against it; consider restricting it to `agent.transcript` (a one-line change in Agent) — left as it is here.
9. **CLAUDE.md**: "One claude process at a time" becomes 1 interactive + 2 background; CLAUDE.md is updated by the integrator, not here.
10. **StudyCore**: no change needed. Automatic reminders use `SourceRef.Kind("agent")` for their change rows (StringKind; the panel may draw it with a generic glyph).

## Design notes for the integrator (decisions rows)

| Decision | Why |
|---|---|
| The mail extraction's answer carries session changes, course facts and `escalate`; MailExtractor writes them as a decided `mail` event that AppAgent applies through the change log without a call | no second call per mail (plan §1), and MailIntelligence cannot depend on AppAgent (AppAgent depends on it) |
| Room changes and cancellations are no longer item kinds of the mail extraction; a proposal finding without an existing proposal becomes an announcement | auto-apply with Undo replaces M2's Confirm; M2's open proposals still work |
| Session changes are written by `ChangeLog` with `CourseSchedule.edit` (in the transaction: `edited_at`, replan, renumber) and a `done` tracked item of the change's kind | the session row, its item, the item's source and the log row commit together; the calendar re-syncs from the row |
| Source ranks: the student's words in chat > mail > the lecture > a timetable file > a calendar edit elsewhere; equal rank: the newer source | plan §4, with the student's own request in the panel ranked highest (they are the authority on their data) |
| Haiku never overrules the student's own edits or a stronger source; Opus (escalations, the panel) may | the student's edits are deliberate; a careful decision can still follow a lecturer's mail |
| Undo of an extra session cancels it; undo of an appended note removes exactly the appended blocks (a note the agent created and that is empty again goes) | nothing the student made is ever deleted |
| A transcript event goes to triage only when cue lines exist, and triage reads only ±2-line windows (≤ 120 lines) | "never load whole lectures"; most classes cost no triage call |
| A calendar edit elsewhere is kept in Calendar.app until triage decided; then the session's version is written again | the student's edit is not overwritten before the agent looked at it |
| Automatic reminders go through the change log (listed, undoable); a reminder that was cancelled is never planned again | every automatic change is in the activity log; Undo sticks |
| `spawn_task` from the panel is `created_by = user` | the claim order puts the student's (and the panel's) tasks before triage's escalations |
| A task's `apply` tools take sources mail (only with the `mail` group), lecture or event, never chat or web | a sub-agent has no student's words, and web pages are never a source of a change |
| The context line (`label`, `glyph`) is set only when `AgentContext.settled` changed since the previous message | the thread draws the faint line only before an exchange whose screen changed |
| The panel's memory writes (`remember` etc. in `app`) log `agent_change` rows in their transaction (`MemoryTools.logged`) | "Remembered" rows in "what did you change?" with Undo |

## M7: the iPhone's questions (workstream B)

`AgentRequestPickup` (internal; owned and started by `AppAgent.start()` on macOS only, woken by `AppAgent.wake()`, stopped by `stop()`): the Mac answers the questions asked in the iPhone's agent sheet. The phone writes each as an `agent_request` row (+ `agent_request_file` rows with the bytes) into the `app` conversation (a new chat's empty conversation row is written by the phone: ChatUI README "M7"); iCloud sync carries them here.

- **At start** `requeueInterrupted()` (running → pending: a quit while answering), then it follows `agent_request` (`DatabaseRegionObservation` of `SELECT id, state FROM agent_request`; no polling) and answers what waits.
- **A pass**: `pending(excludingDevice: AgentRequest.mac)`, oldest first, one at a time; nothing is claimed while Claude Code is not installed or signed out (the app's wake when it turns ready starts the next pass) or while a usage pause holds (a wake at the reset). Per request: `claim` → a pause that began meanwhile `release`s it → its files into the BlobStore (`AgentAttachment.make(data:contentType:fileName:blobs:)`, the panel's accept rule and limits) → `AppAgent.send(text, context: request.context ?? .today, attachments:, to: request.conversationID)` (the panel's own path: Opus 5.5, the interactive slot, unchanged prompts and blocks) → `runtime.outcome` → `finish(_, conversationID:)` once the run ended `finished` (its answer turn stored), else `fail` with the run's readable sentence.
- **Exceptions**: `busy` (the Mac's own panel answers in that conversation) → `release`, retried after that run; `unknownConversation` (its row not synced yet) → `release`, retried in a minute (one timer); a file the Mac refuses → `fail` ("A file of the question could not be read on the Mac."); any other thrown send → `fail` with `ReadableError.sentence`. A pause or failure after the message was stored fails it (sending it again would put the question twice in the conversation); a quit while answering re-queues it at the next start (then it may be asked twice, as a sub-agent task's "Continue").

### Requests for the integrator
1. Nothing new to call: `agent.start()` starts the pickup (macOS), `agent.wake()` (already called when Claude Code turns available) wakes it, `agent.stop()` stops it. Never on iOS (the phone has no AppAgent running; `#if os(macOS)` inside).
2. With sync off (this build) no row from another device ever arrives, so the pickup only re-queues and waits.

### Design notes (decisions rows)
| Decision | Why |
|---|---|
| The phone's questions are answered by the Mac through `AppAgent.send`, one at a time, oldest first, on the interactive slot | AI runs on the Mac only (PRD); the same prompts, tools and conversation as the panel; at most one interactive claude process |
| A usage pause or a missing Claude Code leaves the questions pending (claimed ones released); a failure after the message was stored fails the question with the readable reason | nothing is lost while the Mac cannot answer; no question is put into a conversation twice |
| Woken by the database observation of `agent_request` (sync writes rows), no polling | no timers while nothing changes |

## md: the document bank (workstream A)

New code in `DocumentTools.swift` and `DocumentTaskRunner.swift`; `AppAgentChat`, `ChangeLog` and `WriteTools` got only registration lines (other branches edit them). Package.swift += `Documents`.

- **Catalog**: a "documents" section (`DocumentCatalog.lines`, ≤ 1,600 characters, newest first): `doc 3f2a9c1e: Modulhandbuch M.Sc. Informatik · handbook · 6 pages · DC, CL · added Mon 19 Oct`, "· reading" while the text or summary is pending, "· unreadable" / "· not summarised" after a failure, then "+N more (search_documents)". Titles escaped.
- **Tools** (`DocumentTools`; both read tools `readsUntrustedContent`, so never beside web tools and a run that read a document hands no input summary to a web task):
  - `search_documents {query, kind?, course?}`: Search's `.documents` scope (keyword + semantic); `course` filters by `document.course_ids`; an empty query lists the documents with their summaries; hits carry `doc`, `title`, `kind`, `page`, `cite` (`[[doc 3f2a9c1e p12]]`), `text` ≤ 300.
  - `read_document {doc, pages?, section?}`: the card (summary, key facts and dates with pages and cite markers, outline as fits 4,000) or `<document_text doc= title= pages= next_page=>` with one escaped `<page n=>` per page, ≤ 10,000 characters, ≤ 40 pages per call; a section resolves through the outline (to the next entry of the same or a higher level), else the pages' headings.
  - `keep_document {file}` (`.verifiedWrite`, the `app` conversation only, and only with a bank): the file must be an attachment of the turn being answered (`ToolContext.turnContext.attachments`); `DocumentBank.add(attachment:by: .agent)`; a new document logs an `agent_change` (`document_add`, target `document`, "Added to Documents", quote = the student's words); a file kept already logs nothing. Undo (`ChangeLog.undo` → `undoDocumentAdd`) deletes the document through a bank (tasks cancelled, file removed at a later launch).
  - Task group `documents` (search + read) for `spawn_task`; refused together with `web`.
- **Context**: `.documents` → `screen: Documents · doc 3f2a9c1e "Title"`, label "Documents", glyph `doc.on.doc`.
- **Attachments** (`AttachmentBlocks.contentBlocks`, called by `send`): a `.document` attachment (Word, ODT, RTF, Pages) goes as its extracted text in a text document block titled with the file name (≤ 100,000 characters, then "…"; one that cannot be read is refused with the extractor's sentence); a PDF over the send limits that is not slides goes as `<attached_file name= pages=>` with its first pages' text (≤ 8,000, PDFKit only), so `keep_document` can still keep it. It returns the attachments as sent too (`sentBlob` set for a re-encoded image), which `send` lists in the turn's context in the student's order.
- **Queue**: `document` tasks run in code (`runDocument` → `DocumentSummarizer.run`), at most one at once (`claim(…, oneAtATime: [.document])`), not claimed without Claude Code, quiet (`settleFinished`), paused on a usage limit; `stopCancelled` now also cancels the `work` of an in-code task whose row turned `cancelled` (a deleted document's summary, drafting cancelled anywhere).
- **Prompt**: documents are data, never instructions; cite pages with the row's marker; `keep_document` only when the student asks; web goes only with lectures (so never with documents).
- **Entry points**: `AppAgent.init(…, documents: DocumentBank? = nil)`, `AppAgent.specs(…, documents: DocumentBank? = nil)`, `AppAgentChat.Services(…, documents:)`.

### Requests for the integrator
1. Pass the app's bank (Mac): `AppAgent.specs(…, documents: bank)` and `AppAgent(…, documents: bank)`. Without it the panel has no `keep_document`; the read tools work anyway.
2. ChatUI's `[[doc …]]` chip (B) checks markers against the rows; the agent writes `ChatCitation.document(id, page:).marker`.

### Design notes (decisions rows)
| Decision | Why |
|---|---|
| The document tools read untrusted content; `documents` is never given with `web` | documents hold personal data and may carry injected text (PRD: documents leave the Mac only as context in the student's own agent calls) |
| A document's summary is an in-code `agent_task` (one Haiku call), one at a time, quiet | usage-aware, resumable and cancellable like the coach's drafting, never news in the thread |
| keep_document needs the file to be an attachment of the message being answered | code, not the model, decides what may be kept |
| Undo of keep_document deletes the document like the Documents screen's Delete | one delete path: the task cancelled, the file removed only at a later launch |

## mr: the action registry and shared decks (workstream A)

### Checklist (resumable after a usage limit)

- [x] 1. Registry: `ActionRegistry.swift` (`AgentAction`, `ActionRegistry`, `ActionRegistry.app`), `ActionTools.swift` (`find_actions`, `run_action` with the untrusted rule).
- [x] 2. Deck actions: `ChangeLog.Request.deckLink` / `.deckUnlink`, `.deckSpan` Undo, `link_deck_pages` / `unlink_deck` (`DeckTools.swift`), `wakeProcessing`.
- [x] 3. `AppAgentChat.spec` (the direct set + find_actions + run_action), the system prompt's write rule, `AgentCatalog` (actions line, decks, lecture ranges).
- [x] 4. Tutor (`TutorLibrary`, `LectureTools`: the lecture's range), ChatUI `ChatCitations` (a slide marker only inside the range).
- [x] 5. READMEs (this section, Tutor).
- [x] Built: `taskpolicy -b swift build -j 4` of AppAgent (`--package-path Packages/AppAgent`), then Tutor and ChatUI (each `--package-path Packages/<P> --scratch-path Packages/AppAgent/.build`, reusing AppAgent's compiled graph). Agent untouched.

New code in `ActionRegistry.swift`, `ActionTools.swift` and `DeckTools.swift`; `AppAgentChat` (the tool list, the write rule), `ChangeLog` (two requests, the deck Undo, `wakeProcessing`), `AgentCatalog`, `AppAgent` (`wakeProcessing`, the catalog's count) got the lines the plan needs. No StudyCore change: the landed `LectureSlides` / `DeckLinkResult` / `deck_link` / `deck_unlink` contracts are used as they are. No model call, no new conversation kind.

### The action registry

- **`AgentAction`** (public): `name` (snake_case, the direct tool's name), `summary` (one line, ≤ 100 characters), `keywords` (English and German), `parameters` (the tool's input schema without `quote` / `source` / `source_id`, with the tool's description as the schema's own `description`, so the model reads the same rules the direct tool carried), `sources` (`chat`, `mail`, `lecture`, `event`), `studentOnly`, `undo` (`.changeLog`, or `.cancelTask` for rerun_study_pass) and `handler` = the tool's own `AgentTool.handler`, unchanged.
- **`ActionRegistry`** (public): `init` refuses names that are not snake_case or repeat (`ActionRegistryError`); `count`, `action(named:)`, `find(_:limit:)`, `run(name:params:quote:source:sourceID:context:)` (callable without a model: menus later).
- **`ActionRegistry.app(_ deps)`** registers, in this order: add_item, move_item, complete_item, update_item, set_reminder, append_note, undo_change, change_session, add_session, set_course_fact, remove_course, add_course, add_weekly_slot, change_weekly_slot, remove_weekly_slot, plan_adjust, mark_away_days, set_profile, set_course_credits, keep_document (only with the document bank), rerun_study_pass, link_deck_pages, unlink_deck, (ln) write_lecture_notes, set_notes_length, keep_notes_answer: 26, 25 without the bank (`appCount(documents:)`, the catalog's line). Student-only: undo_change, remove_course, add_course, the three slot actions, set_profile, keep_document, rerun_study_pass, link_deck_pages, unlink_deck and the three notes actions. Sources `chat` only: those and append_note, plan_adjust, mark_away_days, set_profile; the rest take `chat`, `mail`, `lecture`, `event` as their direct tools do.
- **Adding an action** is one registration: build its `AgentTool` as any write tool (quote and source checked in its handler, the change through `ChangeLog` with its row and Undo), then append `AgentAction(tool, summary:, keywords:, sources:, studentOnly:)` in `ActionRegistry.app` and bump `appCount`. It is never a direct tool unless the student uses it in most conversations.
- **`find_actions {query, limit?}`** (`.read`): the query folded (`TextFolding`) and split into words (function words and repeats left out); score per action = 3 per word equal to a part of the name + 2 per word that hits a keyword (equal, or a shared prefix of ≥ 5 letters: "Folien" hits "Foliensatz", "Übungsblatt" hits "Übung") + 1 per word of the summary; ties in registry order; the best `limit` (default 4, ≤ 8) with a score above 0 as `{total, actions: [{name, summary, parameters, sources, student_only}]}`; nothing matched: every action's `{name, summary}`. Deterministic, no model.
- **`run_action {name, params, quote, source, source_id}`** (`.verifiedWrite`, not strict: `params` is any object): an unknown name → an error naming find_actions; `params` must be an object (null counts as `{}`; its own `quote` / `source` / `source_id` are overwritten by the top level); the action's handler runs with `ToolUseBlock(name: action, input: params + quote + source + source_id)` and the same `ToolContext`, and its output (the `[[change …]]` cite) is returned as it is.
- **The untrusted rule** (in `ActionRegistry.run`, so a menu caller gets it too): once the run has read mail, a document or a web task's result (`context.trace.hasReadUntrustedContent`), only `source: chat` (the action's own check then needs an exact span of ≥ 3 words of the student's message), and find_actions then lists only `chat` among an action's sources (`AgentAction.sources(readUntrusted:)`); a `studentOnly` action takes only `chat` at any time; a source the action does not list is refused.

### The `app` conversation's tools (mr)

In this fixed order: Tutor's five lecture tools, the three mail tools, search_notes, read_note, query_items, query_sessions, query_calendar, query_memory, list_changes, check_tasks, plan_query, search_documents, read_document (reads); add_item, move_item, complete_item, update_item, set_reminder, append_note, undo_change (direct writes); draft_reply (with a drafter); spawn_task, cancel_task (delegate); find_actions, run_action; then the runtime's remember, update_memory, forget. Everything else is only an action. Task conversations are unchanged (their `apply` group keeps its direct tools). The system prompt's write rule names the direct writes and says "Anything else (sessions, course facts, courses, weekly classes, the plan, credits, keeping a document, a study pass, a lecture's slides): find_actions with a few words, then run_action"; the `<catalog>` description names "slide decks"; the rest of the prompt is unchanged.

| Tool | Effect | Does |
|---|---|---|
| find_actions | read | the registry's keyword match (above) |
| run_action | verified write | one registered action's own handler (above) |
| link_deck_pages {lecture, deck, first_page?, last_page?} (action) | verified write, student-only | `ChangeLog.Request.deckLink` → `LectureSlides.link(source: .manual)`: the lecture's range of the deck made or changed (other lectures' ranges stay; null pages: 1 / the deck's last); `deck_link` row "DC Lecture 1 · Uses DC L2’s slides 1–20" |
| unlink_deck {lecture, deck} (action) | verified write, student-only | `.deckUnlink` → `LectureSlides.unlink`: the coarse span and the lecture's timed spans on that deck go, the deck stays; `deck_unlink` row "No longer uses …" |

`deck` is the catalog's `[deck 1a2b3c4d]` key (or its 8 hex), a deck id, or a lecture reference meaning that lecture's current slides (`LectureSlides.current`); `lecture` as the other tools take it (`WriteToolsLookup.lectureID`).

### Deck changes in the log

| Request | Writes (one transaction) | Undo |
|---|---|---|
| deckLink / deckUnlink | `LectureSlides.link` / `unlink` (+ the `align` jobs they queue) + `DeckLinkResult.change(sourceKind: origin's, quote:, confidence:, model: origin's)` completed with the origin's columns (`ItemChangeRows.apply`, `finalize`; `lecture_id` stays the lecture whose slides changed, `api_call_id`); already so → `.unchanged("Already uses DC L2’s slides 38–88.")`; a `DeckLinkError` → `.refused` with its sentence, nothing written | `ChangeLog.undo` of target `lecture_deck_span` → `LectureSlides.undo` in the transaction that marks the row (`DeckLinkError.changedSince` → `UndoRefused.changedSince`); the static in-transaction `undo` has the same case. This also undoes continuation detection's `deck_link` rows (B writes them) |

`wakeProcessing` (`AppAgent.init`, `AppAgent.specs`, `AppAgentChat.Services`, `ChangeLog.init`; default `{}`) runs after an apply or an Undo that queued `align` jobs, so the processor re-aligns the lecture's recordings against the new range.

### Catalog (mr)

`AgentCatalog.build(services:now:actions:)`: the panel's catalog gains "actions: 22 more writes through find_actions / run_action" under the head line (triage's has none: `actions` nil); after the open items (so the 8,000 cut drops them first), per course a line of the decks a lecture reference cannot name (`needsKey`: on no lecture, on 2 or more, a range that is not the whole deck, or not its one lecture's current slides), newest first, at most 6 then "+N older": `decks DC: [deck ae4abf08] Virtualization & IaaS · 88 slides · L2 1–37, L3 38–88` (a deck's course is its own, else its lectures'; lectures by when they were held; "on no lecture" when none links it); a lecture line shows its range ("slides 38–88") when it is not the whole deck. Triage's catalog (`actions` nil) has no deck lines or ranges and reads no spans. Ranges are read as `LectureSlides.current` reads them (each lecture's newest coarse span), in the catalog's one read. Within the 8,000 limit as before (whole lines, then "cut short").

### ChatUI (`ChatCitations.swift`, A's one ChatUI file)

`CitationRows.LectureRow.pages` replaces `pageCount`: a lecture's slides are `LectureSlides.current(…).pages`, so `[[key S50]]` is a chip only inside its lecture's range (`slide_outside_deck` else); a lecture with only timed spans (stamps, no coarse span) keeps the old rule (1 to its decks' largest page count). Nothing else in ChatUI changed.

### Requests for the integrator

1. **Wire `wakeProcessing`** in `App/Shared/AppModel.swift`, on both: `AppAgent.specs(…, wakeProcessing: { [weak processor] in await processor?.wake() })` (the panel's link_deck_pages / unlink_deck / undo_change run through the specs' change log) and `AppAgent(…, wakeProcessing: { [weak processor] in await processor?.wake() })` (the panel's change rows' Undo). `processor` is built before both.
2. Nothing else: no `project.yml`, no migration, no new package dependency.

### Design notes for the integrator

DESIGN 9 strings: "Uses DC L4’s slides 21–40" (a `deck_link` row; the deck named by the earliest other lecture that uses it, else "slides 21–40 of Virtualization & IaaS"), "No longer uses DC L4’s slides 21–40" (`deck_unlink`), the title "DC Lecture 5" (the lecture whose slides changed); "Already uses …" (the tool's note, never a row).

| Decision | Why |
|---|---|
| The app agent's rare writes are registered actions behind two tools (`find_actions`, `run_action`) with their direct tools' own handlers; the direct set is add_item, move_item, complete_item, update_item, set_reminder, append_note, undo_change (+ the memory tools, draft_reply, spawn_task, cancel_task) | every request carries fewer tool definitions (cheaper, the cached prefix fixed per conversation); a new write is one registration, not a new tool; no behaviour change (same checks, change rows and Undo) |
| `find_actions` matches by folded words: 3 per name part, 2 per keyword hit (equal or a shared prefix of ≥ 5 letters), 1 per summary word, ties in registry order, best 4 (≤ 8), else every name and summary | deterministic, < 1 ms, no model; English and German keywords; the model can always see the whole list |
| A found action's parameters carry the tool's own description | the rules the direct tool's description stated (when to use it, what each value means) still reach the model |
| `run_action` takes only `source: chat` once the run read mail, a document or a web task's result; a student-only action (courses, slots, removals, keep_document, rerun_study_pass, the deck actions, undo_change) takes only `chat` at any time | text from content can never trigger a rare write; the student's own words (an exact span of ≥ 3 words, checked by the action) always can |
| `link_deck_pages` / `unlink_deck` change only the lecture's link through `LectureSlides` (deck numbers kept, other lectures' ranges untouched, no PDF cut or copied), logged with Undo | the model: slides belong to the course whole; a lecture names a deck and a page range |

## ln: lecture notes (workstream A; docs/plan-lecture-notes.md §5.6)

- **Runner** (`LectureNotesTaskRunner.swift`): `lecture_notes` tasks run in code (`runsInCode`), one at a time (`claim(…, oneAtATime: [.document, .lectureNotes])`), only with Claude Code: `NotesWriter.run(notesID:)` on the version `LectureNotesRepository.notes(taskID:)` finds. done → `succeeded` with an empty result (quiet; a version the agent queued from the chat reports "Summary written: …" into that conversation), waiting → `wait(task, until:)`, failed → `failed` with the writer's sentence. A cancelled task cancels its version (`cancel(taskID:)`, also from `cancel_task` and the panel's Cancel); a quit writes nothing (the version is resumed at the next launch). `AppAgent(…, notesWriter:)` passes the writer to the queue; nil: the tasks fail "Summaries are not written on this device."
- **Read** (`LectureNotesTools.readLectureNotes`, an `app` tool): `read_lecture_notes(lecture, section?)`: the outline, then whole parts from a section on (≤ 8,000 characters a call, `next_section` continues), each with the student's highlights and kept answers, as data. The catalog's lecture line gains "notes · 2,140 words" (or "notes being written", "notes failed").
- **Actions** (registered, student-only, source chat, a change row and Undo each; `ChangeLog+LN.swift`): `write_lecture_notes(lecture, request?)` → `LectureNotesRepository.queue(createdBy: .agent)`, kind `lecture_notes`, target `lecture_notes`, the task reports into the conversation; Undo cancels the version while it is open, else discards it. `set_notes_length(length, course?)` → a `preference` memory with its `notes_rule` (kind `notes_rule`, target `memory`; an older rule of the same scope is forgotten and superseded); Undo forgets it as any memory change. `keep_notes_answer(lecture, passage, question, answer)` → the passage must be in the current notes (`LectureNotesText.part(holding:in:)`), the question a span of the student's message or a question of the Ask exchange they took to the panel, the answer's chips checked (`NotesChipCheck`); a `lecture_notes_mark` of kind `answer` created by the agent, kind `notes_answer`, target `lecture_notes_mark`; Undo removes the mark.
- **Context** (`AgentContextBlock`): a course screen with `courseScreen` "lecture_notes" and the lecture names the notes page ("screen: lecture notes · DC L3 …", label "DC Lecture 3"); `notesPassage` adds the passage, its section and the Ask exchange as delimited data.

## The lecture plan and the clock (2026-10-23)

- **The clock.** `AgentRuntime` puts `AgentClock.block(now)` (`<now>Thu 22 Oct 2026, 23:30 · Example City (Europe/Lisbon)</now>`) as the last block before the student's words in every user turn it writes (`start`, `send`, always on `retry`); the five system prompts say when the conversation started, that the student's words are read against their own turn's `<now>` and that the latest `<now>` decides whether a class has happened (`AgentClock.promptLine`). Words written earlier than their turn: an iPhone question (`AgentRequestPickup` passes `request.createdAt`) and a queued sub-agent task (`task.createdAt`) add "; asked Thu 22 Oct 2026, 23:30" to the block; Try again's `<retry>` says when the restated words were written. The tools read relative days against that time (`ToolContext.wordsWrittenAt`: the quote checks, `move_lecture`'s day check, the deadline date checks), never against the time of the Try again or the pickup. The `app` prompt lists `<now>` first among the blocks; the catalog's sessions line is "sessions from today" (clock-free, the catalog's revision stays the same all day). `ClaudeCodeConfiguration.clockTag` lets the readers skip it: `ChatTranscript.isContextBlock` (never shown as the student's message), `AgentRuntime.lastStudentMessage` (Try again keeps the words and the quote check), `ToolLoopPrompts.history` (a replayed session keeps its `<mail>` context).
- **Actions** (registered, student-only, source chat, a change row and Undo each; `LecturePlanTools.swift`, `ChangeLog+Plan.swift` → `FilingService+Plan`):

| Action | Does | Row / Undo |
|---|---|---|
| `move_lecture {lecture, session \| date, later, quote}` | the lecture to a class of its course (`date` "YYYY-MM-DD": the course's numbered class that day, else its meeting; "THH:MM" picks one of two). A class whose own lecture stays keeps it, and this one joins the meeting (dated to its start, without the link). `later: follow`: the planned lectures numbered after it (linked to a class after now, no recording, no running job) go to the free numbered classes after it, in order; those left over are undated (`unplaced`). The quote must state the day of the class it goes to or leaves (`states`: a date, today, a coming weekday, a week, or for the past six days "yesterday" / its weekday's name). Refused: another course, a cancelled class, a recorded lecture to a class that has not happened, both recorded, a recording being processed, a lecture with nothing of its own beside the class's lecture | `lecture_edit` (target `lecture`): every touched lecture before and after (`AgentChangeValues.lectures`); Undo all or none, refused when a touched lecture changed or was filed into since, a recorded one would go back to a class that has not happened, or a class or number it goes back to is another lecture's now |
| `edit_lecture {lecture, title?, number?, later_numbers, quote}` | rename and renumber (1–999); `later_numbers` moves every lecture numbered after the old number by the same step; a number another lecture has is refused (naming it) | `lecture_edit` |
| `move_recording {recording, to, quote}` | a recording (its key from list_lectures' `recordings` or `recordings_without_lecture`, which it places, or a lecture with one; a "lecture/recording" key whose recording part matches none is refused) into another lecture through `FilingService.move` (transcript, stamps, notes, flags, jobs; the old lecture's study pass dropped, alignment or transcription queued; the processor woken). The lecture it leaves stays even when its filing created it (`keepsEmptiedLecture`; delete_lecture removes it). Another course only when the quote names that course (`CourseList.names`, the deadline parser's course match); refused while a job of the recording runs, or when it is in that lecture already (checked in the move's transaction) | `filing` (target `filing`), undone like the filing advisor's |
| `delete_lecture {lecture, quote}` | an empty lecture (no recording, slides, notes, kept answers, flags, practice answers or sections the student said it covered) through the delete's own plan | `lecture_delete`: `before.deletion`; Undo refused when its class or number belongs to another lecture now |
| `set_lecture_coverage {lecture, material, sections, covers, quote}` | one or more sections of a material, one transaction | `material_coverage` with `coverages` before and after; Undo all or none |

- **Reads.** list_lectures rows gain `class` (the class's day and time, or "with DC L2" for a joined lecture) and `recordings` ("key · start · length"); query_sessions rows gain `lecture` ("L3 9a7d94d1"). 2026-10-27: list_lectures also gives `recordings_without_lecture` ("key · start · length", a course's only with `course`), the recordings filed with no lecture that no screen shows, so the student can have them placed with move_recording.
- **The prompt.** The write rule's "Anything else" names a lecture's class, date, number or title, a recording's lecture and an empty lecture; one rule says how the plan works (later lectures are decks filed ahead), when to use which action, that whether a class has happened goes by `<now>`, never to say it cannot change lectures, to explain a refusal in one sentence, and to ask once whether a chapter is a lecture or a book section.
