import Foundation

// The study coach's measures (docs/plan-coach.md §3–4): one implementation the plan engine, the
// agent's tools and every screen (Today, Study, Progress, Practice) use, so they never disagree.
// Pure functions over rows; no database, no model.

// MARK: - Universal rules

/// The universal core's constants (research §6). University facts live in `UniversityProfile`.
public enum CoachRules {
    /// The share of a course's self-study planned over the term; the rest goes to the exam runway.
    public static let termShare = 2.0 / 3.0
    /// The runway: this many weeks before the week of the exam the student sits.
    public static let runwayWeeks = 5
    /// FSRS desired retention: a card is due when recall would fall to this.
    public static let desiredRetention = 0.9
    /// Mastery dots at or above this count as known solidly (Ready).
    public static let solidLevel = 3
    /// The highest mastery level (four dots).
    public static let maximumLevel = 4
    /// A round asks about this many questions a minute (a written one counts `writtenWeight`).
    public static let questionsPerMinute = 1.2
    public static let writtenWeight = 3
    /// At most this many written (Claude-graded) questions per round.
    public static let writtenPerRound = 2
    /// The plan is written for today and this many days after it.
    public static let planDays = 14
    /// The study day the planner fills, minutes after midnight (the university's time zone).
    public static let dayStartMinute = 8 * 60
    public static let dayEndMinute = 20 * 60
    /// No new Read block this many days before the exam.
    public static let noReadDays = 3
    /// Study's Weakest topics list at most this many.
    public static let weakestLimit = 6
}

// MARK: - Recall (FSRS-5)

/// FSRS-5 retrievability: R(t, S) = (1 + F·t/S)^D with D = −0.5 and F = 19/81, so R(S, S) = 0.9.
public enum Recall {
    public static let decay = -0.5
    public static let factor = 19.0 / 81.0

    /// Recall probability `elapsedDays` after a review of a card with `stability` days.
    public static func retrievability(stability: Double, elapsedDays: Double) -> Double {
        guard stability > 0 else { return 0 }
        return pow(1 + factor * max(0, elapsedDays) / stability, decay)
    }

    /// The days after a review at which recall falls to `retention` (the interval).
    public static func interval(stability: Double, retention: Double = CoachRules.desiredRetention) -> Double {
        stability / factor * (pow(retention, 1 / decay) - 1)
    }

    /// A question's recall now (nil: never answered).
    public static func retrievability(of question: StudyQuestion, at now: Date) -> Double? {
        guard question.reps > 0, let stability = question.stability, let last = question.lastReviewedAt else { return nil }
        return retrievability(stability: stability, elapsedDays: now.timeIntervalSince(last) / 86_400)
    }
}

// MARK: - Topics and mastery

/// A topic as the coach counts it: its lecture and its title, compared folded (case, diacritics,
/// spacing), so questions drafted before a study pass re-run still count for the same topic.
public struct TopicKey: Hashable, Sendable, Codable {
    public var lectureID: Lecture.ID
    public var title: String

    public init(lectureID: Lecture.ID, title: String) {
        self.lectureID = lectureID
        self.title = title
    }

    /// An M4 topic row (`annotation` ai · topic).
    public init?(topic annotation: Annotation) {
        guard annotation.kind == .topic, let lectureID = annotation.lectureID else { return nil }
        self.init(lectureID: lectureID, title: annotation.body)
    }

    public var folded: String { Self.fold(title) }

    public static func == (lhs: TopicKey, rhs: TopicKey) -> Bool {
        lhs.lectureID == rhs.lectureID && lhs.folded == rhs.folded
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(lectureID)
        hasher.combine(folded)
    }

    /// Lowercased, without diacritics, single spaces, no trailing punctuation.
    public static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let words = folded.split(whereSeparator: { $0.isWhitespace })
        return words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
    }
}

/// How well a topic is known: 0…4 dots (mockups 13–15: "Mastery 2 of 4 · again Fri 23 Oct").
public struct TopicMastery: Hashable, Sendable {
    /// 0 (not yet asked) … 4.
    public var level: Int
    /// Any of its questions answered.
    public var seen: Bool
    /// When one of its questions comes back next.
    public var nextDue: Date?
    /// Mean recall of its answered questions now (nil: none answered); orders equal levels.
    public var recall: Double?

    public init(level: Int, seen: Bool, nextDue: Date?, recall: Double?) {
        self.level = level
        self.seen = seen
        self.nextDue = nextDue
        self.recall = recall
    }

    public static let unseen = TopicMastery(level: 0, seen: false, nextDue: nil, recall: nil)

    /// Known solidly (counts toward Ready).
    public var isSolid: Bool { level >= CoachRules.solidLevel }

    /// One question's level: 0 never answered; 1 not yet right or recall < 70 %; 2 known for less
    /// than a week; 3 a week or more (or recall < 90 %); 4 three weeks or more at ≥ 90 %.
    public static func level(of question: StudyQuestion, at now: Date) -> Int {
        guard let recall = Recall.retrievability(of: question, at: now), let stability = question.stability else { return 0 }
        if question.cardState == .learning || question.cardState == .relearning || recall < 0.7 { return 1 }
        if stability < 7 { return 2 }
        if stability < 21 || recall < CoachRules.desiredRetention { return 3 }
        return 4
    }

    /// A topic's mastery from its questions (retired ones and a reading's recall questions do not
    /// count: a read never counts toward Ready): the rounded mean level, unseen questions as 0,
    /// at least 1 once any was answered.
    public static func of(_ questions: [StudyQuestion], at now: Date) -> TopicMastery {
        let counted = questions.filter { $0.retiredAt == nil && $0.readingID == nil }
        guard !counted.isEmpty else { return .unseen }
        let answered = counted.filter { $0.reps > 0 }
        guard !answered.isEmpty else { return .unseen }
        let levels = counted.map { Self.level(of: $0, at: now) }
        let mean = Double(levels.reduce(0, +)) / Double(levels.count)
        let topicLevel = min(CoachRules.maximumLevel, max(1, Int(mean.rounded())))
        let recalls = answered.compactMap { Recall.retrievability(of: $0, at: now) }
        return TopicMastery(
            level: topicLevel,
            seen: true,
            nextDue: answered.compactMap(\.dueAt).min(),
            recall: recalls.isEmpty ? nil : recalls.reduce(0, +) / Double(recalls.count)
        )
    }

    /// Mastery per topic of `questions` (grouped by `StudyQuestion.topicKey`).
    public static func byTopic(_ questions: [StudyQuestion], at now: Date) -> [TopicKey: TopicMastery] {
        Dictionary(grouping: questions.compactMap { question in question.topicKey.map { ($0, question) } }, by: \.0)
            .mapValues { of($0.map(\.1), at: now) }
    }

    /// Weakest first: seen topics by level, then lower recall, then sooner due; unseen last.
    public static func weakestFirst(_ lhs: TopicMastery, _ rhs: TopicMastery) -> Bool {
        if lhs.seen != rhs.seen { return lhs.seen }
        if lhs.level != rhs.level { return lhs.level < rhs.level }
        if let left = lhs.recall, let right = rhs.recall, left != right { return left < right }
        return (lhs.nextDue ?? .distantFuture) < (rhs.nextDue ?? .distantFuture)
    }
}

/// Ready: the share of what has been taught that is known solidly (research §6.1: progress is
/// recall, never hours or pages).
public enum Readiness {
    /// `taught`: the topics of the lectures held so far; `mastery`: `TopicMastery.byTopic`.
    /// Nil when nothing was taught yet.
    public static func share(taught: [TopicKey], mastery: [TopicKey: TopicMastery]) -> Double? {
        let topics = Set(taught)
        guard !topics.isEmpty else { return nil }
        let solid = topics.filter { mastery[$0]?.isSolid == true }.count
        return Double(solid) / Double(topics.count)
    }
}

// MARK: - Budget

/// A course's self-study budget (research §6.1): the module's stated self-study hours, else
/// credits × the profile's hours per credit − its scheduled class hours; two thirds over the term,
/// one third over the runway (the last `CoachRules.runwayWeeks` weeks before the exam week). Weeks
/// start on Monday. A course without an exam (a seminar) spreads it over the whole term.
public struct StudyBudget: Hashable, Sendable {
    public var totalHours: Double
    /// The Monday of the first lecture week.
    public var termStart: CalendarDay
    /// The Monday the runway starts (nil: no exam date known, or a seminar).
    public var runwayStart: CalendarDay?
    /// The day of the exam the student sits.
    public var examDay: CalendarDay?
    /// The Monday after the last lecture week (the term's end when there is no runway).
    public var termEnd: CalendarDay

    public init(totalHours: Double, termStart: CalendarDay, runwayStart: CalendarDay?, examDay: CalendarDay?, termEnd: CalendarDay) {
        self.totalHours = totalHours
        self.termStart = termStart
        self.runwayStart = runwayStart
        self.examDay = examDay
        self.termEnd = termEnd
    }

    /// - Parameters:
    ///   - sessions: the course's sessions (class hours are the ones not cancelled).
    ///   - examDay: the day of the exam the student sits (`CourseExams.sat`), nil for none.
    public static func make(
        course: Course, semester: Semester, sessions: [LectureSession], examDay: CalendarDay?,
        profile: UniversityProfile = .current
    ) -> StudyBudget {
        let total: Double
        if let stated = course.selfStudyHours {
            total = stated
        } else {
            let credits = course.credits ?? profile.defaultCredits
            let classHours = sessions
                .filter { $0.courseID == course.id && !$0.isCancelled }
                .reduce(0) { $0 + max(0, $1.endsAt.timeIntervalSince($1.startsAt)) / 3_600 }
            total = max(0, credits * profile.hoursPerCredit - classHours)
        }
        let termStart = monday(of: semester.lectureStart)
        let termEnd = monday(of: semester.lectureEnd).adding(days: 7)
        let runwayStart = examDay.map { monday(of: $0).adding(days: -7 * CoachRules.runwayWeeks) }
            .map { max($0, termStart.adding(days: 7)) }
        return StudyBudget(totalHours: total, termStart: termStart, runwayStart: runwayStart, examDay: examDay, termEnd: termEnd)
    }

    public var termHours: Double { runwayStart == nil ? totalHours : totalHours * CoachRules.termShare }
    public var runwayHours: Double { runwayStart == nil ? 0 : totalHours - termHours }

    /// Weeks of the term phase (≥ 1).
    public var termWeeks: Int { max(1, termStart.days(to: runwayStart ?? termEnd) / 7) }

    /// True when `day` lies in the runway.
    public func isRunway(_ day: CalendarDay) -> Bool {
        guard let runwayStart else { return false }
        return day >= runwayStart && (examDay.map { day <= $0 } ?? true)
    }

    /// The share of the week containing `day`, in seconds (DC: 6 h 10 min now, 8 h in the runway);
    /// 0 before the term and after the exam.
    public func weeklyShare(containing day: CalendarDay) -> Double {
        let week = Self.monday(of: day)
        if week < termStart { return 0 }
        if let examDay, week > Self.monday(of: examDay) { return 0 }
        if let runwayStart, week >= runwayStart {
            return runwayHours / Double(CoachRules.runwayWeeks) * 3_600
        }
        if runwayStart == nil, week >= termEnd { return 0 }
        return termHours / Double(termWeeks) * 3_600
    }

    /// The Monday of `day`'s week.
    public static func monday(of day: CalendarDay) -> CalendarDay { day.adding(days: 1 - day.weekday) }
}

/// The term week for the Study subtitle ("Week 3 of 17"): Monday weeks from the first lecture week
/// to the last; nil outside the lecture period.
public struct TermWeek: Hashable, Sendable {
    public var number: Int
    public var count: Int

    public init(number: Int, count: Int) {
        self.number = number
        self.count = count
    }

    public init?(day: CalendarDay, semester: Semester) {
        guard semester.contains(day) else { return nil }
        let start = StudyBudget.monday(of: semester.lectureStart)
        number = start.days(to: StudyBudget.monday(of: day)) / 7 + 1
        count = start.days(to: StudyBudget.monday(of: semester.lectureEnd)) / 7 + 1
    }
}

// MARK: - Exams

/// A course's exam dates (tracked items of kind `exam`, not dismissed, by date): the first is
/// "Exam", the next "Second date"; the student sits the first unless a `sitting` rule says 2.
public struct CourseExams: Hashable, Sendable {
    public var first: TrackedItem?
    public var second: TrackedItem?
    /// 1 or 2.
    public var sitting: Int

    public init(first: TrackedItem?, second: TrackedItem?, sitting: Int) {
        self.first = first
        self.second = second
        self.sitting = sitting
    }

    public static func resolve(courseID: Course.ID, items: [TrackedItem], rules: PlanRules) -> CourseExams {
        let exams = items
            .filter { $0.courseID == courseID && $0.kind == .exam && $0.status != .dismissed && $0.dueAt != nil }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
        return CourseExams(first: exams.first, second: exams.dropFirst().first, sitting: rules.sitting(courseID))
    }

    /// The exam the student sits (the second date once chosen and known).
    public var sat: TrackedItem? { sitting == 2 ? (second ?? first) : first }

    /// True when the student sits the second date.
    public var sitsSecondDate: Bool { sitting == 2 && second != nil }
}

// MARK: - Plan rules

/// The plan rules in effect: `plan` memories that are not forgotten and carry a `PlanRule`.
public struct PlanRules: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public var memoryID: AgentMemory.ID
        public var rule: PlanRule

        public init(memoryID: AgentMemory.ID, rule: PlanRule) {
            self.memoryID = memoryID
            self.rule = rule
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public init(memories: [AgentMemory]) {
        entries = memories
            .filter { $0.forgottenAt == nil }
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap { memory in memory.planRule.map { Entry(memoryID: memory.id, rule: $0) } }
    }

    public static let none = PlanRules(entries: [])

    private func rules(_ kind: PlanRule.Kind) -> [PlanRule] { entries.map(\.rule).filter { $0.kind == kind } }

    /// An away day (travel): phone-sized blocks only.
    public func isAway(_ day: CalendarDay) -> Bool {
        rules(.away).contains { $0.applies(to: day) }
    }

    /// The most minutes of study on `day` (the lowest of its away and cap rules; nil: no cap).
    public func cap(on day: CalendarDay) -> Int? {
        let away = rules(.away).filter { $0.applies(to: day) }.map { $0.minutes ?? PlanRule.awayMinutes }
        let caps = rules(.cap).filter { $0.applies(to: day) }.compactMap(\.minutes)
        return (away + caps).min()
    }

    /// True when the student asked for no `kind` block (any kind when the rule names none) of
    /// `courseID` on `day`.
    public func skips(_ kind: StudyBlockKind, of courseID: Course.ID?, on day: CalendarDay) -> Bool {
        rules(.skip).contains { rule in
            rule.applies(to: day)
                && (rule.courseID == nil || rule.courseID == courseID)
                && (rule.blockKind == nil || rule.blockKind == kind)
        }
    }

    /// Which exam date of the course the student sits (1 unless a newer rule says 2).
    public func sitting(_ courseID: Course.ID) -> Int {
        rules(.sitting).last { $0.courseID == courseID }?.sitting ?? 1
    }

    /// Weekly hours for a seminar (off unless the student asked).
    public func plansSeminarHours(_ courseID: Course.ID) -> Bool {
        rules(.seminarHours).last { $0.courseID == courseID }?.enabled ?? false
    }

    /// False when the student said they do not attend this session (once, or its weekly slot).
    public func attends(_ session: LectureSession) -> Bool {
        !rules(.attend).contains { rule in
            rule.enabled != true
                && ((rule.sessionID != nil && rule.sessionID == session.id)
                    || (rule.slotID != nil && rule.slotID == session.weeklySlotID))
        }
    }
}

// MARK: - Studied time

/// Studied time (research §6.1: hours show pace only): the seconds of a course's answers (rounds,
/// practice exams) plus the planned minutes of its done blocks without a session (review,
/// exercise, read, seminar step; a round's time is in its answers).
public enum StudyTime {
    /// The week `[start, end)` containing `day` (Monday 00:00 to the next Monday, in `timeZone`),
    /// and its days.
    public static func week(containing day: CalendarDay, in timeZone: TimeZone) -> (range: Range<Date>, days: ClosedRange<CalendarDay>) {
        let monday = StudyBudget.monday(of: day)
        return (monday.start(in: timeZone)..<monday.adding(days: 7).start(in: timeZone), monday...monday.adding(days: 6))
    }

    /// Seconds per course with answers in `range` and blocks done on a day in `days`.
    public static func studied(
        answers: [StudyAnswer], blocks: [StudyBlock], in range: Range<Date>, days: ClosedRange<CalendarDay>
    ) -> [Course.ID: Double] {
        var seconds: [Course.ID: Double] = [:]
        for answer in answers where range.contains(answer.answeredAt) {
            seconds[answer.courseID, default: 0] += answer.seconds
        }
        for block in blocks where block.state == .done && block.sessionID == nil && days.contains(block.day) {
            let courses = block.courses
            guard !courses.isEmpty else { continue }
            let share = block.spentSeconds / Double(courses.count)
            for course in courses { seconds[course, default: 0] += share }
        }
        return seconds
    }
}
