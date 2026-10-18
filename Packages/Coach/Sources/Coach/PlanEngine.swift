import Deadlines
import Foundation
import StudyCore

/// The plan engine (plan §4 "Day plan", research §6.2–6.4): pure, rows in, blocks out. Writes
/// today to `CoachRules.planDays` ahead as `study_block` rows (the caller hands `Output.blocks` to
/// `StudyPlanRepository.replacePlanned`).
///
/// Rules and where they are enforced:
/// - **Day size** (`Planner.capacity`): the free minutes 08:00–20:00 outside attended sessions
///   (`CoachRows.freeMinutes`), capped by the week's remaining share spread over its remaining
///   days by their free time (days without class carry the most), by a `cap` rule and on away
///   days by the away cap (30 min).
/// - **First-block order** (`Planner.planDay`): (1) an exam-admission item due within 48 h (and a
///   seminar's short gate), (2) Review of a lecture ≤ 2 days old or before the next lecture builds
///   on it, weakest topic's slides first, (3) the round of due practice items, (4) an exercise
///   sheet due within 3 days (admission-gated first, ≤ 105 min a block, ≤ 3 h a sheet), (5) a
///   runway practice exam, (6) Read only as gap-fill; then fillers (the rest of a lecture's
///   review, backlog reviews, seminar steps, later sheets) while the day has room.
/// - **Away days** (`PlanRules.isAway`): phone-sized only (a round of ≤ 12, misses first, plus one
///   short read); an item due on an away day is worked the day before ("due on an away day").
/// - **Classes and deadlines never move**: blocks carry no times; items keep their dates.
/// - **Today stable** (`Planner.todayIsFixed`): once today's blocks were written today (or one
///   started), they stay; only skips and an urgent admission item change them.
/// - **The student's blocks** (`created_by = user`) are kept as they are on every replan.
/// - **Expired one-day rules** are returned for the engine to forget (`Output.expiredRules`).
/// - **Block done** (derived, `Planner.doneSeconds`): review → `reviewed_at` or the review
///   position past its last slide; round / practice exam → its session ended or submitted;
///   exercise / seminar step → its item done; read → its recall questions answered, `done_at` or
///   its recall round ended; a started block without a session (a sheet, a seminar step, a
///   reading opened by its link) also once its minutes are up or its day is over
///   (`Planner.ranOut`; the opened reading's recall questions then join the rounds).
///   A planned block of a past day is `skipped`.
/// - **Phases** (never labelled): the runway (`StudyBudget.isRunway`) adds practice exams, reviews
///   only weak topics; breaks (`CoachRows.isBreak`) catch up the backlog; no new Read in the last
///   `CoachRules.noReadDays` days before the exam.
public enum PlanEngine {
    public struct Settled: Sendable, Hashable {
        public var id: StudyBlock.ID
        public var state: StudyBlockState
        public var spentSeconds: Double
    }

    public struct Output: Sendable {
        /// Today … today + `CoachRules.planDays`.
        public var days: ClosedRange<CalendarDay>
        /// Every planned block of `days` that should exist after the replan (the student's
        /// included); `replacePlanned` deletes the other planned ones.
        public var blocks: [StudyBlock]
        /// Open blocks that are done (derived) or whose day passed.
        public var settled: [Settled]
        /// `plan` memories whose one-off rule ended before today.
        public var expiredRules: [AgentMemory.ID]
        /// Readings whose recall questions are all answered.
        public var readingsDone: [StudyReading.ID]
    }

    // Sizes (research §6.2; the mockup's Tue 20 Oct: quiz 20 min, review 90 + 40 min, round 18 / 15
    // min, sheet 105 min, read 45 min).
    static let minutesPerSlide = 10
    static let reviewMinutes = 30...90
    static let sheetMinutes = 180
    static let sheetBlockMinutes = 105
    static let quickMinutes = 20
    static let registrationMinutes = 15
    static let wholeLectureMinutes = 60
    static let newPerDay = 8
    static let roundMaximum = 24
    static let awayRoundMaximum = 12
    static let seminarStepMinutes = 60

    public static func plan(_ rows: CoachRows) -> Output {
        var planner = Planner(rows: rows)
        return planner.run()
    }

    /// When a started block without a session counts as done: its start + its minutes (nil for
    /// the other blocks).
    static func runsOut(_ block: StudyBlock) -> Date? {
        guard block.state == .started, block.sessionID == nil, let start = block.startedAt else { return nil }
        guard block.kind == .exercise || block.kind == .seminarStep || block.kind == .read else { return nil }
        return start.addingTimeInterval(Double(block.minutes * 60))
    }

    /// Readings whose recall questions join the rounds: read (`done_at`), or opened from a Read
    /// block this week.
    static func readReadings(_ rows: CoachRows) -> Set<StudyReading.ID> {
        var read = Set(rows.readings.filter { $0.doneAt != nil }.map(\.id))
        // A started block with a session asks them in its own recall round.
        for block in rows.blocks where block.kind == .read && (block.state == .done || (block.state == .started && block.sessionID == nil)) {
            if let id = block.readingID { read.insert(id) }
        }
        return read
    }
}

/// One replan's state (what is covered so far, minutes per course and day).
struct Planner {
    let rows: CoachRows
    let zone: TimeZone
    let today: CalendarDay
    let days: ClosedRange<CalendarDay>
    let statuses: [Course.ID: CoachRows.CourseStatus]
    let rules: PlanRules
    /// Readings whose recall questions join the rounds (`PlanEngine.readReadings`).
    let readReadings: Set<StudyReading.ID>

    var settled: [PlanEngine.Settled] = []
    /// The blocks as they stand after the derived states.
    var current: [StudyBlock] = []
    var output: [StudyBlock] = []
    var coveredItems: [TrackedItem.ID: Int] = [:]
    var itemDays: Set<String> = []
    var coveredReadings: Set<StudyReading.ID> = []
    var coveredPages: [Lecture.ID: Set<Int>] = [:]
    var coveredLectures: Set<Lecture.ID> = []
    var practiceWeeks: Set<String> = []
    var seminarWeeks: Set<String> = []
    /// Minutes of open blocks per day and course (today on).
    var minutes: [CalendarDay: [Course.ID: Double]] = [:]
    var countedDue: Set<StudyQuestion.ID> = []
    var introduced: Int = 0

    init(rows: CoachRows) {
        self.rows = rows
        zone = rows.timeZone
        today = rows.today
        days = rows.today...rows.today.adding(days: CoachRules.planDays)
        statuses = Dictionary(rows.statuses.map { ($0.course.id, $0) }, uniquingKeysWith: { first, _ in first })
        rules = rows.rules
        readReadings = PlanEngine.readReadings(rows)
    }

    // MARK: - Run

    mutating func run() -> PlanEngine.Output {
        // Derived states of open blocks (today and before).
        var states: [StudyBlock.ID: StudyBlockState] = [:]
        for block in rows.blocks where block.state.isOpen && block.day <= today {
            if let spent = doneSeconds(block) {
                settled.append(PlanEngine.Settled(id: block.id, state: .done, spentSeconds: spent))
                states[block.id] = .done
            } else if block.day < today, block.state == .planned {
                settled.append(PlanEngine.Settled(id: block.id, state: .skipped, spentSeconds: 0))
                states[block.id] = .skipped
            }
        }
        current = rows.blocks.map { block in
            var block = block
            if let state = states[block.id] { block.state = state }
            return block
        }
        // What the standing blocks cover already.
        for block in current where block.state != .skipped {
            let fixedPlanned = block.state == .planned && (block.createdBy == .user || (block.day == today && todayIsFixed))
            guard block.state != .planned || fixedPlanned || block.day < today else { continue }
            cover(block, counting: block.day >= today && block.state.isOpen)
        }
        for offset in 0...days.lowerBound.days(to: days.upperBound) { planDay(days.lowerBound.adding(days: offset)) }

        let expired = rows.planMemories.filter { $0.planRule?.hasExpired(before: today) == true }.map(\.id)
        // Read: its recall questions answered, or (none drafted) its Read block done.
        let readBlocks = Set(rows.blocks.filter { $0.kind == .read && (states[$0.id] ?? $0.state) == .done }.compactMap(\.readingID))
        let readingsDone = rows.readings.filter { reading in
            guard reading.doneAt == nil else { return false }
            let recall = rows.questions.filter { $0.readingID == reading.id }
            return recall.isEmpty ? readBlocks.contains(reading.id) : recall.allSatisfy { $0.reps > 0 }
        }.map(\.id)
        return PlanEngine.Output(days: days, blocks: output, settled: settled, expiredRules: expired, readingsDone: readingsDone)
    }

    /// Today's blocks were written today (after the day began) or one of them was started.
    var todayIsFixed: Bool {
        let start = today.start(in: zone)
        return rows.blocks.contains { $0.day == today && ($0.createdAt >= start || $0.state != .planned) }
    }

    // MARK: - Derived states

    /// The seconds a done block counts, or nil while it is not done.
    func doneSeconds(_ block: StudyBlock) -> Double? {
        let planned = Double(block.minutes * 60)
        switch block.kind {
        case .review:
            guard let id = block.lectureID, let lecture = rows.lectures.first(where: { $0.id == id }) else { return nil }
            if lecture.reviewedAt != nil { return planned }
            if let last = block.lastPage, rows.reviewedPage(lecture) > last { return planned }
            return nil
        case .round, .practiceExam:
            guard let id = block.sessionID, let session = rows.sessionsByID[id], !session.state.isOpen else { return nil }
            return session.activeSeconds
        case .exercise, .seminarStep:
            if let id = block.trackedItemID, let item = rows.items.first(where: { $0.id == id }), item.status == .done { return planned }
            return ranOut(block) ? planned : nil
        case .read:
            if let id = block.readingID, let reading = rows.readings.first(where: { $0.id == id }) {
                if reading.doneAt != nil { return planned }
                let recall = rows.questions.filter { $0.readingID == id }
                if !recall.isEmpty && recall.allSatisfy({ $0.reps > 0 }) { return planned }
            }
            // A link-less reading's recall round ended.
            if let id = block.sessionID, let session = rows.sessionsByID[id], !session.state.isOpen { return session.activeSeconds }
            return ranOut(block) ? planned : nil
        default:
            return nil
        }
    }

    /// A started block without a session (an exercise, a seminar step, a reading opened by its
    /// link) whose time is up or whose day is over: done, so the hero moves on (a sheet split over
    /// two days or a seminar item weeks ahead is never done on the day).
    func ranOut(_ block: StudyBlock) -> Bool {
        guard block.state == .started, block.sessionID == nil else { return false }
        if block.day < today { return true }
        return PlanEngine.runsOut(block).map { $0 <= rows.now } ?? false
    }

    // MARK: - Coverage

    mutating func cover(_ block: StudyBlock, counting: Bool) {
        if let item = block.trackedItemID {
            coveredItems[item, default: 0] += block.minutes
            itemDays.insert("\(item)|\(block.day.rawValue)")
        }
        if let reading = block.readingID { coveredReadings.insert(reading) }
        if let lecture = block.lectureID {
            if let first = block.firstPage {
                coveredPages[lecture, default: []].formUnion(first...max(first, block.lastPage ?? first))
            } else {
                coveredLectures.insert(lecture)
            }
        }
        let week = StudyBudget.monday(of: block.day).rawValue
        if block.kind == .practiceExam, let course = block.courseID { practiceWeeks.insert("\(course)|\(week)") }
        if block.kind == .seminarStep, let course = block.courseID { seminarWeeks.insert("\(course)|\(week)") }
        if counting {
            let courses = block.courses
            for course in courses { minutes[block.day, default: [:]][course, default: 0] += Double(block.minutes) / Double(max(1, courses.count)) }
        }
    }

    // MARK: - Capacity

    func share(_ status: CoachRows.CourseStatus, on day: CalendarDay) -> Double {
        if status.isSeminar && !rules.plansSeminarHours(status.course.id) { return 0 }
        return status.budget.weeklyShare(containing: day) / 60
    }

    /// A course's minutes left in `day`'s week: its share − studied this week − planned so far.
    func remaining(_ courseID: Course.ID, on day: CalendarDay) -> Double {
        guard let status = statuses[courseID] else { return 0 }
        let monday = StudyBudget.monday(of: day)
        let studied = monday == StudyBudget.monday(of: today) ? status.studiedThisWeek / 60 : 0
        var planned = 0.0
        for offset in 0..<7 {
            let other = monday.adding(days: offset)
            guard other >= today else { continue }
            planned += minutes[other]?[courseID] ?? 0
        }
        return share(status, on: day) - studied - planned
    }

    /// The week's minutes left over every course (none below zero).
    func weekRemaining(_ day: CalendarDay) -> Double {
        statuses.keys.reduce(0) { $0 + max(0, remaining($1, on: day)) }
    }

    /// What a day can hold: free time, a cap rule, the away cap.
    func dayLimit(_ day: CalendarDay) -> Int {
        let free = rows.freeMinutes(day)
        if let cap = rules.cap(on: day) { return min(free, cap) }
        return free
    }

    /// The day's planned size: its limit, and the week's remaining share spread over the days
    /// left in the week by their room (days without class carry the most).
    func capacity(_ day: CalendarDay) -> Int {
        let limit = dayLimit(day)
        let monday = StudyBudget.monday(of: day)
        let rest = (0..<7).map { monday.adding(days: $0) }.filter { $0 >= day }
        let weights = rest.map { Double(dayLimit($0)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        // `weekRemaining` has the day's own kept blocks (the student's) taken off already: they
        // come on top of the day's part.
        let share = max(0, weekRemaining(day)) * Double(limit) / total
        return min(limit, Int(share.rounded()) + planned(on: day))
    }

    /// Minutes planned on `day` so far (this replan and the blocks kept).
    func planned(on day: CalendarDay) -> Int {
        Int((minutes[day] ?? [:]).values.reduce(0, +).rounded())
    }

    // MARK: - A day

    mutating func planDay(_ day: CalendarDay) {
        let away = rules.isAway(day)
        let existing = current.filter { $0.day == day && $0.state == .planned && $0.createdBy == .agent }
        // The student's blocks stay as they are.
        let placed = current.filter { $0.day == day && $0.state == .planned && $0.createdBy == .user }
        output += placed
        if day == today, todayIsFixed {
            var kept = existing.filter { block in
                let courses = block.courses
                if courses.isEmpty { return !rules.skips(block.kind, of: nil, on: day) }
                return !courses.allSatisfy { rules.skips(block.kind, of: $0, on: day) }
            }
            let fresh = gates(on: day, away: away)
            let first = (current.filter { $0.day == day }.map(\.sortOrder).min() ?? 0) - fresh.count
            for (offset, block) in fresh.enumerated() {
                var block = block
                block.sortOrder = first + offset
                cover(block, counting: true)
                kept.append(block)
            }
            output += kept
            return
        }
        var built: [StudyBlock] = []
        let limit = away ? min(dayLimit(day), rules.cap(on: day) ?? PlanRule.awayMinutes) : dayLimit(day)
        let size = away ? limit : capacity(day)
        var used = planned(on: day)

        // (1) Exam admission due within 48 h, a seminar's short gate, registration.
        for block in gates(on: day, away: away) {
            cover(block, counting: true)
            built.append(block)
            used += block.minutes
        }
        // (2) Review of a recent lecture: its weakest topic's slides.
        var reviewedToday: [Lecture] = []
        if !away {
            for lecture in recentLectures(on: day) {
                guard used < limit, let block = review(lecture, on: day, room: limit - used) else { continue }
                cover(block, counting: true)
                built.append(block)
                used += block.minutes
                reviewedToday.append(lecture)
            }
        }
        // (3) The round: due items, then new ones (every study day, away days too).
        if let block = round(on: day, away: away) {
            cover(block, counting: true)
            built.append(block)
            used += block.minutes
        }
        if !away {
            // (4) Exercise sheets due within 3 days.
            for block in sheets(on: day, within: 3, room: limit - used) {
                cover(block, counting: true)
                built.append(block)
                used += block.minutes
            }
            // (5) A runway practice exam.
            for block in practiceExams(on: day, room: size - used) {
                cover(block, counting: true)
                built.append(block)
                used += block.minutes
            }
        }
        // (6) Read as gap-fill (one; two on break days; one short one on away days).
        let reads = away ? 1 : (rows.isBreak(day) ? 2 : 1)
        for _ in 0..<reads {
            guard let block = read(on: day, room: (away ? limit : size) - used, away: away) else { break }
            cover(block, counting: true)
            built.append(block)
            used += block.minutes
        }
        if !away {
            // Fillers while the day has room: the rest of today's reviews, backlog reviews,
            // seminar steps, later sheets.
            for lecture in reviewedToday {
                guard size - used >= PlanEngine.reviewMinutes.lowerBound,
                      let block = review(lecture, on: day, room: size - used) else { continue }
                cover(block, counting: true)
                built.append(block)
                used += block.minutes
            }
            let backlog = rows.isBreak(day) ? 2 : 1
            for lecture in backlogLectures(on: day).prefix(backlog) {
                guard size - used >= PlanEngine.reviewMinutes.lowerBound, remaining(lecture.courseID, on: day) > 0,
                      let block = review(lecture, on: day, room: size - used) else { continue }
                cover(block, counting: true)
                built.append(block)
                used += block.minutes
            }
            for block in seminarSteps(on: day, room: size - used) {
                cover(block, counting: true)
                built.append(block)
                used += block.minutes
            }
            for block in sheets(on: day, within: 7, room: size - used) {
                cover(block, counting: true)
                built.append(block)
                used += block.minutes
            }
        }
        // Order after the student's blocks; reuse ids of the same block planned before.
        let start = (placed.map(\.sortOrder).max() ?? -1) + 1
        var reuse: [String: StudyBlock] = [:]
        for block in existing { reuse[key(block)] = reuse[key(block)] ?? block }
        let rewritingToday = day == today
        for (offset, block) in built.enumerated() {
            var block = block
            block.sortOrder = start + offset
            if let old = reuse.removeValue(forKey: key(block)) {
                block = StudyBlock(
                    id: old.id, day: block.day, sortOrder: block.sortOrder, kind: block.kind, courseID: block.courseID,
                    courseIDs: block.courseIDs, title: block.title, detail: block.detail, why: block.why, minutes: block.minutes,
                    questionCount: block.questionCount, lectureID: block.lectureID, firstPage: block.firstPage, lastPage: block.lastPage,
                    trackedItemID: block.trackedItemID, readingID: block.readingID, url: block.url, isAway: block.isAway,
                    createdBy: .agent, createdAt: rewritingToday ? rows.now : old.createdAt, updatedAt: rows.now
                )
            }
            output.append(block)
        }
    }

    /// What makes two plannings of a block the same block (its id is kept).
    func key(_ block: StudyBlock) -> String {
        [
            block.kind.rawValue, block.lectureID?.uuidString ?? "", block.firstPage.map(String.init) ?? "",
            block.trackedItemID?.uuidString ?? "", block.readingID?.uuidString ?? "",
            block.courses.map(\.uuidString).joined(separator: ","),
        ].joined(separator: "|")
    }

    func newBlock(
        _ day: CalendarDay, kind: StudyBlockKind, courseID: Course.ID?, courseIDs: [Course.ID] = [], title: String, detail: String = "",
        why: String = "", minutes: Int, questionCount: Int? = nil, lectureID: Lecture.ID? = nil, firstPage: Int? = nil,
        lastPage: Int? = nil, trackedItemID: TrackedItem.ID? = nil, readingID: StudyReading.ID? = nil
    ) -> StudyBlock {
        StudyBlock(
            day: day, kind: kind, courseID: courseID, courseIDs: courseIDs, title: title, detail: detail, why: why, minutes: minutes,
            questionCount: questionCount, lectureID: lectureID, firstPage: firstPage, lastPage: lastPage, trackedItemID: trackedItemID,
            readingID: readingID, isAway: rules.isAway(day), state: .planned, createdBy: .agent, createdAt: rows.now, updatedAt: rows.now
        )
    }

    // MARK: (1) Gates

    /// A short item (a quiz, a survey, a registration): about 20 minutes.
    static func isQuick(_ item: TrackedItem) -> Bool {
        let words = TextFolding.fold(item.title)
        return ["quiz", "test", "survey", "umfrage", "poll", "form", "anmeld", "regist"].contains { words.contains($0) }
    }

    /// The day an item is worked: its due day, or the last day before it that is not an away day.
    func workDay(for due: CalendarDay) -> CalendarDay {
        var day = due
        var steps = 0
        while rules.isAway(day), day > today, steps < 14 {
            day = day.adding(days: -1)
            steps += 1
        }
        return day
    }

    /// Exam-admission items due within 48 h, a seminar's short gate (due within 48 h), and an exam
    /// registration (from a week before it closes), not yet planned.
    mutating func gates(on day: CalendarDay, away: Bool) -> [StudyBlock] {
        var blocks: [StudyBlock] = []
        let open = rows.items
            .filter { $0.status == .open && ($0.dueAt ?? .distantPast) > rows.now && !$0.kind.isSessionChange && !$0.kind.isSessionProposal }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
        for item in open {
            guard let due = item.dueAt, coveredItems[item.id] == nil else { continue }
            let seminar = item.courseID.flatMap { statuses[$0] }?.isSeminar == true
            let admission = item.relevance == .examAdmission && item.kind.isDue
            let gate = seminar && Self.isQuick(item)
            let registration = item.relevance == .registration
            guard admission || gate || registration else { continue }
            if let course = item.courseID, rules.skips(.exercise, of: course, on: day) { continue }
            let dueDay = CalendarDay(due, in: zone)
            guard day <= dueDay else { continue }
            let work = workDay(for: dueDay)
            let window: TimeInterval = registration ? 7 * 86_400 : 48 * 3_600
            let near = due.timeIntervalSince(day.start(in: zone)) <= window
            guard (near && !away && day <= work) || day == work else { continue }
            let quick = Self.isQuick(item) || !item.kind.isDue
            let minutes = registration ? PlanEngine.registrationMinutes
                : (quick ? PlanEngine.quickMinutes : min(PlanEngine.sheetBlockMinutes, PlanEngine.sheetMinutes))
            let why = rules.isAway(dueDay) && day < dueDay ? "due on an away day" : ""
            blocks.append(newBlock(day, kind: .exercise, courseID: item.courseID, title: item.title, why: why, minutes: minutes, trackedItemID: item.id))
        }
        return blocks
    }

    // MARK: (2) Reviews

    /// Lectures to review on `day`: held in the last 2 days, or before the course's next lecture
    /// tomorrow builds on them; not reviewed, not skipped.
    func recentLectures(on day: CalendarDay) -> [Lecture] {
        rows.lectures.filter { lecture in
            guard lecture.reviewedAt == nil, let held = lecture.heldAt, !coveredLectures.contains(lecture.id) else { return false }
            if day == today, held > rows.now { return false }
            let heldDay = CalendarDay(held, in: zone)
            guard heldDay <= day, !rules.skips(.review, of: lecture.courseID, on: day) else { return false }
            let recent = heldDay.days(to: day) <= 2
            let beforeNext = rows.nextLectureDay(of: lecture.courseID, after: heldDay) == day.adding(days: 1)
            return recent || beforeNext
        }
        .sorted { ($0.heldAt ?? .distantPast) > ($1.heldAt ?? .distantPast) }
    }

    /// Older unreviewed lectures (the backlog), oldest first.
    func backlogLectures(on day: CalendarDay) -> [Lecture] {
        rows.lectures.filter { lecture in
            guard lecture.reviewedAt == nil, let held = lecture.heldAt, !coveredLectures.contains(lecture.id) else { return false }
            return CalendarDay(held, in: zone).days(to: day) > 2 && !rules.skips(.review, of: lecture.courseID, on: day)
        }
        .sorted { ($0.heldAt ?? .distantPast) < ($1.heldAt ?? .distantPast) }
    }

    /// The next review block of a lecture: its weakest open topic's slides, merged with the
    /// adjacent open topics up to 90 minutes (the runway: weak topics only). A lecture without
    /// topics is reviewed whole (from the first slide not reviewed).
    mutating func review(_ lecture: Lecture, on day: CalendarDay, room: Int) -> StudyBlock? {
        guard room >= PlanEngine.reviewMinutes.lowerBound || room >= 15 else { return nil }
        let status = statuses[lecture.courseID]
        let runway = status?.budget.isRunway(day) == true
        let reviewed = rows.reviewedPage(lecture)
        let covered = coveredPages[lecture.id] ?? []
        let title = lecture.number.map { "Lecture \($0)" } ?? (lecture.title.isEmpty ? "Lecture" : lecture.title)
        let topics = rows.topics(of: lecture.id).filter { $0.pageNumber != nil }
        guard !topics.isEmpty else {
            guard !runway, !coveredLectures.contains(lecture.id) else { return nil }
            coveredLectures.insert(lecture.id)
            let first = reviewed > 0 ? reviewed + 1 : nil
            return newBlock(
                day, kind: .review, courseID: lecture.courseID, title: title, detail: first.map { "from slide \($0)" } ?? "",
                minutes: min(PlanEngine.wholeLectureMinutes, max(15, room)), lectureID: lecture.id, firstPage: first
            )
        }
        func pages(_ topic: Annotation) -> ClosedRange<Int> {
            let first = topic.pageNumber ?? 1
            return first...max(first, topic.lastPage ?? first)
        }
        let mastery = status?.mastery ?? [:]
        var open = topics.filter { topic in
            let range = pages(topic)
            return range.upperBound > reviewed && !range.allSatisfy(covered.contains)
        }
        if runway {
            open = open.filter { topic in TopicKey(topic: topic).flatMap { mastery[$0] }.map { $0.seen && $0.level <= 1 } ?? false }
        }
        guard !open.isEmpty else { return nil }
        let weakest = open.min { lhs, rhs in
            let left = TopicKey(topic: lhs).flatMap { mastery[$0] } ?? .unseen
            let right = TopicKey(topic: rhs).flatMap { mastery[$0] } ?? .unseen
            if left.seen != right.seen { return left.seen }
            if left.level != right.level { return left.level < right.level }
            return pages(lhs).lowerBound < pages(rhs).lowerBound
        } ?? open[0]
        let limit = min(PlanEngine.reviewMinutes.upperBound, max(PlanEngine.reviewMinutes.lowerBound, room))
        func cost(_ range: ClosedRange<Int>) -> Int { range.count * PlanEngine.minutesPerSlide }
        var range = max(pages(weakest).lowerBound, reviewed + 1)...pages(weakest).upperBound
        // Grow over adjacent open topics (by slide) while it stays within the limit. Each topic is
        // clamped to the slides not reviewed yet first, so a topic the review stopped inside can
        // never count as growth again; at most one pass per topic.
        let bySlide = open.sorted { pages($0).lowerBound < pages($1).lowerBound }
        var grew = true
        var passes = 0
        while grew, passes <= bySlide.count {
            grew = false
            passes += 1
            for topic in bySlide {
                let lower = max(pages(topic).lowerBound, reviewed + 1)
                guard lower <= pages(topic).upperBound else { continue }
                let other = lower...pages(topic).upperBound
                let touches = other.lowerBound <= range.upperBound + 1 && other.upperBound >= range.lowerBound - 1
                guard touches, !range.contains(other.lowerBound) || !range.contains(other.upperBound) else { continue }
                let merged = min(range.lowerBound, other.lowerBound)...max(range.upperBound, other.upperBound)
                if merged != range, cost(merged) <= limit {
                    range = merged
                    grew = true
                }
            }
        }
        // Slides covered by an earlier block are left out at the edges.
        while range.lowerBound < range.upperBound, covered.contains(range.lowerBound) { range = (range.lowerBound + 1)...range.upperBound }
        while range.upperBound > range.lowerBound, covered.contains(range.upperBound) { range = range.lowerBound...(range.upperBound - 1) }
        let minutes = min(limit, max(PlanEngine.reviewMinutes.lowerBound, cost(range)))
        return newBlock(
            day, kind: .review, courseID: lecture.courseID, title: title, detail: CoachText.slides(range.lowerBound, range.upperBound),
            minutes: minutes, lectureID: lecture.id, firstPage: range.lowerBound, lastPage: range.upperBound
        )
    }

    // MARK: (3) The round

    /// Due items of the day (not counted on an earlier day), then up to 8 new ones a day; ≤ 24
    /// questions (≤ 12 on an away day); about 1.2 a minute.
    mutating func round(on day: CalendarDay, away: Bool) -> StudyBlock? {
        let courses = rows.courses.map(\.id).filter { !rules.skips(.round, of: $0, on: day) }
        guard !courses.isEmpty else { return nil }
        let allowed = Set(courses)
        let end = day.adding(days: 1).start(in: zone)
        let eligible = rows.questions.filter {
            $0.pool == .round && ($0.readingID.map(readReadings.contains) ?? true) && allowed.contains($0.courseID)
        }
        let due = eligible.filter { $0.reps > 0 && ($0.dueAt ?? .distantFuture) < end && !countedDue.contains($0.id) }
        let held = Set(rows.lectures.filter { ($0.heldAt ?? .distantFuture) < end }.map(\.id))
        let fresh = eligible.filter { $0.reps == 0 && ($0.lectureID.map(held.contains) ?? true) }
        let newCount = max(0, min(PlanEngine.newPerDay, fresh.count - introduced))
        let maximum = away ? PlanEngine.awayRoundMaximum : PlanEngine.roundMaximum
        let count = min(maximum, due.count + newCount)
        guard count > 0 else { return nil }
        let takenDue = Array(due.sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }.prefix(count))
        countedDue.formUnion(takenDue.map(\.id))
        introduced += max(0, count - takenDue.count)
        var involved = Set(takenDue.map(\.courseID))
        if count > takenDue.count { involved.formUnion(fresh.map(\.courseID)) }
        let ordered = rows.courses.map(\.id).filter(involved.contains)
        let minutes = max(5, (Int((Double(count) / CoachRules.questionsPerMinute).rounded(.up)) + 4) / 5 * 5)
        return newBlock(
            day, kind: .round, courseID: ordered.count == 1 ? ordered.first : nil, courseIDs: ordered, title: "\(count) questions",
            minutes: minutes, questionCount: count
        )
    }

    // MARK: (4) Sheets

    /// Exercise sheets and deadlines due within `within` days of `day` (not on their due day unless
    /// they close in the evening), admission-gated first: ≤ 105 min a block, ≤ 3 h a sheet, one
    /// block a day.
    mutating func sheets(on day: CalendarDay, within: Int, room: Int) -> [StudyBlock] {
        var blocks: [StudyBlock] = []
        var room = room
        let candidates = rows.items
            .filter { item in
                guard item.status == .open, item.kind == .exercise || item.kind == .deadline, let course = item.courseID,
                      statuses[course]?.isSeminar != true, item.relevance != .registration, !Self.isQuick(item),
                      let due = item.dueAt, due > rows.now else { return false }
                let dueDay = CalendarDay(due, in: zone)
                let lateEnough = DateMentions.minute(of: due, timeZone: zone) >= 18 * 60
                let work = workDay(for: dueDay)
                guard day.days(to: dueDay) <= within, day < dueDay || (day == dueDay && lateEnough), day <= work else { return false }
                return !rules.skips(.exercise, of: course, on: day) && !itemDays.contains("\(item.id)|\(day.rawValue)")
            }
            .sorted { lhs, rhs in
                let left = lhs.relevance == .examAdmission
                let right = rhs.relevance == .examAdmission
                if left != right { return left }
                return (lhs.dueAt ?? .distantFuture) < (rhs.dueAt ?? .distantFuture)
            }
        for item in candidates {
            let left = PlanEngine.sheetMinutes - (coveredItems[item.id] ?? 0)
            let minutes = min(PlanEngine.sheetBlockMinutes, left, room)
            guard minutes >= 30 else { continue }
            let dueDay = item.dueAt.map { CalendarDay($0, in: zone) }
            let why = dueDay.map { rules.isAway($0) && day < $0 } == true ? "due on an away day" : ""
            blocks.append(newBlock(day, kind: .exercise, courseID: item.courseID, title: item.title, why: why, minutes: minutes, trackedItemID: item.id))
            itemDays.insert("\(item.id)|\(day.rawValue)")
            room -= minutes
        }
        return blocks
    }

    // MARK: (5) Practice exams

    /// One practice exam per course and runway week, in the exam's length, on a day with room.
    mutating func practiceExams(on day: CalendarDay, room: Int) -> [StudyBlock] {
        var blocks: [StudyBlock] = []
        var room = room
        let week = StudyBudget.monday(of: day).rawValue
        for status in rows.statuses where !status.isSeminar {
            guard let exam = status.examDay, day < exam, status.budget.isRunway(day),
                  !practiceWeeks.contains("\(status.course.id)|\(week)"), !rules.skips(.practiceExam, of: status.course.id, on: day),
                  room >= status.examMinutes else { continue }
            blocks.append(newBlock(day, kind: .practiceExam, courseID: status.course.id, title: "Practice exam", minutes: status.examMinutes))
            practiceWeeks.insert("\(status.course.id)|\(week)")
            room -= status.examMinutes
        }
        return blocks
    }

    // MARK: (6) Read

    /// One reading as gap-fill: the slides assume it (gap), a topic of it was missed twice, or the
    /// lecturer named it; never in the last 3 days before the exam; on an away day only a short one.
    mutating func read(on day: CalendarDay, room: Int, away: Bool) -> StudyBlock? {
        guard room >= 10 else { return nil }
        let end = day.adding(days: 1).start(in: zone)
        var missed: [TopicKey: Int] = [:]
        let byID = Dictionary(rows.questions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for answer in rows.misses {
            if let key = byID[answer.questionID]?.topicKey { missed[key, default: 0] += 1 }
        }
        func reason(_ reading: StudyReading) -> Int? {
            if reading.reason == .gap { return 0 }
            if let key = reading.topicKey, (missed[key] ?? 0) >= 2 { return 1 }
            if reading.reason == .lecturer { return 2 }
            return nil
        }
        let candidates = rows.readings.filter { reading in
            guard reading.doneAt == nil, !coveredReadings.contains(reading.id), reading.minutes <= room, reason(reading) != nil,
                  !rules.skips(.read, of: reading.courseID, on: day) else { return false }
            if let lectureID = reading.lectureID, let lecture = rows.lectures.first(where: { $0.id == lectureID }),
               (lecture.heldAt ?? .distantFuture) >= end { return false }
            if let exam = statuses[reading.courseID]?.examDay, day.days(to: exam) < CoachRules.noReadDays { return false }
            return away ? reading.minutes <= room : remaining(reading.courseID, on: day) > 0 || rows.isBreak(day)
        }
        .sorted { lhs, rhs in
            let left = reason(lhs) ?? 9
            let right = reason(rhs) ?? 9
            if left != right { return left < right }
            return (lhs.sortOrder, lhs.minutes) < (rhs.sortOrder, rhs.minutes)
        }
        guard let reading = candidates.first else { return nil }
        coveredReadings.insert(reading.id)
        var why = ""
        if reading.reason == .gap {
            let subject = reading.section.isEmpty ? reading.topic : reading.section
            if !subject.isEmpty { why = "\(subject.lowercased()), which the \(rows.shortName(reading.courseID)) slides assume" }
        } else if let key = reading.topicKey, (missed[key] ?? 0) >= 2 {
            why = "\(reading.topic.lowercased()), missed twice"
        }
        return newBlock(day, kind: .read, courseID: reading.courseID, title: reading.title, why: why, minutes: reading.minutes, readingID: reading.id)
    }

    // MARK: Seminar steps

    /// A seminar's next milestone (its talk, paper, slides…), one step a week, planned backward
    /// from its item's date.
    mutating func seminarSteps(on day: CalendarDay, room: Int) -> [StudyBlock] {
        var blocks: [StudyBlock] = []
        var room = room
        let week = StudyBudget.monday(of: day).rawValue
        for status in rows.statuses where status.isSeminar {
            guard !seminarWeeks.contains("\(status.course.id)|\(week)"), !rules.skips(.seminarStep, of: status.course.id, on: day) else { continue }
            let next = rows.items
                .filter { item in
                    guard item.courseID == status.course.id, item.status == .open, !Self.isQuick(item), let due = item.dueAt,
                          due > rows.now, item.kind.isDue || item.kind == .event else { return false }
                    let dueDay = CalendarDay(due, in: zone)
                    return day < dueDay && day.days(to: dueDay) <= 21
                }
                .min { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
            guard let item = next, let due = item.dueAt else { continue }
            let minutes = CalendarDay(due, in: zone).days(to: day) > -7 ? 90 : PlanEngine.seminarStepMinutes
            guard room >= minutes else { continue }
            blocks.append(newBlock(day, kind: .seminarStep, courseID: status.course.id, title: item.title, minutes: minutes, trackedItemID: item.id))
            seminarWeeks.insert("\(status.course.id)|\(week)")
            room -= minutes
        }
        return blocks
    }
}
