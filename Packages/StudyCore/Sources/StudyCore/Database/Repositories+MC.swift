import Foundation
import SQLiteData

// Repositories added with schema v12 (milestone mc: the study coach). The rules (what to plan,
// how a card moves, how an answer is graded) live in Coach; these only read and write rows.
// Screens use `StudySessionRepository` directly for an exam's drafts, flags, position and pause.

// MARK: - The plan

public struct StudyPlanRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// A day's blocks in order.
    public func blocks(on day: CalendarDay) async throws -> [StudyBlock] {
        try await store.database.read { db in
            try StudyBlock.where { $0.day.eq(day) }.order { ($0.sortOrder, $0.createdAt) }.fetchAll(db)
        }
    }

    /// The blocks of `first…last`, by day and order.
    public func blocks(from first: CalendarDay, through last: CalendarDay) async throws -> [StudyBlock] {
        try await store.database.read { db in
            try StudyBlock
                .where { $0.day.gte(first) && $0.day.lte(last) }
                .order { ($0.day, $0.sortOrder, $0.createdAt) }
                .fetchAll(db)
        }
    }

    /// The planner's write, in one transaction: the `planned` blocks of `days` that are not among
    /// `blocks` go, `blocks` are upserted. Started, done and skipped blocks are never deleted.
    public func replacePlanned(days: ClosedRange<CalendarDay>, with blocks: [StudyBlock]) async throws {
        let stamped = blocks.map(store.stamp)
        let keep = Set(stamped.map(\.id))
        let first = days.lowerBound
        let last = days.upperBound
        try await store.database.write { db in
            let planned = try StudyBlock
                .where { $0.day.gte(first) && $0.day.lte(last) && $0.state.eq(StudyBlockState.planned) }
                .fetchAll(db)
            for block in planned where !keep.contains(block.id) {
                try StudyBlock.find(block.id).delete().execute(db)
            }
            for block in stamped {
                try StudyBlock.upsert { block }.execute(db)
            }
        }
    }

    /// Moves a block on: `started` (with the session Start made), `done` (with the seconds it
    /// counts) or `skipped`; stamps `started_at` / `done_at`.
    public func setState(
        _ id: StudyBlock.ID, _ state: StudyBlockState, spentSeconds: Double? = nil, sessionID: StudySession.ID? = nil
    ) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            guard var block = try StudyBlock.find(id).fetchOne(db) else { return }
            block.state = state
            if state == .started, block.startedAt == nil { block.startedAt = stamp }
            if state == .done { block.doneAt = stamp }
            if let spentSeconds { block.spentSeconds = spentSeconds }
            if let sessionID { block.sessionID = sessionID }
            block.updatedAt = stamp
            try StudyBlock.upsert { block }.execute(db)
        }
    }
}

// MARK: - Questions

extension StudyQuestion {
    /// The spaced-repetition card of a question (FSRS-5 state).
    public struct Card: Hashable, Sendable {
        public var state: StudyCardState
        public var dueAt: Date?
        public var stability: Double?
        public var difficulty: Double?
        public var reps: Int
        public var lapses: Int
        public var lastReviewedAt: Date?

        public init(
            state: StudyCardState, dueAt: Date?, stability: Double?, difficulty: Double?, reps: Int, lapses: Int, lastReviewedAt: Date?
        ) {
            self.state = state
            self.dueAt = dueAt
            self.stability = stability
            self.difficulty = difficulty
            self.reps = reps
            self.lapses = lapses
            self.lastReviewedAt = lastReviewedAt
        }
    }

    public var card: Card {
        get { Card(state: cardState, dueAt: dueAt, stability: stability, difficulty: difficulty, reps: reps, lapses: lapses, lastReviewedAt: lastReviewedAt) }
        set {
            cardState = newValue.state
            dueAt = newValue.dueAt
            stability = newValue.stability
            difficulty = newValue.difficulty
            reps = newValue.reps
            lapses = newValue.lapses
            lastReviewedAt = newValue.lastReviewedAt
        }
    }
}

public struct StudyQuestionRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// A course's questions that are not retired (all pools and origins).
    public func questions(course courseID: Course.ID) async throws -> [StudyQuestion] {
        try await store.database.read { db in
            try StudyQuestion.where { $0.courseID.eq(courseID) && $0.retiredAt.is(nil) }.order(by: \.createdAt).fetchAll(db)
        }
    }

    /// A lecture's questions that are not retired.
    public func questions(lecture lectureID: Lecture.ID) async throws -> [StudyQuestion] {
        try await store.database.read { db in
            try StudyQuestion
                .where { $0.lectureID.eq(Lecture.ID?.some(lectureID)) && $0.retiredAt.is(nil) }
                .order(by: \.createdAt)
                .fetchAll(db)
        }
    }

    /// The questions with these ids, in the given order (a session's).
    public func questions(ids: [StudyQuestion.ID]) async throws -> [StudyQuestion] {
        let rows = try await store.database.read { db in
            try StudyQuestion.where { $0.id.in(ids) }.fetchAll(db)
        }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// Answered, not retired questions of `courseIDs` due before `date`, the most overdue first.
    public func due(courses courseIDs: [Course.ID], before date: Date) async throws -> [StudyQuestion] {
        try await store.database.read { db in
            try StudyQuestion
                .where { $0.courseID.in(courseIDs) && $0.retiredAt.is(nil) && $0.dueAt.lt(Date?.some(date)) }
                .order { $0.dueAt.asc() }
                .fetchAll(db)
        }
    }

    /// The old exams a course's questions came from (the sheet's menu), by title.
    public func oldExams(course courseID: Course.ID) async throws -> [String] {
        let titles = try await store.database.read { db in
            try StudyQuestion
                .where { $0.courseID.eq(courseID) && $0.origin.eq(StudyQuestionOrigin.oldExam) && $0.retiredAt.is(nil) }
                .select(\.sourceTitle)
                .fetchAll(db)
        }
        return Array(Set(titles.filter { !$0.isEmpty })).sorted()
    }

    /// Saves drafted or extracted questions (and readings) in one transaction.
    public func insert(_ questions: [StudyQuestion], readings: [StudyReading] = []) async throws {
        let questions = questions.map(store.stamp)
        let readings = readings.map(store.stamp)
        try await store.database.write { db in
            for reading in readings { try StudyReading.upsert { reading }.execute(db) }
            for question in questions { try StudyQuestion.upsert { question }.execute(db) }
        }
    }

    /// The scheduler's write after an answer was graded (column-only).
    public func updateCard(_ id: StudyQuestion.ID, _ card: StudyQuestion.Card) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try StudyQuestion.find(id).update {
                $0.cardState = card.state
                $0.dueAt = card.dueAt
                $0.stability = card.stability
                $0.difficulty = card.difficulty
                $0.reps = card.reps
                $0.lapses = card.lapses
                $0.lastReviewedAt = card.lastReviewedAt
                $0.updatedAt = stamp
            }
            .execute(db)
        }
    }

    /// Points a lecture's questions and readings at its current topic rows (after a study pass
    /// re-run replaced them), by `TopicKey`; a question whose topic no longer exists keeps its
    /// title and loses the link. Returns the questions changed.
    @discardableResult
    public func relink(lectureID: Lecture.ID, topics: [Annotation]) async throws -> Int {
        var keys: [TopicKey: Annotation.ID] = [:]
        for topic in topics {
            if let key = TopicKey(topic: topic), keys[key] == nil { keys[key] = topic.id }
        }
        let byKey = keys
        let stamp = store.currentDate
        return try await store.database.write { db in
            var changed = 0
            let questions = try StudyQuestion.where { $0.lectureID.eq(Lecture.ID?.some(lectureID)) }.fetchAll(db)
            for var question in questions {
                let target = question.topicKey.flatMap { byKey[$0] }
                guard question.topicID != target else { continue }
                question.topicID = target
                question.updatedAt = stamp
                try StudyQuestion.upsert { question }.execute(db)
                changed += 1
            }
            let readings = try StudyReading.where { $0.lectureID.eq(Lecture.ID?.some(lectureID)) }.fetchAll(db)
            for var reading in readings {
                let target = reading.topicKey.flatMap { byKey[$0] }
                guard reading.topicID != target else { continue }
                reading.topicID = target
                reading.updatedAt = stamp
                try StudyReading.upsert { reading }.execute(db)
            }
            return changed
        }
    }

    /// Hides questions (never deleted: their answers stay).
    public func retire(_ ids: [StudyQuestion.ID]) async throws {
        guard !ids.isEmpty else { return }
        let stamp = store.currentDate
        try await store.database.write { db in
            try StudyQuestion.where { $0.id.in(ids) }.update {
                $0.retiredAt = Date?.some(stamp)
                $0.updatedAt = stamp
            }
            .execute(db)
        }
    }
}

// MARK: - Answers

public struct StudyAnswerRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// Appends an answer.
    @discardableResult
    public func record(_ answer: StudyAnswer) async throws -> StudyAnswer {
        try await store.save(answer)
    }

    /// A session's answers, oldest first.
    public func answers(session sessionID: StudySession.ID) async throws -> [StudyAnswer] {
        try await store.database.read { db in
            try StudyAnswer.where { $0.sessionID.eq(StudySession.ID?.some(sessionID)) }.order(by: \.answeredAt).fetchAll(db)
        }
    }

    /// A question's answers, oldest first (its review log).
    public func answers(question questionID: StudyQuestion.ID) async throws -> [StudyAnswer] {
        try await store.database.read { db in
            try StudyAnswer.where { $0.questionID.eq(questionID) }.order(by: \.answeredAt).fetchAll(db)
        }
    }

    /// Every answer given in `range` (studied time).
    public func answers(in range: Range<Date>) async throws -> [StudyAnswer] {
        let start = range.lowerBound
        let end = range.upperBound
        return try await store.database.read { db in
            try StudyAnswer.where { $0.answeredAt.gte(start) && $0.answeredAt.lt(end) }.order(by: \.answeredAt).fetchAll(db)
        }
    }

    /// Written answers waiting for Claude, oldest first.
    public func pendingGrades(limit: Int = 32) async throws -> [StudyAnswer] {
        try await store.database.read { db in
            try StudyAnswer.where { $0.grading.eq(StudyGrading.pending) }.order(by: \.answeredAt).limit(limit).fetchAll(db)
        }
    }

    /// Claude's grade (also kept as `model_score`). `points` for an exam's answer.
    public func setGrade(
        _ id: StudyAnswer.ID, result: StudyAnswerResult, score: Double, points: Double?, note: String, apiCallID: APICall.ID?
    ) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            guard var answer = try StudyAnswer.find(id).fetchOne(db) else { return }
            answer.modelScore = score
            answer.note = note
            answer.grading = .done
            answer.apiCallID = apiCallID
            // An override the student made meanwhile stands.
            if answer.overriddenAt == nil {
                answer.result = result
                answer.score = score
                answer.points = points
                answer.gradedBy = .model
            }
            answer.updatedAt = stamp
            try StudyAnswer.upsert { answer }.execute(db)
        }
    }

    /// A grading call failed: one more attempt; `failed` after `StudyAnswer.maximumGradingAttempts`.
    public func failGrade(_ id: StudyAnswer.ID, error: String) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            guard var answer = try StudyAnswer.find(id).fetchOne(db) else { return }
            answer.gradingAttempts += 1
            answer.gradingError = error
            if answer.gradingAttempts >= StudyAnswer.maximumGradingAttempts { answer.grading = .failed }
            answer.updatedAt = stamp
            try StudyAnswer.upsert { answer }.execute(db)
        }
    }

    /// The student's grade (Count as wrong: 0; Change Points…: points / the question's points);
    /// Claude's stays in `model_score`.
    public func override(_ id: StudyAnswer.ID, score: Double, points: Double?) async throws {
        let stamp = store.currentDate
        let score = min(1, max(0, score))
        try await store.database.write { db in
            guard var answer = try StudyAnswer.find(id).fetchOne(db) else { return }
            answer.score = score
            answer.points = points
            answer.result = score >= 0.999 ? .correct : (score <= 0.001 ? .wrong : .partial)
            answer.gradedBy = .user
            answer.overriddenAt = stamp
            answer.updatedAt = stamp
            try StudyAnswer.upsert { answer }.execute(db)
        }
    }

    /// The FSRS rating the card took from this answer.
    public func setRating(_ id: StudyAnswer.ID, _ rating: Int) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try StudyAnswer.find(id).update {
                $0.rating = Int?.some(rating)
                $0.updatedAt = stamp
            }
            .execute(db)
        }
    }
}

// MARK: - Rounds and practice exams

public struct StudySessionRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    @discardableResult
    public func create(_ session: StudySession) async throws -> StudySession {
        try await store.save(session)
    }

    public func session(_ id: StudySession.ID) async throws -> StudySession? {
        try await store.fetch(StudySession.self, id: id)
    }

    /// Active and paused sessions, newest first (Progress's Resume practice exam).
    public func open(kind: StudySessionKind? = nil) async throws -> [StudySession] {
        let rows = try await store.database.read { db in
            try StudySession
                .where { $0.state.in([StudySessionState.active, StudySessionState.paused]) }
                .order { $0.createdAt.desc() }
                .fetchAll(db)
        }
        return kind.map { kind in rows.filter { $0.kind == kind } } ?? rows
    }

    /// The question on screen (Next question, a number in the exam's bar, ⇧⌘[ / ⇧⌘]).
    public func setPosition(_ id: StudySession.ID, _ position: Int) async throws {
        try await modify(id) { session in
            session.position = max(0, min(position, session.questionIDs.count))
        }
    }

    /// Asks `questionID` again later in a round (successive relearning): appended at the end.
    public func append(_ id: StudySession.ID, question questionID: StudyQuestion.ID) async throws {
        try await modify(id) { $0.questionIDs.append(questionID) }
    }

    /// An exam answer as typed (or picked, or labelled); an empty response removes the draft.
    public func saveDraft(_ id: StudySession.ID, question questionID: StudyQuestion.ID, _ response: StudyResponse) async throws {
        try await modify(id) { session in
            session.drafts.removeAll { $0.questionID == questionID }
            if !response.isEmpty { session.drafts.append(StudyDraft(questionID: questionID, response: response)) }
        }
    }

    /// Flag / unflag a question (⇧⌘L).
    public func toggleFlag(_ id: StudySession.ID, question questionID: StudyQuestion.ID) async throws {
        try await modify(id) { session in
            if session.flags.contains(questionID) {
                session.flags.removeAll { $0 == questionID }
            } else {
                session.flags.append(questionID)
            }
        }
    }

    /// Stops an exam's clock (Pause; leaving the exam).
    public func pause(_ id: StudySession.ID, at date: Date) async throws {
        try await modify(id) { session in
            guard session.state == .active else { return }
            session.activeSeconds = session.elapsed(at: date)
            session.resumedAt = nil
            session.state = .paused
        }
    }

    /// Starts an exam's clock again (Resume; also an exam's first start).
    public func resume(_ id: StudySession.ID, at date: Date) async throws {
        try await modify(id) { session in
            guard session.state.isOpen, session.resumedAt == nil else { return }
            session.resumedAt = date
            session.state = .active
        }
    }

    /// Submitted (an exam) or ended (a round): the clock stops for good.
    public func finish(_ id: StudySession.ID, _ state: StudySessionState, at date: Date) async throws {
        try await modify(id) { session in
            guard session.state.isOpen else { return }
            session.activeSeconds = session.elapsed(at: date)
            session.resumedAt = nil
            session.state = state
            session.endedAt = date
        }
    }

    /// An exam's points once every answer is graded.
    public func setScore(_ id: StudySession.ID, points: Double?) async throws {
        try await modify(id) { $0.scorePoints = points }
    }

    /// Read, change and write one session in one transaction.
    private func modify(_ id: StudySession.ID, _ change: @escaping @Sendable (inout StudySession) -> Void) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            guard var session = try StudySession.find(id).fetchOne(db) else { return }
            change(&session)
            session.updatedAt = stamp
            try StudySession.upsert { session }.execute(db)
        }
    }
}

// MARK: - Reading list

public struct StudyReadingRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// A course's readings that are not hidden, in list order.
    public func readings(course courseID: Course.ID) async throws -> [StudyReading] {
        try await store.database.read { db in
            try StudyReading
                .where { $0.courseID.eq(courseID) && $0.hiddenAt.is(nil) }
                .order { ($0.sortOrder, $0.createdAt) }
                .fetchAll(db)
        }
    }

    public func save(_ readings: [StudyReading]) async throws {
        try await store.save(readings)
    }

    /// Read (its recall questions answered, or the student said so).
    public func markDone(_ id: StudyReading.ID, at date: Date) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try StudyReading.find(id).update {
                $0.doneAt = Date?.some(date)
                $0.updatedAt = stamp
            }
            .execute(db)
        }
    }
}

// MARK: - Course facts

extension CourseRepository {
    /// A course's credits and self-study hours (the change log's `course_credits`; nil clears).
    public func setCredits(_ courseID: Course.ID, credits: Double?, selfStudyHours: Double?) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try Course.find(courseID).update {
                $0.credits = credits
                $0.selfStudyHours = selfStudyHours
                $0.updatedAt = stamp
            }
            .execute(db)
        }
    }
}
