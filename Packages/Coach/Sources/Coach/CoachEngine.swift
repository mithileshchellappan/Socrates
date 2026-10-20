import ClaudeKit
import CryptoKit
import Deadlines
import Foundation
import GRDB
import StudyCore

/// The study coach's engine (plan §4–5.1): implements `StudyCoaching` for the screens, keeps the
/// plan (`study_block`) written from today to two weeks ahead, grades written answers in the
/// background and queues the drafting of new lectures' questions.
///
/// - Follows the rows it plans from (`DatabaseRegionObservation`: courses, lectures, sessions,
///   items, plan memories, questions, answers, readings, study units) and replans debounced (2 s,
///   then at most once every 15 s while rows keep changing: a review's saved position), on a new
///   day (local midnight) and after answers, ended rounds and submitted exams (its own writes).
///   Rounds and exams are not followed: the screens write only drafts, flags, position and pause.
/// - Nothing here waits for a model: choices and labels are graded in code at once; a written
///   answer is `pending` until `AnswerGrader` (Opus, background) grades it; drafting runs as a
///   `question_draft` task of AppAgent's queue (`drafter`), an old exam as a `practice_exam` task
///   (`oldExams`).
///
/// Wiring (the integrator): `let coach = CoachEngine(services:client:)`, hand it to
/// `AppAgent.specs(…, coach:)` and `AppAgent(…, coach:)`, install it in `\.studyCoach`, then
/// `await coach.start()` in `startBackgroundWork`, `await coach.wake()` when study pass units
/// finish or Claude Code turns available, `await coach.stop()` at `willTerminate`.
///
/// M7, the iPhone: `CoachEngine(services:)` has no Claude client. Rounds and Start work (choices
/// and labels graded in code, the cards as on the Mac); a written answer stays `pending` for the
/// Mac's grader (it arrives there through sync); it never plans (`start()` does nothing: the
/// Mac's plan comes down), drafts or grades.
public actor CoachEngine: StudyCoaching {
    let services: StudyServices
    /// Nil on the iPhone: no drafting, old exams, grading or planning there.
    let client: ClaudeClient?
    let now: @Sendable () -> Date
    /// Drafts a lecture's questions (the queue's `question_draft` runner); nil without Claude.
    public nonisolated let drafter: QuestionDrafter?
    /// Reads an old exam (the queue's `practice_exam` runner for an old exam); nil without Claude.
    public nonisolated let oldExams: OldExamReader?
    let grader: AnswerGrader?

    private var started = false
    private var observation: AnyDatabaseCancellable?
    private var follower: Task<Void, Never>?
    private var nudges: AsyncStream<Void>.Continuation?
    private var dayTimer: Task<Void, Never>?
    private var planTask: Task<Void, Never>?
    private var planAgain = false
    private var gradeTask: Task<Void, Never>?
    private var gradeAgain = false
    private var gradeWake: Task<Void, Never>?
    /// A replan when a started block without a session runs out (`PlanEngine.runsOut`).
    private var runOutWake: Task<Void, Never>?
    private var runOutAt: Date?

    /// A question comes back at most this often in one round (successive relearning).
    static let maximumRepeats = 3
    static let debounce: Duration = .seconds(2)
    static let throttle: Duration = .seconds(15)

    /// The Mac's coach (`client`: Claude Code); nil: as `init(services:)`.
    public init(services: StudyServices, client: ClaudeClient?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.services = services
        self.client = client
        self.now = now
        drafter = client.map { QuestionDrafter(services: services, client: $0, now: now) }
        oldExams = client.map { OldExamReader(services: services, client: $0, now: now) }
        grader = client.map { AnswerGrader(services: services, client: $0) }
    }

    /// M7, the iPhone's coach: no Claude. Rounds and `start(block:)` work, choices and labels are
    /// graded in code, written answers stay `pending` for the Mac; no plan loop, no drafting, no
    /// grading (`start()` does nothing).
    public init(services: StudyServices, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(services: services, client: nil, now: now)
    }

    var store: RecordStore { services.records }
    var plans: StudyPlanRepository { StudyPlanRepository(store: store) }
    var bank: StudyQuestionRepository { StudyQuestionRepository(store: store) }
    var answers: StudyAnswerRepository { StudyAnswerRepository(store: store) }
    var sessions: StudySessionRepository { StudySessionRepository(store: store) }

    // MARK: - Lifecycle

    /// Follows the rows, replans now and grades what waits (a quit or a usage pause left). Without
    /// Claude (the iPhone) nothing: the phone never plans.
    public func start() async {
        guard !started, client != nil else { return }
        started = true
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let tracked: [any DatabaseRegionConvertible] = [
            SQLRequest<Row>(sql: "SELECT id, credits, self_study_hours, rules FROM course"),
            // Not `review_position`: Review saves it every 10 s while playing (no replan for that).
            SQLRequest<Row>(sql: "SELECT id, held_at, reviewed_at FROM lecture"),
            SQLRequest<Row>(sql: "SELECT id, starts_at, ends_at, is_cancelled FROM lecture_session"),
            SQLRequest<Row>(sql: "SELECT id, status, due_at, relevance, kind FROM tracked_item"),
            SQLRequest<Row>(sql: "SELECT id, plan_rule, forgotten_at FROM agent_memory"),
            SQLRequest<Row>(sql: "SELECT id, due_at, retired_at FROM study_question"),
            SQLRequest<Row>(sql: "SELECT id, result FROM study_answer"),
            SQLRequest<Row>(sql: "SELECT id, done_at, hidden_at FROM study_reading"),
            SQLRequest<Row>(sql: "SELECT id, state FROM study_unit"),
        ]
        observation = DatabaseRegionObservation(tracking: tracked).start(
            in: services.database,
            onError: { error in CoachModule.log.error("Coach observation failed: \(String(describing: error), privacy: .public)") },
            onChange: { _ in continuation.yield() }
        )
        nudges = continuation
        follower = Task { [weak self] in
            for await _ in stream {
                do { try await Task.sleep(for: Self.debounce) } catch { return }
                await self?.replan()
                // Changes meanwhile wait (coalesced to one replan after).
                do { try await Task.sleep(for: Self.throttle) } catch { return }
            }
        }
        scheduleNewDay()
        Task { await self.replan() }
        grade()
    }

    /// Looks for work again: a replan (new lectures to draft, finished units) and grading of
    /// pending answers (after a usage pause, or when Claude Code turned available).
    public func wake() async {
        guard started else { return }
        grade()
        await replan()
    }

    /// The app quits: nothing half-written (rows stay `pending`, picked up at the next launch).
    public func stop() async {
        started = false
        observation?.cancel()
        observation = nil
        nudges?.finish()
        nudges = nil
        follower?.cancel()
        follower = nil
        dayTimer?.cancel()
        dayTimer = nil
        gradeWake?.cancel()
        gradeWake = nil
        runOutWake?.cancel()
        runOutWake = nil
        runOutAt = nil
        gradeTask?.cancel()
        planTask?.cancel()
    }

    /// A replan soon (debounced): after the engine's own writes (answers, an ended round, an exam).
    func replanSoon() {
        nudges?.yield()
    }

    /// Replans now (the agent's plan tools wait for it); a replan running already runs once more.
    public func replan() async {
        if let task = planTask {
            planAgain = true
            await task.value
            return
        }
        let task = Task { await self.runReplans() }
        planTask = task
        await task.value
    }

    private func runReplans() async {
        repeat {
            planAgain = false
            do {
                try await performReplan()
            } catch {
                CoachModule.log.error("Replan failed: \(String(describing: error), privacy: .public)")
            }
        } while planAgain && !Task.isCancelled
        planTask = nil
    }

    private func scheduleNewDay() {
        dayTimer?.cancel()
        let zone = CoachModule.timeZone
        let date = now()
        let tomorrow = CalendarDay(date, in: zone).adding(days: 1).start(in: zone)
        let delay = max(60, tomorrow.timeIntervalSince(date) + 30)
        dayTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.newDay()
        }
    }

    private func newDay() async {
        guard started else { return }
        await replan()
        scheduleNewDay()
    }

    /// Replans when the first started block without a session runs out (it is done then, and the
    /// hero moves on); an earlier time replaces a later one.
    private func scheduleRunOut(at date: Date) {
        guard started else { return }
        if runOutWake != nil, let at = runOutAt, at <= date { return }
        runOutWake?.cancel()
        runOutAt = date
        let delay = max(5, date.timeIntervalSince(now()) + 5)
        runOutWake = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.runOutEnded()
        }
    }

    private func runOutEnded() async {
        runOutWake = nil
        runOutAt = nil
        guard started else { return }
        await replan()
    }

    // MARK: - The plan

    func performReplan() async throws {
        let date = now()
        let rows = try await services.database.read { db in try CoachRows.load(db, now: date) }
        let output = PlanEngine.plan(rows)
        for settled in output.settled {
            try await plans.setState(settled.id, settled.state, spentSeconds: settled.spentSeconds)
        }
        let readings = StudyReadingRepository(store: store)
        for id in output.readingsDone { try await readings.markDone(id, at: date) }
        // One-off rules that ended are forgotten (the memory stays under its limit).
        let memories = AgentMemoryRepository(store: store)
        for id in output.expiredRules { try await memories.forget(id) }
        let standing = rows.blocks.filter { output.days.contains($0.day) && $0.state == .planned }
        if !Self.same(standing, output.blocks) {
            try await plans.replacePlanned(days: output.days, with: output.blocks)
        }
        try await queueDrafting(rows)
        if let next = rows.blocks.compactMap(PlanEngine.runsOut).filter({ $0 > date }).min() { scheduleRunOut(at: next) }
    }

    /// The same blocks (`updated_at` aside): nothing to write.
    static func same(_ lhs: [StudyBlock], _ rhs: [StudyBlock]) -> Bool {
        func normalized(_ blocks: [StudyBlock]) -> Set<StudyBlock> {
            Set(blocks.map { block in
                var block = block
                block.updatedAt = .distantPast
                return block
            })
        }
        return lhs.count == rhs.count && normalized(lhs) == normalized(rhs)
    }

    /// Queues a `question_draft` task for every lecture whose study pass wrote topics that have no
    /// questions yet: once per topic set (the task's input names it), after the pass's reads and
    /// synthesis are done.
    func queueDrafting(_ rows: CoachRows) async throws {
        let stages = [StudyStage.read, StudyStage.synthesize]
        let draft = AgentTaskKind.questionDraft
        let (units, tasks) = try await services.database.read { db in
            (
                try StudyUnit.where { $0.stage.in(stages) }.fetchAll(db),
                try AgentTask.where { $0.kind.eq(draft) }.fetchAll(db)
            )
        }
        let unitsByLecture = Dictionary(grouping: units, by: \.lectureID)
        let drafted = Set(rows.questions.filter { $0.origin == .generated && $0.readingID == nil }.compactMap(\.topicKey))
        let repository = AgentTaskRepository(store: store)
        // Only the semester's courses (never an old course's lectures).
        let courses = Set(rows.courses.map(\.id))
        for lecture in rows.lectures where courses.contains(lecture.courseID) {
            let topics = rows.topics(of: lecture.id)
            guard !topics.isEmpty else { continue }
            let own = unitsByLecture[lecture.id] ?? []
            guard own.contains(where: { $0.stage == .synthesize && $0.state == .done }), !own.contains(where: { $0.state == .pending }) else { continue }
            let keys = topics.compactMap { TopicKey(topic: $0) }
            guard keys.contains(where: { !drafted.contains($0) }) else { continue }
            let fingerprint = Self.fingerprint(keys)
            guard !tasks.contains(where: { $0.lectureID == lecture.id && $0.inputSummary == fingerprint }) else { continue }
            let name = "\(rows.shortName(lecture.courseID)) L\(lecture.number.map(String.init) ?? "?")"
            let date = now()
            _ = try await repository.enqueue(AgentTask(
                kind: .questionDraft, title: String("Questions: \(name)".prefix(AgentTask.titleLimit)),
                goal: "Draft practice questions and readings for \(name) from its study pass.", inputSummary: fingerprint,
                model: QuestionDrafter.model.rawValue, effort: QuestionDrafter.effort.rawValue, tools: [], courseID: lecture.courseID,
                lectureID: lecture.id, createdBy: .agent, createdAt: date, updatedAt: date
            ))
        }
    }

    /// "topics:" + 12 hex of the SHA-256 of the folded topic titles (sorted).
    static func fingerprint(_ keys: [TopicKey]) -> String {
        let text = keys.map(\.folded).sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return "topics:" + digest.prefix(12)
    }

    // MARK: - Cards

    /// The FSRS bounds of a course's cards: the exam it sits, the runway, the away days.
    static func limits(for courseID: Course.ID, db: Database, now: Date) throws -> Scheduler.Limits {
        let memories = try AgentMemory.where { $0.forgottenAt.is(nil) && $0.kind.eq(AgentMemoryKind.plan) }.fetchAll(db)
        let rules = PlanRules(memories: memories)
        guard let course = try Course.find(courseID).fetchOne(db) else { return Scheduler.Limits(examDay: nil, runwayStart: nil, rules: rules) }
        let exam = TrackedItemKind.exam
        let items = try TrackedItem.where { $0.courseID.eq(Course.ID?.some(courseID)) && $0.kind.eq(exam) }.fetchAll(db)
        let exams = CourseExams.resolve(courseID: courseID, items: items, rules: rules)
        let seminar = course.rules.contains { $0.kind == .examForm && $0.examForm == .seminar }
        let examDay = seminar ? nil : exams.sat?.dueAt.map { CalendarDay($0, in: CoachModule.timeZone) }
        let semester = CoachRows.pickSemester(try Semester.all.fetchAll(db), on: now)
        let budget = StudyBudget.make(course: course, semester: semester, sessions: [], examDay: examDay)
        return Scheduler.Limits(examDay: examDay, runwayStart: budget.runwayStart, rules: rules)
    }

    /// The question's card from its whole answer log (an override or a late grade gives the card
    /// it would have had); the ratings are stamped on the answers.
    func recard(_ questionID: StudyQuestion.ID) async throws {
        guard let question = try await store.fetch(StudyQuestion.self, id: questionID) else { return }
        let courseID = question.courseID
        let date = now()
        let (log, limits) = try await services.database.read { db in
            (
                try StudyAnswer.where { $0.questionID.eq(questionID) }.order(by: \.answeredAt).fetchAll(db),
                try Self.limits(for: courseID, db: db, now: date)
            )
        }
        try await bank.updateCard(questionID, Scheduler.card(after: log, limits: limits))
        for answer in log {
            guard let rating = Scheduler.rating(of: answer), answer.rating != rating else { continue }
            try await answers.setRating(answer.id, rating)
        }
    }

    /// An exam's points once no answer waits for Claude.
    func rescore(_ sessionID: StudySession.ID) async throws {
        let list = try await answers.answers(session: sessionID)
        guard !list.contains(where: { $0.grading == .pending }) else { return }
        try await sessions.setScore(sessionID, points: list.reduce(0) { $0 + ($1.points ?? 0) })
    }

    // MARK: - Grading

    /// Grades pending written answers in the background (one run at a time). Without Claude (the
    /// iPhone) they stay `pending` for the Mac.
    func grade() {
        guard started, grader != nil else { return }
        if gradeTask != nil {
            gradeAgain = true
            return
        }
        gradeTask = Task { await self.runGrading() }
    }

    private func runGrading() async {
        guard let grader else {
            gradeTask = nil
            return
        }
        repeat {
            gradeAgain = false
            let report = await grader.run()
            await applyGrades(report.graded)
            if report.waiting {
                if let until = report.until { scheduleGradeWake(at: until) }
                break
            }
            if report.graded.isEmpty && !gradeAgain { break }
        } while !Task.isCancelled && started
        gradeTask = nil
    }

    private func applyGrades(_ graded: [StudyAnswer]) async {
        do {
            for questionID in Set(graded.map(\.questionID)) { try await recard(questionID) }
            for sessionID in Set(graded.compactMap(\.sessionID)) { try await rescore(sessionID) }
        } catch {
            CoachModule.log.error("Applying grades failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func scheduleGradeWake(at date: Date) {
        guard gradeWake == nil else { return }
        let delay = max(5, date.timeIntervalSince(now()) + 5)
        gradeWake = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.gradeWakeEnded()
        }
    }

    private func gradeWakeEnded() {
        gradeWake = nil
        grade()
    }

    // MARK: - StudyCoaching: the plan

    public func start(block id: StudyBlock.ID) async throws -> StudyStart {
        guard let block = try await store.fetch(StudyBlock.self, id: id) else { throw CoachError.missing("The block") }
        switch block.kind {
        case .round:
            if let sessionID = block.sessionID, let session = try await sessions.session(sessionID), session.state.isOpen {
                return .session(sessionID)
            }
            let scope = StudyScope(kind: .plan, courseIDs: block.courses)
            let size: RoundBuilder.Size = block.questionCount.map { .questions($0) } ?? .minutes(block.minutes)
            let sessionID = try await createRound(scope, size: size, blockID: block.id)
            try await plans.setState(block.id, .started, sessionID: sessionID)
            return .session(sessionID)
        case .review:
            try await plans.setState(block.id, .started)
            guard let lectureID = block.lectureID else { return .none }
            let page = block.firstPage
            let time = try await services.database.read { db -> Double? in
                guard let page else { return nil }
                let timed = try LectureDeckSpan
                    .where { $0.lectureID.eq(lectureID) && $0.startTime.isNot(nil) && $0.firstPage.isNot(nil) }
                    .fetchAll(db)
                // mr: only visits on the lecture's slides (its range).
                let spans = try CoachRows.onSlides(timed, in: db)
                    .filter { ($0.firstPage ?? 0) <= page && page <= ($0.lastPage ?? $0.firstPage ?? 0) }
                return spans.compactMap(\.startTime).min()
            }
            return .lecture(lectureID, page: page, time: time)
        case .exercise, .seminarStep:
            try await plans.setState(block.id, .started)
            scheduleRunOut(at: (block.startedAt ?? now()).addingTimeInterval(Double(block.minutes * 60)))
            if let url = block.url { return .url(url) }
            if let item = block.trackedItemID { return .item(item) }
            return .none
        case .read:
            try await plans.setState(block.id, .started)
            // Opened by its link (no recall round): done once its minutes are up, and its recall
            // questions join the next rounds.
            scheduleRunOut(at: (block.startedAt ?? now()).addingTimeInterval(Double(block.minutes * 60)))
            guard let readingID = block.readingID, let reading = try await store.fetch(StudyReading.self, id: readingID) else { return .none }
            if let url = reading.url ?? block.url { return .url(url) }
            // No link: the reading's recall questions.
            if let sessionID = try? await createRound(StudyScope(kind: .reading, courseIDs: [reading.courseID], readingID: readingID), size: .questions(3), blockID: block.id) {
                try await plans.setState(block.id, .started, sessionID: sessionID)
                return .session(sessionID)
            }
            return .none
        case .practiceExam:
            try await plans.setState(block.id, .started)
            return block.courseID.map { .examSheet($0) } ?? .none
        default:
            try await plans.setState(block.id, .started)
            return .none
        }
    }

    // MARK: - StudyCoaching: rounds

    public func previewRound(_ scope: StudyScope) async throws -> StudyRoundPreview {
        let (questions, _) = try await roundQuestions(scope, size: .minutes(RoundBuilder.defaultMinutes))
        return StudyRoundPreview(questions: questions.count, minutes: RoundBuilder.minutes(for: questions))
    }

    public func startRound(_ scope: StudyScope) async throws -> StudySession.ID {
        try await createRound(scope, size: .minutes(RoundBuilder.defaultMinutes), blockID: nil)
    }

    /// The questions of a round of `scope` and its courses.
    func roundQuestions(_ scope: StudyScope, size: RoundBuilder.Size) async throws -> ([StudyQuestion], [Course]) {
        let date = now()
        let (rows, misses, courseIDs) = try await services.database.read { db -> (CoachRows, [StudyQuestion.ID], [Course.ID]) in
            let rows = try CoachRows.load(db, now: date)
            var courses = scope.courseIDs
            var misses: [StudyQuestion.ID] = []
            switch scope.kind {
            case .misses:
                if let sessionID = scope.sessionID {
                    let list = try StudyAnswer.where { $0.sessionID.eq(StudySession.ID?.some(sessionID)) }.fetchAll(db)
                    misses = list.filter { $0.result == .wrong || $0.result == .partial }.map(\.questionID)
                    if courses.isEmpty, let course = try StudySession.find(sessionID).fetchOne(db)?.courseID { courses = [course] }
                }
            case .topic:
                if courses.isEmpty, let lectureID = scope.topic?.lectureID, let lecture = rows.lectures.first(where: { $0.id == lectureID }) {
                    courses = [lecture.courseID]
                }
            case .reading:
                if courses.isEmpty, let readingID = scope.readingID, let reading = try StudyReading.find(readingID).fetchOne(db) {
                    courses = [reading.courseID]
                }
            default:
                break
            }
            if courses.isEmpty { courses = rows.courses.map(\.id) }
            return (rows, misses, courses)
        }
        let wanted = Set(courseIDs)
        let questions = rows.questions.filter { wanted.contains($0.courseID) }
        let runway = rows.statuses.contains { wanted.contains($0.course.id) && $0.budget.isRunway(rows.today) }
        let picked = RoundBuilder.build(
            scope: scope, size: size, questions: questions, lectures: rows.lectures, misses: misses, runway: runway, now: date,
            readings: PlanEngine.readReadings(rows)
        )
        return (picked, rows.courses.filter { wanted.contains($0.id) })
    }

    func createRound(_ scope: StudyScope, size: RoundBuilder.Size, blockID: StudyBlock.ID?) async throws -> StudySession.ID {
        let (questions, courses) = try await roundQuestions(scope, size: size)
        guard !questions.isEmpty else { throw CoachError.nothingToAsk }
        let involved = courses.filter { course in questions.contains { $0.courseID == course.id } }
        let date = now()
        let session = StudySession(
            kind: .round, courseID: involved.count == 1 ? involved.first?.id : nil, blockID: blockID, title: Self.title(involved),
            scope: scope, questionIDs: questions.map(\.id), state: .active, startedAt: date, resumedAt: date, createdAt: date, updatedAt: date
        )
        return try await sessions.create(session).id
    }

    /// "Data Centers", "Data Centers · CL".
    static func title(_ courses: [Course]) -> String {
        guard let first = courses.first else { return "" }
        let rest = courses.dropFirst().map { $0.shortName.isEmpty ? $0.name : $0.shortName }
        return ([first.name] + rest).joined(separator: " · ")
    }

    @discardableResult
    public func answer(_ response: StudyResponse, to questionID: StudyQuestion.ID, in sessionID: StudySession.ID, seconds: Double) async throws -> StudyAnswer {
        guard let session = try await sessions.session(sessionID), session.state.isOpen else { throw CoachError.notOpen }
        guard let question = try await store.fetch(StudyQuestion.self, id: questionID) else { throw CoachError.missing("The question") }
        let date = now()
        if session.kind == .exam {
            // An exam's answers are drafts until Submit.
            try await sessions.saveDraft(sessionID, question: questionID, response)
            return StudyAnswer(questionID: questionID, sessionID: sessionID, courseID: question.courseID, response: response, result: .pending, answeredAt: date)
        }
        let graded = CodeGrading.grade(response, for: question)
        let row = try await answers.record(StudyAnswer(
            questionID: questionID, sessionID: sessionID, courseID: question.courseID, response: response, result: graded?.result ?? .pending,
            score: graded?.score, gradedBy: graded == nil ? .model : .code, grading: graded == nil ? .pending : .none, seconds: max(0, seconds),
            answeredAt: date, createdAt: date, updatedAt: date
        ))
        if let graded {
            try await recard(questionID)
            // Successive relearning: a miss of a new or learning question comes back later in the
            // round (at most a few times).
            let learning = question.cardState == .new || question.cardState == .learning || question.cardState == .relearning
            if graded.result != .correct, learning || graded.result == .wrong,
               session.questionIDs.filter({ $0 == questionID }).count < Self.maximumRepeats {
                try await sessions.append(sessionID, question: questionID)
            }
        } else {
            grade()
        }
        replanSoon()
        return row
    }

    public func override(_ answerID: StudyAnswer.ID, score: Double) async throws {
        guard let answer = try await store.fetch(StudyAnswer.self, id: answerID) else { throw CoachError.missing("The answer") }
        guard let question = try await store.fetch(StudyQuestion.self, id: answer.questionID) else { throw CoachError.missing("The question") }
        var session: StudySession?
        if let id = answer.sessionID { session = try await sessions.session(id) }
        let exam = session?.kind == .exam
        let clamped = min(1, max(0, score))
        let points = exam ? clamped * Double(PracticeExamBuilder.points(of: question)) : nil
        try await answers.override(answerID, score: clamped, points: points)
        try await recard(question.id)
        if exam, let id = session?.id { try await rescore(id) }
    }

    public func end(_ sessionID: StudySession.ID) async throws {
        guard let session = try await sessions.session(sessionID) else { throw CoachError.missing("The round") }
        let date = now()
        try await sessions.finish(sessionID, .ended, at: date)
        try await finishBlock(of: session, at: date)
        replanSoon()
    }

    /// The plan block a round or exam was started from is done (its session's time counts).
    func finishBlock(of session: StudySession, at date: Date) async throws {
        let sessionID = Optional(session.id)
        let block = try await services.database.read { db in
            try StudyBlock.where { $0.sessionID.eq(sessionID) }.fetchOne(db)
        }
        guard let id = session.blockID ?? block?.id else { return }
        try await plans.setState(id, .done, spentSeconds: session.elapsed(at: date), sessionID: session.id)
    }

    // MARK: - StudyCoaching: practice exams

    public func previewExam(course: Course.ID, source: StudyScope, minutes: Int?) async throws -> StudyExamPreview {
        let exam = try await assemble(course: course, source: source, minutes: minutes, exclude: [])
        return StudyExamPreview(questions: exam.questions.count, points: exam.points, minutes: exam.minutes)
    }

    public func startExam(course: Course.ID, source: StudyScope, minutes: Int?) async throws -> StudySession.ID {
        try await startExam(course: course, source: source, minutes: minutes, exclude: [], retakeOf: nil)
    }

    func assemble(course courseID: Course.ID, source: StudyScope, minutes: Int?, exclude: Set<StudyQuestion.ID>) async throws -> PracticeExamBuilder.Exam {
        let date = now()
        let rows = try await services.database.read { db in try CoachRows.load(db, now: date) }
        guard let course = rows.courses.first(where: { $0.id == courseID }) else { throw CoachError.missing("The course") }
        let status = rows.status(course)
        return PracticeExamBuilder.build(
            source: source, minutes: minutes, questions: rows.questions.filter { $0.courseID == courseID }, taught: status.taught,
            defaultMinutes: status.examMinutes, exclude: exclude, now: date
        )
    }

    func startExam(
        course courseID: Course.ID, source: StudyScope, minutes: Int?, exclude: Set<StudyQuestion.ID>, retakeOf: StudySession.ID?
    ) async throws -> StudySession.ID {
        let exam = try await assemble(course: courseID, source: source, minutes: minutes, exclude: exclude)
        guard !exam.questions.isEmpty else { throw CoachError.nothingToAsk }
        guard let course = try await store.fetch(Course.self, id: courseID) else { throw CoachError.missing("The course") }
        let date = now()
        let zone = CoachModule.timeZone
        let today = CalendarDay(date, in: zone)
        let kind = StudyBlockKind.practiceExam
        let course2 = Course.ID?.some(courseID)
        // Today's practice exam block of the course, when there is one.
        let block = try await services.database.read { db in
            try StudyBlock.where { $0.day.eq(today) && $0.kind.eq(kind) && $0.courseID.eq(course2) }.fetchAll(db).first { $0.state.isOpen }
        }
        var scope = source
        if scope.courseIDs.isEmpty { scope.courseIDs = [courseID] }
        let session = try await sessions.create(StudySession(
            kind: .exam, courseID: courseID, blockID: block?.id, title: course.name, scope: scope, questionIDs: exam.questions.map(\.id),
            minutes: exam.minutes, points: exam.points, state: .active, startedAt: date, resumedAt: date, retakeOf: retakeOf,
            createdAt: date, updatedAt: date
        ))
        if let block { try await plans.setState(block.id, .started, sessionID: session.id) }
        return session.id
    }

    public func submitExam(_ sessionID: StudySession.ID) async throws {
        guard let session = try await sessions.session(sessionID), session.kind == .exam else { throw CoachError.missing("The exam") }
        guard session.state.isOpen else { return }
        let date = now()
        try await sessions.finish(sessionID, .submitted, at: date)
        // Handed in once (a second Submit, or the clock at 0:00 meanwhile, writes nothing).
        guard try await answers.answers(session: sessionID).isEmpty else { return }
        let questions = try await bank.questions(ids: session.questionIDs)
        let elapsed = session.elapsed(at: date)
        let each = questions.isEmpty ? 0 : elapsed / Double(questions.count)
        var codeGraded: [StudyQuestion.ID] = []
        var waits = false
        for question in questions {
            let response = session.draft(for: question.id) ?? .text("")
            let graded = CodeGrading.grade(response, for: question)
            let total = Double(PracticeExamBuilder.points(of: question))
            try await answers.record(StudyAnswer(
                questionID: question.id, sessionID: sessionID, courseID: question.courseID, response: response,
                result: graded?.result ?? .pending, score: graded?.score, points: graded.map { $0.score * total },
                gradedBy: graded == nil ? .model : .code, grading: graded == nil ? .pending : .none, seconds: each,
                answeredAt: date, createdAt: date, updatedAt: date
            ))
            if graded == nil { waits = true } else { codeGraded.append(question.id) }
        }
        for id in codeGraded { try await recard(id) }
        try await rescore(sessionID)
        try await finishBlock(of: session, at: date)
        if waits { grade() }
        replanSoon()
    }

    public func retake(_ sessionID: StudySession.ID) async throws -> StudySession.ID {
        guard let old = try await sessions.session(sessionID), old.kind == .exam, let courseID = old.courseID else {
            throw CoachError.missing("The exam")
        }
        return try await startExam(course: courseID, source: old.scope, minutes: old.minutes, exclude: Set(old.questionIDs), retakeOf: old.id)
    }

    public func addOldExam(course courseID: Course.ID, file: URL) async throws {
        guard try await store.fetch(Course.self, id: courseID) != nil else { throw CoachError.missing("The course") }
        let blob = try services.blobs.importFile(at: file)
        let sha = Optional(blob.sha256)
        let kind = AgentTaskKind.practiceExam
        let (known, tasks) = try await services.database.read { db in
            (
                try StudyQuestion.where { $0.sourceBlobSHA256.eq(sha) && $0.courseID.eq(courseID) }.fetchCount(db),
                try AgentTask.where { $0.kind.eq(kind) }.fetchAll(db)
            )
        }
        // A PDF is read once.
        guard known == 0 else { return }
        if tasks.contains(where: { OldExamReader.input(of: $0)?.blobSHA256 == blob.sha256 && $0.courseID == courseID && $0.state != .failed && $0.state != .cancelled }) {
            return
        }
        let title = file.deletingPathExtension().lastPathComponent
        let date = now()
        let input = OldExamReader.Input(courseID: courseID, title: String(title.prefix(60)), blob: blob, fileName: file.lastPathComponent)
        _ = try await AgentTaskRepository(store: store).enqueue(AgentTask(
            kind: .practiceExam, title: String("Old exam: \(title)".prefix(AgentTask.titleLimit)),
            goal: "Read the old exam's questions and write model answers from the course's lectures.", inputSummary: input.json,
            model: OldExamReader.model.rawValue, effort: OldExamReader.effort.rawValue, tools: [], courseID: courseID, createdBy: .user,
            createdAt: date, updatedAt: date
        ))
    }
}
