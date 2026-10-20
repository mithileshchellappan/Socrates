import Foundation
import StudyCore

/// The rows the coach plans and measures from, read in one transaction (plan §7: one read, then
/// everything in memory). The plan engine, the catalog lines and `plan_query` all compute from
/// this, through StudyCore's measures only (`StudyBudget`, `TopicMastery`, `Readiness`,
/// `CourseExams`, `PlanRules`, `StudyTime`), so they never disagree with the screens.
public struct CoachRows: Sendable {
    public var now: Date
    public var today: CalendarDay
    public var semester: Semester
    public var profile: UniversityProfile
    /// The semester's courses (a course of another semester is not planned).
    public var courses: [Course]
    /// Every session of the courses (class hours of the budget, free time of a day).
    public var sessions: [LectureSession]
    public var lectures: [Lecture]
    /// The study pass's topic rows (ai · topic, not hidden).
    public var topics: [Annotation]
    /// Items that are not dismissed (exams, admission items, sheets, seminar milestones).
    public var items: [TrackedItem]
    /// Questions that are not retired.
    public var questions: [StudyQuestion]
    /// Readings that are not hidden.
    public var readings: [StudyReading]
    /// Answers given this week (studied time).
    public var weekAnswers: [StudyAnswer]
    /// Every wrong answer (a topic missed twice asks for a Read).
    public var misses: [StudyAnswer]
    /// Blocks from this week's Monday to the plan's last day.
    public var blocks: [StudyBlock]
    /// The rounds and exams those blocks started.
    public var sessionsByID: [StudySession.ID: StudySession]
    /// Active `plan` memories.
    public var planMemories: [AgentMemory]
    public var rules: PlanRules
    /// Timed spans of lectures with a review position (where review left off → its slide); mr:
    /// only those on the lecture's slides (its `LectureSlides` range).
    public var spans: [LectureDeckSpan]

    public var timeZone: TimeZone { CoachModule.timeZone }

    /// Reads everything in `db` (the caller's read transaction); the university profile is the
    /// library's unless `profile` is given.
    public static func load(_ db: Database, now: Date, profile: UniversityProfile? = nil) throws -> CoachRows {
        let profile = try profile ?? UniversityProfileRecord.profile(in: db)
        let zone = CoachModule.timeZone
        let today = CalendarDay(now, in: zone)
        let monday = StudyBudget.monday(of: today)
        let lastDay = today.adding(days: CoachRules.planDays)
        let semester = pickSemester(try Semester.all.fetchAll(db), on: now)
        let weekStart = monday.start(in: zone)
        let blocks = try StudyBlock
            .where { $0.day.gte(monday) && $0.day.lte(lastDay) }
            .order { ($0.day, $0.sortOrder, $0.createdAt) }
            .fetchAll(db)
        let sessionIDs = blocks.compactMap(\.sessionID)
        let studySessions = sessionIDs.isEmpty ? [] : try StudySession.where { $0.id.in(sessionIDs) }.fetchAll(db)
        let memories = try AgentMemory.where { $0.forgottenAt.is(nil) && $0.kind.eq(AgentMemoryKind.plan) }.fetchAll(db)
        let lectures = try Lecture.all.fetchAll(db)
        let reviewing = lectures.filter { $0.reviewPosition != nil && $0.reviewedAt == nil }.map(\.id)
        return CoachRows(
            now: now,
            today: today,
            semester: semester,
            profile: profile,
            courses: try Course.order(by: \.sortOrder).fetchAll(db).filter { $0.semesterID == nil || $0.semesterID == semester.id },
            sessions: try LectureSession.order(by: \.startsAt).fetchAll(db),
            lectures: lectures,
            topics: try Annotation
                .where { $0.kind.eq(AnnotationKind.topic) && $0.layer.eq(AnnotationLayer.ai) && $0.hiddenAt.is(nil) && $0.lectureID.isNot(nil) }
                .fetchAll(db),
            items: try TrackedItem.where { $0.status.neq(TrackedItemStatus.dismissed) }.fetchAll(db),
            questions: try StudyQuestion.where { $0.retiredAt.is(nil) }.fetchAll(db),
            readings: try StudyReading.where { $0.hiddenAt.is(nil) }.order { ($0.sortOrder, $0.createdAt) }.fetchAll(db),
            weekAnswers: try StudyAnswer.where { $0.answeredAt.gte(weekStart) }.fetchAll(db),
            misses: try StudyAnswer.where { $0.result.eq(StudyAnswerResult.wrong) }.fetchAll(db),
            blocks: blocks,
            sessionsByID: Dictionary(studySessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            planMemories: memories,
            rules: PlanRules(memories: memories),
            spans: reviewing.isEmpty ? [] : try onSlides(
                LectureDeckSpan
                    .where { $0.lectureID.in(reviewing) && $0.startTime.isNot(nil) && $0.firstPage.isNot(nil) }
                    .fetchAll(db),
                in: db
            )
        )
    }

    /// mr: the timed spans on their lecture's slides: its current range of a deck
    /// (`LectureSlides.current`); a lecture without a range keeps all of them (a capture's
    /// stamped deck).
    static func onSlides(_ spans: [LectureDeckSpan], in db: Database) throws -> [LectureDeckSpan] {
        var ranges: [Lecture.ID: LectureSlideRange?] = [:]
        var kept: [LectureDeckSpan] = []
        for span in spans {
            let lectureID = span.lectureID
            if ranges[lectureID] == nil {
                ranges[lectureID] = .some(try LectureSlides.current(lectureID: lectureID, in: db))
            }
            guard let range = ranges[lectureID] ?? nil else {
                kept.append(span)
                continue
            }
            guard span.deckID == range.deckID, let page = span.firstPage, range.contains(page) else { continue }
            kept.append(span)
        }
        return kept
    }

    /// The semester the coach plans in: the latest whose lectures began (its break and exam
    /// runway after the lecture period stay with it until the next one begins), else the first.
    static func pickSemester(_ semesters: [Semester], on date: Date) -> Semester {
        func day(_ semester: Semester) -> CalendarDay { CalendarDay(date, in: semester.zone) }
        if let latest = semesters.filter({ day($0) >= $0.lectureStart }).max(by: { $0.lectureStart < $1.lectureStart }) {
            return latest
        }
        return semesters.min(by: { $0.lectureStart < $1.lectureStart }) ?? .placeholder(on: date)
    }

    // MARK: - Per course

    /// What the coach knows about one course now (Study's row, Progress's figures, the catalog,
    /// `plan_query`).
    public struct CourseStatus: Sendable {
        public var course: Course
        public var exams: CourseExams
        /// A seminar (exam form `seminar`, or no exam item): no weekly share unless a
        /// `seminar_hours` rule turns it on; seminar steps instead.
        public var isSeminar: Bool
        public var budget: StudyBudget
        /// This week's share in seconds (0 for a seminar without hours).
        public var weeklyShare: Double
        /// Studied this week, seconds (`StudyTime`).
        public var studiedThisWeek: Double
        /// Ready (nil: nothing taught yet).
        public var ready: Double?
        /// The topics of the lectures held so far.
        public var taught: [TopicKey]
        public var mastery: [TopicKey: TopicMastery]
        /// The exam the student sits, as a day (nil: none known).
        public var examDay: CalendarDay?
        /// The practice exam's length: the announced minutes, else the profile's default.
        public var examMinutes: Int
        /// Credits were never set (the agent asks once).
        public var creditsUnknown: Bool
    }

    /// Every course's status, in course order.
    public var statuses: [CourseStatus] { courses.map(status) }

    public func status(_ course: Course) -> CourseStatus {
        let exams = CourseExams.resolve(courseID: course.id, items: items, rules: rules)
        let formSeminar = course.rules.contains { $0.kind == .examForm && $0.examForm == .seminar }
        let isSeminar = formSeminar || exams.first == nil
        let examDay = isSeminar ? nil : exams.sat?.dueAt.map { CalendarDay($0, in: timeZone) }
        let budget = StudyBudget.make(course: course, semester: semester, sessions: sessions, examDay: examDay, profile: profile)
        let share = isSeminar && !rules.plansSeminarHours(course.id) ? 0 : budget.weeklyShare(containing: today)
        let week = StudyTime.week(containing: today, in: timeZone)
        let studied = StudyTime.studied(answers: weekAnswers, blocks: blocks, in: week.range, days: week.days)[course.id] ?? 0
        let own = questions.filter { $0.courseID == course.id }
        let mastery = TopicMastery.byTopic(own, at: now)
        let taught = taughtTopics(of: course.id)
        let minutes = course.rules.first { $0.kind == .examForm && $0.minutes != nil }?.minutes ?? profile.defaultExamMinutes
        return CourseStatus(
            course: course, exams: exams, isSeminar: isSeminar, budget: budget, weeklyShare: share, studiedThisWeek: studied,
            ready: Readiness.share(taught: taught, mastery: mastery), taught: taught, mastery: mastery, examDay: examDay,
            examMinutes: minutes, creditsUnknown: course.credits == nil && course.selfStudyHours == nil
        )
    }

    /// The topics of a course's lectures held by now (unique, in lecture and slide order).
    public func taughtTopics(of courseID: Course.ID) -> [TopicKey] {
        let held = Set(lectures.filter { $0.courseID == courseID && ($0.heldAt ?? .distantFuture) <= now }.map(\.id))
        var seen: Set<TopicKey> = []
        var keys: [TopicKey] = []
        for topic in topics.sorted(by: Self.topicOrder) {
            guard let lectureID = topic.lectureID, held.contains(lectureID), let key = TopicKey(topic: topic) else { continue }
            if seen.insert(key).inserted { keys.append(key) }
        }
        return keys
    }

    /// Topics in slide order (then time, then title).
    static func topicOrder(_ lhs: Annotation, _ rhs: Annotation) -> Bool {
        (lhs.pageNumber ?? Int.max, lhs.startTime ?? .infinity, lhs.body) < (rhs.pageNumber ?? Int.max, rhs.startTime ?? .infinity, rhs.body)
    }

    // MARK: - Lectures

    /// The last slide the student reviewed (from `review_position` and the lecture's timed
    /// spans); 0 when not started. A reviewed lecture counts every slide.
    public func reviewedPage(_ lecture: Lecture) -> Int {
        if lecture.reviewedAt != nil { return Int.max }
        guard let position = lecture.reviewPosition else { return 0 }
        let own = spans.filter { $0.lectureID == lecture.id }
        let containing = own.filter { ($0.startTime ?? .infinity) <= position }.max { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
        return containing?.firstPage ?? 0
    }

    /// Where a slide was first shown in the lecture (Start of a review opens there).
    public func time(of page: Int?, in lectureID: Lecture.ID) -> Double? {
        guard let page else { return nil }
        if let span = spans.filter({ $0.lectureID == lectureID && ($0.firstPage ?? 0) <= page && page <= ($0.lastPage ?? $0.firstPage ?? 0) })
            .min(by: { ($0.startTime ?? .infinity) < ($1.startTime ?? .infinity) }) {
            return span.startTime
        }
        return topics.filter { $0.lectureID == lectureID && $0.pageNumber == page }.compactMap(\.startTime).min()
    }

    /// A lecture's topics in slide order.
    public func topics(of lectureID: Lecture.ID) -> [Annotation] {
        topics.filter { $0.lectureID == lectureID }.sorted(by: Self.topicOrder)
    }

    // MARK: - Days

    /// Minutes free for study on `day` between 08:00 and 20:00 outside the classes the student
    /// attends (for today: from now on).
    public func freeMinutes(_ day: CalendarDay) -> Int {
        let start = day.date(minute: CoachRules.dayStartMinute, in: timeZone)
        let end = day.date(minute: CoachRules.dayEndMinute, in: timeZone)
        let from = day == today ? max(start, now) : start
        guard end > from else { return 0 }
        var busy: [(Date, Date)] = []
        for session in sessions where !session.isCancelled && rules.attends(session) {
            let lower = max(session.startsAt, from)
            let upper = min(session.endsAt, end)
            if upper > lower { busy.append((lower, upper)) }
        }
        busy.sort { $0.0 < $1.0 }
        var taken: TimeInterval = 0
        var cursor = from
        for (lower, upper) in busy {
            let begin = max(lower, cursor)
            if upper > begin {
                taken += upper.timeIntervalSince(begin)
                cursor = upper
            }
        }
        return max(0, Int((end.timeIntervalSince(from) - taken) / 60))
    }

    /// True when a class the student attends meets on `day`.
    public func hasClass(_ day: CalendarDay) -> Bool {
        sessions.contains { !$0.isCancelled && rules.attends($0) && CalendarDay($0.startsAt, in: timeZone) == day }
    }

    /// The course's next attended lecture session after `day` (a review is due before it).
    func nextLectureDay(of courseID: Course.ID, after day: CalendarDay) -> CalendarDay? {
        sessions
            .filter { $0.courseID == courseID && !$0.isCancelled && $0.kind == .lecture && CalendarDay($0.startsAt, in: timeZone) > day }
            .map { CalendarDay($0.startsAt, in: timeZone) }
            .min()
    }

    /// True when `day` lies in a semester break or after the lecture period (before the exams).
    public func isBreak(_ day: CalendarDay) -> Bool {
        semester.breaks.contains { $0.contains(day) } || day > semester.lectureEnd
    }

    /// The short name a course is called by in titles ("CL"), else its name.
    func shortName(_ courseID: Course.ID?) -> String {
        guard let course = courses.first(where: { $0.id == courseID }) else { return "" }
        let short = course.shortName.trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? course.name : short
    }
}
