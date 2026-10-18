# Coach

Milestone mc, the study coach (PRD "Study coach"). Two targets, two owners:

- `Coach` (workstream A, logic only, no SwiftUI): `CoachEngine` (implements StudyCore's `StudyCoaching`), the plan engine (`study_block` rows), the FSRS scheduler, rounds and practice exam assembly, Haiku question drafting (a `question_draft` task the AppAgent queue runs in code), Opus grading of written answers, old exams, the university profile's items.
- `CoachUI` (workstream B, SwiftUI): the plan hero shared by Today and Study, Study, a course's Progress, the practice round, the practice exam (sheet, exam, results).

They meet only in StudyCore (rows `study_*`, `CoachMeasures`, `StudyCoaching`, `UniversityProfile`) and StudyUI (`\.studyCoach`, `StudyDestination.study` / `.courseProgress` / `.practice` / `.practiceResults`, `DurationText`). CoachUI never imports Coach.

No automated test suite at present; verified by building and rendering: for CoachUI, that an off-screen render of the coach's sample rows matches the study coach mockups.

Each workstream adds its checklist (resumable after a usage limit), entry points, "Requests for the integrator" and "Design notes for the integrator" below.

## Workstream A: `Coach` (logic)

Depends on StudyCore, ClaudeKit, Deadlines (Agent), StudyPass and GRDB. AppAgent depends on Coach (the plan tools, the catalog lines, the task queue's code runners); Coach never imports AppAgent, so everything that goes through the change log (plan rules, credits, the profile's items) is written by AppAgent.

### Checklist (resumable after a usage limit)

- [x] 1. StudyPass: its planner reconcile, `rerun(lectureID:)` and pending-unit reads touch only `read` / `synthesize` / `research` (`StudyPlanner.stages`), so `quiz` units survive a study pass; `LectureText` (the pass's line ids, the slide of each line, page texts) for drafting.
- [x] 2. Coach: `CoachEngine`, `CoachRows`, `PlanEngine` (`Planner`), `Scheduler`, `CodeGrading`, `RoundBuilder`, `PracticeExamBuilder`, `QuestionDrafter` (+ `DraftedQuestion`, `QuoteCheck`, `CoachSchema`), `AnswerGrader`, `OldExamReader`, `ProfileItems`, `CoachCatalog`, `CoachModule.Purpose`.
- [x] 3. AppAgent: `PlanTools` (plan_query, plan_adjust, set_course_credits, mark_away_days), `AgentToolGroup.plan` → plan_query for tasks, `CoachCatalog.lines` in the catalog, `<reminder>` blocks in `AppAgent.send`, `AgentTaskQueue` code runners (`question_draft`, an old exam's `practice_exam`), `ChangeLog` `.courseCredits` / `.planRule` (apply + Undo), `ProfileItemWriter` (in `AppAgent.wake`), `AppAgent.init(…, coach:)` / `AppAgent.specs(…, coach:)`; Agent: memory change rows keep `planRule` before / after.
- [x] 4. This section.
- [x] Built: `taskpolicy -b swift build --package-path Packages/AppAgent -j 4` (builds Coach, Agent, StudyPass, ClaudeKit). No live model call.

### Entry points

```swift
public actor CoachEngine: StudyCoaching {
    public init(services: StudyServices, client: ClaudeClient, now: @escaping @Sendable () -> Date = { Date() })
    public func start() async      // follow the rows, replan now, grade what waits
    public func wake() async       // grade pending answers again, replan (study pass units done, Claude Code available)
    public func stop() async       // willTerminate: rows stay pending, picked up at the next launch
    public func replan() async     // now (the agent's plan tools wait for it)
    public nonisolated let drafter: QuestionDrafter    // AgentTaskQueue's `question_draft` runner
    public nonisolated let oldExams: OldExamReader     // AgentTaskQueue's old-exam `practice_exam` runner
    // StudyCoaching: start(block:), previewRound, startRound, answer, override, end,
    //                previewExam, startExam, submitExam, retake, addOldExam
}
public enum PlanEngine { static func plan(_ rows: CoachRows) -> Output }        // pure: rows in, blocks out
public struct CoachRows { static func load(_ db:now:profile:); statuses; status(_:) }   // one read, every measure
public enum Scheduler { rating(of:), card(after:limits:), review(_:rating:at:limits:) }
public enum RoundBuilder { build(scope:size:questions:lectures:misses:runway:now:), minutes(for:) }
public enum PracticeExamBuilder { build(source:minutes:questions:taught:defaultMinutes:exclude:now:), points(of:) }
public enum CodeGrading { grade(_:for:) }                                       // choice, label, an empty written answer
public struct QuestionDrafter { run(lectureID:) -> Outcome }                    // done / waiting(until:) / failed
public struct OldExamReader { read(task:) -> Outcome; static input(of:); struct Input }
public enum ProfileItems { wanted(_ rows:), wanted(db:now:) -> [Item] }         // AppAgent writes them
public enum CoachCatalog { lines(db:now:token:), report(db:now:from:through:token:) }
public enum CoachModule { Purpose.draft = "coach.draft", .grade = "coach.grade", .oldExam = "coach.old_exam"; timeZone }
public enum CoachText { duration(minutes:), slides(_:_:), dayTime(_:allDay:), day(_:), range(_:_:), weekdays(_:) }
```

The engine follows `course`, `lecture`, `lecture_session`, `tracked_item`, `agent_memory`, `study_question`, `study_answer`, `study_reading` and `study_unit` (`DatabaseRegionObservation`, debounced 2 s, then at most one replan every 15 s while rows keep changing), replans at midnight in the university's time zone and after its own writes (answers, an ended round, a submitted exam: `replanSoon`). `study_block` and `study_session` are not followed (its own writes; the screens write only drafts, flags, position and pause).

### Plan §4 rules and the functions that enforce them

| Rule (plan §4) | Enforced by |
|---|---|
| Budget: `self_study_hours`, else credits × 30 h − class hours; unknown credits → 6 and the agent asks once | `StudyBudget.make` via `CoachRows.status` (`CourseStatus.budget`, `creditsUnknown`); `CoachCatalog.courseLine` ("credits unknown (planned with 6; ask the student once)"); the `app` system prompt (`AppAgentChat.system`) |
| ⅔ over the term, ⅓ over the runway; the week's share | `StudyBudget.termHours` / `runwayHours` / `weeklyShare(containing:)` via `CoachRows.status` (`weeklyShare`); `Planner.share`, `Planner.remaining` |
| A seminar (form `seminar`, or no exam item) has no weekly share unless `seminar_hours`; seminar steps backward from its items | `CoachRows.status` (`isSeminar`; share 0 unless `PlanRules.plansSeminarHours`), `Planner.share`, `Planner.seminarSteps` (one step a week toward the next item within 21 days) |
| Progress counts recall (Ready); hours only show pace; pages never count | `Readiness.share` / `TopicMastery.byTopic` in `CoachRows.status`; no page count anywhere |
| Studied time: answers' seconds + done blocks without a session | `StudyTime.studied` in `CoachRows.status`; `spent_seconds` from `Planner.doneSeconds` (settled by `CoachEngine.performReplan`) and `CoachEngine.finishBlock` (a session's active time) |
| Phases (never labelled): term, break, runway = the last 5 weeks before the week of the exam sat (first by default, `sitting`) | `StudyBudget.isRunway` with `CourseExams.resolve` + `PlanRules.sitting` (`CoachRows.status`), `CoachRows.isBreak`; `CoachRows.pickSemester` keeps the semester through its break and exams until the next one's lectures begin |
| Back-to-back exams share one runway, interleaved | each course's runway from its own exam; the day's one round mixes the courses (`Planner.round`), `RoundBuilder.interleave` in the runway |
| After a failed or skipped first date the runway re-targets the second | `plan_adjust` `sitting` 2 (`PlanTools.courseRule` → `PlanRules.sitting` → `CourseExams.sat`) |
| Day plan from today to 14 days ahead as `study_block` rows | `PlanEngine.plan` → `CoachEngine.performReplan` → `StudyPlanRepository.replacePlanned` (skipped when nothing changed: `CoachEngine.same`) |
| Day size: free 08:00–20:00 outside attended sessions, capped by the week's remaining share over its remaining study days (days without class carry the most), by a `cap` rule, on away days by the away cap | `CoachRows.freeMinutes` (`PlanRules.attends`), `Planner.dayLimit` (`PlanRules.cap`), `Planner.capacity` (the share spread by each day's room), `Planner.planDay` (away: `PlanRules.isAway`, `PlanRule.awayMinutes`) |
| Away day: one round (misses first) plus one short read | `Planner.planDay` (no reviews, sheets or exams), `Planner.round(on:away:)` (≤ 12 questions), `Planner.read(on:room:away:)`; misses first at Start: `RoundBuilder.build` |
| First blocks (1): an exam-admission item due within 48 h | `Planner.gates` (also a seminar's short gate and a registration item from a week before it closes) |
| (2) Review of a lecture ≤ 2 days old (or before the next lecture builds on it), weakest topic's slides first | `Planner.recentLectures`, `Planner.review` (the weakest open topic, grown over adjacent open topics up to 90 min; a lecture without topics whole) |
| (3) due practice items | `Planner.round` (due cards counted once over the 14 days, ≤ 8 new a day, ≤ 24 questions) |
| (4) an exercise sheet due within 3 days: admission-gated first, ≤ 3 h, the day before when it is due on an away day | `Planner.sheets` (105 min a block, 180 min a sheet, admission first), `Planner.workDay` |
| (5) a runway practice exam | `Planner.practiceExams` (one per course and runway week, in the exam's length) |
| (6) Read only as gap-fill (gap, a topic missed twice, named by the lecturer); never in the last 3 days | `Planner.read` (`CoachRules.noReadDays`) |
| Classes and deadlines never move; clashes stay visible | blocks carry no times; the planner never writes items or sessions |
| Reviews pulled forward before an away block, spread after it | `Planner.recentLectures` (a review falls on the first day with room within 2 days of the class, never on an away day), `Planner.backlogLectures` (one a day after it, two on break days) |
| Today fixed once the day began (done and started never change; an urgent admission item or `plan_adjust` may add or drop planned ones) | `Planner.todayIsFixed`, `Planner.planDay` (today's branch: the kept blocks minus skip rules, plus `gates`), `StudyPlanRepository.replacePlanned` (never deletes started / done / skipped), `PlanTools.planAdjust` (a skipped block at once) |
| The student's blocks (`created_by = user`, `plan_adjust move`) are never moved or dropped | `Planner.planDay` (`placed`), `PlanTools.move` |
| Later days rewritten on every replan | `Planner.planDay`; `CoachEngine.start` (observation), `replanSoon`, `scheduleNewDay` |
| Expired one-day rules forgotten | `Planner.run` (`Output.expiredRules`) → `CoachEngine.performReplan` (`AgentMemoryRepository.forget`) |
| Block done (derived) | `Planner.doneSeconds` (review: `reviewed_at` or `CoachRows.reviewedPage` past its last slide; round / exam: session ended or submitted; exercise / seminar step: item done; read: recall answered or `done_at`); a past day's planned block → skipped (`Planner.run`); `CoachEngine.finishBlock` |
| Scheduler: FSRS-5 defaults, 90 %; wrong → Again, partial → Hard, right → Good | `Scheduler.rating(of:)`, `Scheduler.review`, `Scheduler.card(after:limits:)` (replays the answer log), `CoachEngine.recard` |
| A new or missed question comes back later in the round until right once | `CoachEngine.answer` (`StudySessionRepository.append`, ≤ 3 times a round) |
| The interval never passes the sat exam (runway ≤ 30 % of the days left; final week ≤ 3 days); due on an away day → the day before | `Scheduler.Limits.due` (limits from `CoachEngine.limits(for:db:now:)`) |
| Mastery dots and Ready only from `TopicMastery` / `Readiness` | `CoachRows.status`, `RoundBuilder.build`, `PracticeExamBuilder.build`, `Planner.review` |
| Rounds: due (misses, then oldest due), then new of the weakest and newest topics, then (integrator, when short) seen cards not due yet, weakest topic first; ≈ 1.2 / min, written ×3, ≤ 2 written; runway interleaving; a Read block's round = its recall questions | `RoundBuilder.build`, `RoundBuilder.weight` / `minutes(for:)`, `RoundBuilder.interleave`; `CoachEngine.start(block:)` (`.read` without a URL → `StudyScope.reading`) |
| Practice exam: All lectures (weighted to weak), Weakest, one old exam; length = `CourseRule.minutes` else 90; ≈ 1 point a minute; least recently used first; Retake = new questions, same settings; Untimed keeps the questions | `PracticeExamBuilder.build` / `points(of:)`, `CoachRows.CourseStatus.examMinutes`, `CoachEngine.startExam` / `retake` (excludes the last exam's questions) |
| Never a grade estimate | nothing computes one (`study_session.score_points` is points only) |
| Drafting: per topic 4 round questions (2 choice, 1 short, 1 why) + 1–2 exam-pool questions with points and a model answer, title, slide, the professor's quote checked in code | `QuestionDrafter.request` / `system`, `QuestionDrafter.build` (≤ 4 round, ≤ 2 exam per topic; the slide within the topic's slides), `DraftedQuestion.checked`, `QuoteCheck.locate` / `apply` (an exact span of a line's `original_text`, else dropped) |
| ≤ 3 readings per lecture (further-reading rows or the lecturer's named literature; a URL only from a further-reading row), 2–3 recall questions each | `QuestionDrafter.build` (readings), `QuestionDrafter.groups` (`wantsReadings`) |
| Slides and transcript go in as delimited data | `QuestionDrafter.request` (`<topic>`, `<slide>`, `<line>`; `CoachXML.escape`) |
| Haiku 5.5, effort low, ≤ 4 topics / 24,000 characters, `--json-schema`, `.background`, `coach.draft`; `study_unit` stage `quiz` with an input hash, a done unit never called again | `QuestionDrafter.model` / `effort` / `topicsPerCall` / `characterLimit`, `QuestionDrafter.groups` (hash), `reconcile`, `finish`, `countFailure` |
| Queued once per lecture after its study pass wrote topics | `CoachEngine.queueDrafting` (synthesis done, nothing pending, a topic without questions, once per topic set: `fingerprint`; the semester's courses only) → `AgentTaskQueue.runDrafting` (claimed only with Claude Code) |
| A re-run study pass relinks by `TopicKey`; a vanished topic's questions are retired; never deleted | `QuestionDrafter.draft` (`StudyQuestionRepository.relink`, `retire`) |
| Grading: Opus 5.5 medium, `--json-schema`, `.background`, `coach.grade`; one call per round answer, one per exam (≤ 8 answers); the student's answer as delimited data | `AnswerGrader.run` (batches), `AnswerGrader.request` / `system` |
| A usage pause leaves answers pending; `failGrade` after errors | `AnswerGrader.run` (`waiting`), `CoachEngine.runGrading` / `scheduleGradeWake`, `StudyAnswerRepository.failGrade` |
| Choice and label graded in code at once | `CodeGrading.grade` in `CoachEngine.answer` / `submitExam` |
| Count as wrong / Change Points…: the student's grade wins, Claude's stays in `model_score` | `CoachEngine.override` → `StudyAnswerRepository.override`, `recard`, `rescore`; `setGrade` keeps an override |
| Old exam: Opus medium, the PDF as a document block, `coach.old_exam`, origin `old_exam`, read once | `CoachEngine.addOldExam` (once per PDF and course) → `AgentTaskQueue.runOldExam` → `OldExamReader.read` |
| Agent tools: plan_query; plan_adjust (verified chat quote ≥ 3 words → `plan` memory + `agent_change`, replan; `move` → the block row, `created_by = user`, through `ChangeLog.Request.planMove` with Undo); set_course_credits (`course_credits` with before / after); mark_away_days | `PlanTools.planQuery` / `planAdjust` / `move` / `setCourseCredits` (the quote must state each number) / `markAwayDays`; `ChangeLog.Request.planRule` (`rememberRule`: an older rule of the same scope is forgotten and superseded, Undo brings it back) and `.courseCredits` (`setCredits`; Undo while unchanged); `AgentToolGroup.plan` → plan_query (`AppAgentChat.taskSpec`) |
| Catalog: one line per course (credits · budget · Ready · this week · exam) and today's plan in one line | `CoachCatalog.lines` in `AgentCatalog.content` |
| No UI toggles for any of this | the four tools and the memory only |
| Profile items: one "Register for exams" per registration window (no course, its last day 23:59, "<registration system> · 18–29 Jan", relevance `registration`, source `profile`, the rule as quote), through the change log, never twice; the second-date window only once a second date is sat | `ProfileItems.wanted`, `ProfileItemWriter.apply` (in `AppAgent.wake`; a key with any change row is never added again) |
| Reminders: the existing ones; the newest `app` conversation's next user turn carries reminders delivered since as `<reminder>` blocks | `ReminderCenter.planAutomatic` (unchanged), `AppAgent.reminderBlocks` in `AppAgent.send`, the `app` system prompt |

### Drafting schema (`QuestionDrafter.schema`; closed objects, every property required, optional values null)

```
{ "topics":   [ { "topic": "t1", "questions": [Question] } ],
  "readings": [ { "title", "section", "byline", "minutes": int, "first_slide": int|null, "last_slide": int|null,
                  "topic": "t2"|null, "reason": "gap"|"lecturer"|"depth", "further_reading": "f1"|null,
                  "quote": string, "line": "l12"|null, "questions": [Recall] } ] }
Question = { "format": "choice"|"short"|"explain"|"calculation"|"label", "pool": "round"|"exam", "title", "prompt",
             "choices": [string], "correct_choice": int|null, "model_answer", "explanation", "points": int,
             "slide": int|null, "diagram": Diagram|null, "quote": string, "line": string|null }
Recall   = Question with "format": "choice"|"short"
Diagram  = { "stacks": [ { "title", "rows": [[ { "text", "blank": bool } ]] } ], "terms": [string] }
```

Checked in code: a choice has exactly 4 options and a right one (2 points); a label diagram's blanks are among its terms (a point a box); a written question has a model answer (explain / calculation 10–18 points, short 2); a round question is never a label or a calculation; titles ≤ 6 words; the slide lies in the topic's slides (else its first); the quote is an exact span (≥ 8 characters) of the named line or of the topic's lines, else dropped. Old exams (`OldExamReader.schema`): `{ "title", "minutes": int|null, "questions": [Question without pool / quote / line, plus "number": int, "lecture": "L2"|null, "topic": string|null] }`, the printed points kept.

### Grading schema (`AnswerGrader.schema`)

```
{ "grades": [ { "id": "a1", "result": "right"|"partial"|"wrong", "score": number, "verdict": string } ] }
```

`score` 0…1 (an exam item: the share of its points; points = score × points, to the half point); the verdict is cut to 40 words ("Right. Name the rule too: Popek and Goldberg."; "9 of 12 points. …"). An item left out counts a failed attempt for that answer.

### Requests for the integrator

1. **project.yml**: package `Packages/Coach` (products `Coach`, `CoachUI`) for the macOS and iOS app targets; `tools/ParityRender` + Coach. AppAgent's manifest already depends on Coach.
2. **AppModel** (plan §8.2), in this order:
   ```swift
   let coach = CoachEngine(services: services, client: client)                      // macOS; nil on iOS
   let specs = AppAgent.specs(services: services, search: engine, drafter: mailPipeline.drafter, memory: memory, coach: coach)
   let agent = AppAgent(services: services, client: client, runtime: runtime, memory: memory,
                        schedule: CourseSchedule(services: services), studyPass: studyPassPipeline, coach: coach)
   // environment: \.studyCoach = coach (nil on iOS)
   // startBackgroundWork: await agent.start(); then await coach.start()   (the coach queues tasks the agent's queue runs)
   // study pass units finished, Claude Code turned available: await coach.wake() (beside agent.wake())
   // willTerminate: agent.prepareForQuit(); await coach.stop(); await agent.stop()
   ```
   Memory pressure: `agent.setBackgroundLimit(1)` also slows drafting (the queue); grading uses ClaudeKit's background slots.
3. **Purposes** (`api_call.purpose`, billing `subscription`): `coach.draft` (Haiku 5.5, low), `coach.grade` (Opus 5.5, medium), `coach.old_exam` (Opus 5.5, medium). `AgentCostGuard` sums `agent.*` only, so the coach's calls do not count against the transcript extraction's gate.
4. **Old exam PDFs**: `addOldExam` imports the file into the BlobStore and queues a `practice_exam` task (`created_by = user`, its input the JSON of `OldExamReader.Input`), shown in the task list as "Old exam: …".
5. **Live check (§8.4)**: one `question_draft` task for DC L2 on the parity copy (queued by `CoachEngine.queueDrafting`, or enqueue one with `lecture_id` set) and one `coach.wake()` for the pending 7 / 12 written answer.
6. **StudyCore**: no change needed.

### Design notes for the integrator (decisions rows)

| Decision | Why |
|---|---|
| The plan is rows (`study_block`) written by a pure planner over one read (`CoachRows`); the screens, the catalog and `plan_query` all measure through StudyCore's `CoachMeasures` | one implementation, so Today, Study, Progress and the agent never disagree; a replan stays well under 100 ms |
| Today's plan is set by the first replan of the day and then fixed; later days are rewritten on every replan | a plan that changes under the student's eyes is not a plan; tomorrow follows every new fact |
| Row-following replans debounce 2 s and then wait 15 s while rows keep changing; the engine's own writes nudge it | a review's saved position or a burst of mail must not replan every few seconds |
| The planning semester runs from its first lecture until the next semester's first lecture; only its courses are planned and drafted | its break and exam runway (Feb/Mar) lie after its lecture period; old courses cost no usage |
| A card is replayed from its whole answer log | a late Opus grade or an override gives the card it would have had |
| Successive relearning appends the missed question to the round (≤ 3 times) | rounds are short; the miss comes back while the context is fresh |
| Drafting runs as an `agent_task` (`question_draft`) in code, resumable by `study_unit` rows (stage `quiz`, input hash), once per lecture topic set | the PM-with-sub-agents queue (≤ 2 background, paused on usage limits, visible in the task list) and no repeated Haiku calls |
| Quotes are exact spans of a line's `original_text`; a reading's URL only from a further-reading row | the professor's words can be played and their corrections drawn; no invented links |
| Plan rules are `plan` memories with a typed `PlanRule`, written through the change log; a newer rule of the same scope forgets the older one (Undo brings it back) | "Manage it through the agent": forgetting the memory drops the rule; "at most 4 h" after "at most 2 h" must win, not the smaller cap |
| `set_course_credits` checks that the quote states each number | the credits drive the whole budget; a model must not guess them |
| Profile items are written by AppAgent (change log, source `profile`, one key per window) on every wake | listed and undoable; an undone window is never added again |
| `<reminder>` blocks go only into the newest `app` conversation, for reminders since its last student message | "done" / "remind me at 22:00" refers to what was just shown, without a reminder row in the thread |
| No grade estimate anywhere; exams show points only | PRD: never a grade estimate |

## CoachUI (workstream B)

### Checklist (resumable)
- [x] 1. CoachUI: `PlanHero`, `StudyView`, `CourseProgressView`, `PracticeView`, `PracticeExamSheet`, `PracticeExamView`, `PracticeExamResultsView`, `MasteryDots`, `PracticeCommands`, the sentence player (`SentencePlayer`: `AVAudioPlayer` over the recording's segment file, stopped at the sentence's end; no Review dependency).
- [x] 2. CoursesUI Today: the hero is `PlanHero` of the first open block when today has `study_block` rows; subtitle "Tuesday, 20 October 2026 · 5 h 15 min planned"; Coming up gets each course's next lecture while the hero is a plan block and drops the hero's own item. `Packages/Courses/Package.swift`: CoursesUI depends on `../Coach` product `CoachUI`.
- [x] 3. This section.

Built once with `taskpolicy -b swift build --package-path Packages/Courses -j 4`, which compiles CoachUI (as CoursesUI's dependency) and CoursesUI.

### Entry points
All views take an optional `now:` where it matters (a fixed moment for renders; nil follows the clock) and read their rows with `@Fetch` (one `FetchKeyRequest` each). They need `\.defaultDatabase`; for actions `\.studyCoach` (nil: Start, Practice, Practice exam, Retake, Review misses, Count as wrong, Change Points…, Add Old Exam… are not offered; rows still draw) and `\.studyServices` (session writes: position, drafts, flags, pause / resume through `StudySessionRepository`).

| View | Shown for | Notes |
|---|---|---|
| `PlanHero(plan: PlanDay, courses:, now:)` | Today's hero, Study zone 1 | `PlanDay.fetch(db, day:)` reads the day's blocks, their items and trails. Start → `coach.start(block:)` → `StudyStart` through `\.openDestination` / `\.openURL`; `.examSheet` presents `PracticeExamSheet` itself. |
| `StudyView(now:)` | `StudyDestination.study` | sets agent context `.study` |
| `CourseProgressView(courseID:now:)` | `.courseProgress(id)` | sets agent context `.course` + `"progress"`; presents `PracticeExamSheet` itself |
| `PracticeView(sessionID:now:)` | `.practice(id)`, session `kind == .round` | End → the course's Progress (one course) or Study |
| `PracticeExamView(sessionID:now:)` | `.practice(id)`, session `kind == .exam` | pauses itself on disappear; Submit / 0:00 → `.practiceResults(id)` |
| `PracticeExamResultsView(sessionID:)` | `.practiceResults(id)` | sets agent context `.course` + `"progress"` |
| `PracticeExamSheet(courseID:now:)` | a sheet (Progress, the hero, ParityMode) | Start → `.practice(id)` |
| `MasteryDots(TopicMastery)` | wherever a topic shows | help "Mastery 1 of 4 · again Tue 20 Oct" |
| `PracticeCommands()` | the app's `.commands { }` | reads `FocusedValues.practiceActions` |
| `HeroCard`, `HeroButtonLabel`, `.heroButtonStyle()` | Today's heroes too (moved here from CoursesUI) | StudyUI is their home once promoted |

### Keys (the Practice menu, `PracticeCommands`)
| Key | Action | When |
|---|---|---|
| 1–4 | Choice 1–4 | a choice question while nothing is typed (a round before its answer; an exam) |
| Space | Play Sentence | a round after the answer, nothing typed |
| → | Next Question | a round after the answer, nothing typed |
| ⌘↩ | Submit Answer | a round's written answer |
| ⇧⌘[ / ⇧⌘] | Previous / Next Question | an exam |
| ⇧⌘L | Flag / Unflag | an exam |
| (menu) | Pause / Resume, Submit, End | also in the exam's toolbar and bar, the round's toolbar |
| ↩ | Start (hero, sheet), Practice (Progress), Review misses (results), Resume (paused exam) | the screen's one default action; Esc cancels the sheet |

### Strings (as built)
"Start", "Then …", "planned", "Week 3 of 17", "Courses", "Ready", "This week", "Weakest topics", "Exam Tue 9 Feb, 10:00", "Second date …", "Progress", "Practice", "Practice exam", "Resume practice exam", "Practice This Topic", "Read J&M §4.9 · 15 min", "Topics and reading", "ready", "of 120 h self-study", "Slides 15–16" / "Slide 5", "Questions from", "All lectures", "Old exam", "Add Old Exam…", "Length", "Untimed", "Written", "Oral", "Cancel", "Next question", "Count as wrong", "End", "Flag", "Flagged", "Pause", "Resume", "Submit", "1 question has no answer" / "N questions have no answer", "Review misses", "Retake", "Questions", "Your answer", "Model answer", "Right", "Wrong", "Change Points…", "Change", "Points", "N questions", "N points", "of N points", "Question N · M points", "Mastery N of 4 · again Tue 20 Oct", "Exam admission", "· due Mon 19 Oct, 23:59", "Sources"; the menu: "Practice", "Choice 1"–"Choice 4", "Play Sentence", "Submit Answer", "Next Question", "Previous Question", "Unflag".

### Requests for the integrator
1. **Routing** (`RootView.open`): `.study` → `StudyView()`; `.courseProgress(id)` → `CourseProgressView(courseID: id)` (selects the course's Progress row); `.practice(id)` → read the session's `kind`: `.round` → `PracticeView(sessionID:)`, `.exam` → `PracticeExamView(sessionID:)` (already submitted → `PracticeExamResultsView`); `.practiceResults(id)` → `PracticeExamResultsView(sessionID:)` pushed on the course's Progress (sidebar and panel back).
2. **Sidebar**: `SidebarItem.study` after Notes, before Search, glyph `brain`, title "Study"; a course's Progress row between Notes and Course Settings, glyph `chart.bar`, title "Progress".
3. **Go menu**: Today, Calendar, Mail, Notes, Study ⌘1–⌘5; Search ⌘6; ⌘F unchanged.
4. **Full window**: `.practice` hides the sidebar (restored on leaving). An exam session (`kind == .exam`, not submitted) also hides the agent panel, its launcher and the toolbar search field until it is submitted. Leaving needs nothing else: `PracticeExamView` flushes its draft and pauses in `onDisappear`.
5. **Commands**: `PracticeCommands()` once in the macOS scene's `.commands`; the screens publish `practiceActions` with `focusedSceneValue`.
6. **Environment**: `\.studyCoach` (the `CoachEngine`; nil on iOS) and `\.studyServices` on the window's root.
7. **Agent context**: Study `.study`; Progress and results `.course` + `"progress"` (the views set them).
8. **ParityMode.Launch** (renders, plan §8.3): `study`, `courseProgress(course)`, `practice(session)` (round or exam by kind, with the full-window state applied), `examSheet(course)` (Progress with `PracticeExamSheet` presented), `practiceResults(session)`; pass the render's `--now` as the views' `now:`.
9. **StudyUI** (optional, later): promote `HeroCard` / `HeroButtonLabel` / `heroButtonStyle()` and `Fill2` (CoachUI keeps them; ChatUI has its own `Fill2`); a `.screenTitle(_:subtitle:)` taking a `Text` subtitle (meanwhile `PracticeExamView` draws "1:16:05 left" in SF Mono with its own toolbar title on macOS).

### Design notes (DESIGN 8.7 "Study coach", as built)
- **Today** (mockups 11, 12): with `study_block` rows for today and one still open, the hero is `PlanHero` of the first open block (else the review / session hero as before). Eyebrow: course dot + name (a round over several courses: dots + short names, "Data Centers · CL"); an item's "· due Mon 19 Oct, 23:59" in tertiary; on an away day `tram` leads (tertiary), nothing else says so. Title 22 pt semibold. Meta: detail · length (SF Mono digits) · the grey why, or for an exam-admission item "· ★ Exam admission" + one source glyph with its trail popover. Start (filled, ▶, ↩), beside it "Then Lecture 2 · slides 13–21 · 1 h 30 min" ("Then read J&M §4.9 · 15 min"; the last separator tertiary). Subtitle "Tuesday, 20 October 2026 · 5 h 15 min planned" (every block but skipped ones, done included). Coming up adds each course's next lecture (later weekly lectures stay out) and leaves out the hero's item.
- **Study** (mockup 13): 680 pt column, zones 28 pt apart. Subtitle "Week 3 of 17" (`TermWeek`). Zone 1 the same `PlanHero`. Zone 2 "Courses", column heads "Ready" and "This week": dot, name over "Exam Tue 9 Feb, 10:00" / "Second date Wed 7 Apr, 10:00" once sat / a seminar's next due item ("Survey Mon 26 Oct, 12:00 · 12 places"); Ready "22%" over a 4 pt meter (a seminar: none); "2 h of 6 h 10 min" (studied in primary medium, durations rounded to 5 min; nothing for a seminar without seminar hours); a click opens Progress. Zone 3 "Weakest topics" (≤ 6 seen topics, by mastery then next due): dot, "Data Centers · Paravirtualization", a `TimeChip` "L2 · 37:10" on hover, `MasteryDots`; a click opens the lecture at the topic's slide and second; context menu Practice This Topic. Nothing at all: the `brain` glyph.
- **Progress** (mockup 14): 760 pt column. Hero eyebrow "Exam Tue 9 Feb, 10:00 · Hall A · Second date Wed 7 Apr" (+ the form once announced). Two figures, "22 % ready" and "2 h 10 min of 120 h self-study", each over a meter. Practice (filled, ↩) with the aside from `previewRound` ("12 questions · 10 min"); in the runway a plain "Practice exam" opens the sheet, aside the last settings ("8 questions · 90 min"); an exam in progress offers "Resume practice exam". "Topics and reading" by lecture, newest first: head "L2 · Virtualization Basics" + date over a hairline; topics weakest first (dots, title, "Slides 15–16"; TimeChip on hover; a click opens the lecture at the second; context menu Practice This Topic, and Read … when a reading is mapped); then the readings (`book`, title + faint source glyphs with the trail popover, "Slides 5–21", length; a click opens it). A lecture with every topic solid and its readings read is a closed group (chevron, count).
- **Practice round** (mockup 15): full window, 680 pt column. Title "Practice", subtitle "Data Centers · 4 / 12", [End]. Zone 1: course dot + "Lecture 2 · Paravirtualization" + the topic's dots; the question (title 2); four choice rows with keys 1–4, or the answer field (⌘↩). Zone 2 once answered (an answer row of this session at this position): the slide (`SlideImageView`), the verdict (choice: the pick keeps the neutral fill with a grey cross, the right one semibold with the green check, the rest dim; written: Claude's grade as one grey AI block with one sparkle, "Right." semibold; pending: the model answer in grey), the professor pin + name + `TimeChip` (the lecture at slide and second), the quote in curly quotes under the 3 pt amber bar with the transcript's corrections as ~~old~~ new, the explanation; [Count as wrong] (written) [**Next question** →]. Space plays the sentence.
- **Practice exam sheet** (mockup 17): Questions from [All lectures | Weakest topics | each old exam | Add Old Exam…], Length [the announced length | 60 / 90 / 120 min | Untimed] + a faint source glyph (help: where the length comes from); "8 questions · 90 points" (`previewExam`); Cancel (Esc) / **Start** (↩). A dropped PDF becomes an old exam (`addOldExam`).
- **Practice exam** (mockup 18): full window, nothing else. "Practice exam" over "Data Centers · 2 / 8 · 1:16:05 left" (SF Mono, ticking each second); toolbar [Flag] [Pause]. "Question 2 · 12 points", the question (title 2) in its form: choices (1–4), a short or long field (content surface, radius 10, accent focus ring), a label diagram (drag a term onto a box or click the box and type; drag a token back to the bank to remove it). The glass bar: ‹ 1…8 › (filled = answered, ring = current, small flag) | **Submit** (filled once all are answered, else it asks once: "N questions have no answer"). Pause covers the question; leaving pauses; 0:00 submits and opens the results. Drafts save as they are typed.
- **Results** (mockup 19): pushed on the course's Progress. "71 of 90 points", "1 h 24 min of 90 min"; Review misses (filled, ↩: a round of the misses) and Retake. "Questions" in exam order: number, title, "9 / 12", a miss's `TimeChip` "L2 · 38:28"; a row opens Your answer beside Model answer, then Claude's grade (grey, one sparkle); context menu Change Points…; an old exam's questions carry the amber quote bar. No grade anywhere.

## M7: the iPhone (workstream B)

### What changed
- **`CoachEngine(services:)`** (Coach): the phone's coach, without a Claude client (`init(services:client:)` now takes `ClaudeClient?`; the Mac passes its client as before). Rounds and `start(block:)` work, choices and labels are graded in code and the cards replayed as on the Mac (FSRS, successive relearning); a written answer is recorded `pending` and graded by the Mac once sync carries it. `start()` does nothing without Claude (no plan loop: the Mac's plan comes down), `grade()` does nothing, `drafter` / `oldExams` are nil (AppAgent's queue reads them as optional: "The study coach does not run on this device.").
- **`PhoneLayout`** (CoachUI): `@PhoneLayout var isPhone`, true at a compact width on iOS, never on the Mac (its layouts unchanged). **`PhoneHeroButton`**: the iPhone's one filled button, the whole width, a capsule, 17 pt semibold (Start, Start review, Record, Next / End).
- **`HeroCard`** on the phone: padding 16/16/14, radius 22, 4 pt between lines (mockup 16 `.hero`).
- **`PlanHero`** on the phone (mockup 16 left): the eyebrow 13 pt (dots 8, the tram 13), the title 26 bold, the meta 15, Start the whole width under the thumb, "Then read J&M §4.9 · 15 min" centred under it (13). A practice exam block has no Start on the phone.
- **`PracticeView`** at a compact width (mockup 16 right): one question per screen. The navigation bar's inline title "Practice" over the subtitle "6 / 12" (iOS 26 `navigationSubtitle`), End (`xmark`) leading. The course dot + "CL Lecture 1 · ELIZA" (the course's short name: the bar does not name the course) + the topic's dots (13 semibold); the question 24 bold; answer rows of at least 52 pt (radius 16, `QuietFill`; the pick on Fill 2, a grey cross when wrong; the right one semibold with the green check; the rest dim; no key caps); a written answer in a 120 pt field (radius 16, accent ring while editing) with Submit. After the answer: the professor's pin, surname and `TimeChip`, the quote (15 pt) under the 3 pt amber bar, the explanation (13 pt, one sparkle); a written one first shows Claude's grade, or the model answer while the Mac has not graded it. No slide on the phone. Next (End on the last) under the thumb in a bottom bar (`safeAreaBar`), [Count as wrong] beside it for a graded written answer.
- **Progress** on the phone: no Practice exam / Resume practice exam (practice exams stay on the Mac); Practice only.

### Requests for the integrator
1. **iOS** (plan §7.2): `\.studyCoach` = `CoachEngine(services: services)` on the iPhone (never `start()`ed; nothing else to call). The Mac's wiring is unchanged (`CoachEngine(services:client:)`).
2. **The round on the phone**: `.practice(id)` of a `round` session → a full-screen cover `NavigationStack { PracticeView(sessionID: id) }` (the view sets its own title, subtitle and End); End opens `.today` (a plan block's round), `.courseProgress(id)` or `.study`: dismiss the cover there (and select Today / the course). An `exam` session never starts on the phone (no entry); if one is opened from the Mac's state, show the course's Progress instead.
3. **Parity route `round`**: Today's Start on the parity copy (`CoachEngine(services:)` on the phone) and a shot of the first question after a tap (mockup 16 right: "6 / 12" there; the seed's round starts at 1).

### Design notes (DESIGN 8.7, add "On the iPhone (16)"; 1.2 row 16)
- "Today's plan card (phone): the eyebrow 13, title 26 bold, meta 15, Start the whole width under the thumb (50 pt capsule), 'Then …' centred under it. The round (phone): one question per screen; 'Practice' over '6 / 12' in the bar, End (×) leading; the eyebrow names the course ('CL Lecture 1 · ELIZA'); answer rows of at least 52 pt; after a tap the green check, the professor's sentence with its moment and the explanation; Next under the thumb; no slide. Written answers wait for the Mac's grade (the model answer in grey meanwhile). No practice exams on the phone."
- **decisions rows**: "The phone's coach has no Claude: `CoachEngine(services:)` grades choices and labels in code and leaves written answers pending for the Mac; it never plans (the Mac's plan arrives by sync)." / "Practice exams stay on the Mac (no entry on the phone): a timed exam needs the Mac's grading and a large screen."

## Shared decks (mr, workstream B)

A lecture's slides are its page range of a deck (`LectureSlides`). `CoachRows.spans` (where review
left off → its slide) and a review block's Start (the slide's first visit) read only the timed spans
on the lecture's range (`CoachRows.onSlides`); a lecture without a range keeps all of them. Topics
and the drafter's slide text come from the study pass, which reads only the range.
