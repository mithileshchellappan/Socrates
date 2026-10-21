import StudyCore
import StudyUI
import SwiftUI

/// Study (mockup 13; the sidebar row after Notes): the coach across courses. Three zones in a
/// 680 pt column: the plan's current block (the same card as Today's hero); Courses, each against
/// its exam ("Exam Tue 9 Feb, 10:00", Ready with a meter) and this week against its share of the
/// budget ("2 h of 6 h 10 min"), a click opens its Progress; Weakest topics (≤ 6), a click opens the
/// lecture at the second the topic was explained, Practice This Topic in the context menu. The
/// subtitle is the term week ("Week 3 of 17").
public struct StudyView: View {
    private let fixedNow: Date?

    @Fetch private var data: StudyData
    @State private var loaded: StudyRequest?
    private let initialRequest: StudyRequest
    @Dependency(\.defaultDatabase) private var database
    @Environment(\.timeZone) private var timeZone

    /// - Parameter now: a fixed "now" (renders); nil follows the clock.
    public init(now: Date? = nil) {
        fixedNow = now
        let zone = TimeZone.current
        let request = StudyRequest(day: CalendarDay(now ?? Date(), in: zone), timeZone: zone)
        initialRequest = request
        _data = Fetch(wrappedValue: StudyData(day: request.day), request)
    }

    public var body: some View {
        Group {
            if let fixedNow {
                StudyContent(data: data, now: fixedNow)
            } else {
                TimelineView(.everyMinute) { context in
                    StudyContent(data: data, now: context.date)
                }
            }
        }
        .agentContext(AgentContext(screen: .study))
        .task(id: StudyRequest(day: CalendarDay(fixedNow ?? Date(), in: timeZone), timeZone: timeZone)) {
            let request = StudyRequest(day: CalendarDay(fixedNow ?? Date(), in: timeZone), timeZone: timeZone)
            guard request != (loaded ?? initialRequest) else { return }
            loaded = request
            _ = try? await $data.load(request, database: database)
        }
    }
}

// MARK: - Rows

struct StudyData: Hashable, Sendable {
    var plan: PlanDay
    var courses: [CourseRows] = []
    var semesters: [Semester] = []
    var rules = PlanRules.none
    /// This week's answers and blocks (studied time).
    var answers: [StudyAnswer] = []
    var blocks: [StudyBlock] = []

    init(day: CalendarDay) {
        plan = PlanDay(day: day)
    }

    var courseMap: [Course.ID: Course] {
        Dictionary(courses.map { ($0.course.id, $0.course) }, uniquingKeysWith: { first, _ in first })
    }
}

struct StudyRequest: FetchKeyRequest {
    let day: CalendarDay
    let timeZone: TimeZone

    func fetch(_ db: Database) throws -> StudyData {
        var data = StudyData(day: day)
        data.plan = try PlanDay.fetch(db, day: day)
        let courses = try Course.all.order { ($0.sortOrder, $0.name) }.fetchAll(db)
        let from = day.start(in: timeZone)
        data.courses = try courses.map { try CoachRows.course($0, from: from, db) }
        data.semesters = try Semester.all.fetchAll(db)
        data.rules = try CoachRows.rules(db)
        let week = StudyTime.week(containing: day, in: timeZone)
        let start = week.range.lowerBound
        let end = week.range.upperBound
        data.answers = try StudyAnswer.where { $0.answeredAt.gte(start) && $0.answeredAt.lt(end) }.fetchAll(db)
        let first = week.days.lowerBound
        let last = week.days.upperBound
        data.blocks = try StudyBlock.where { $0.day.gte(first) && $0.day.lte(last) }.fetchAll(db)
        return data
    }
}

// MARK: - Screen

private struct StudyContent: View {
    let data: StudyData
    let now: Date

    @Environment(\.timeZone) private var timeZone

    var body: some View {
        let today = CalendarDay(now, in: timeZone)
        let lines = courseLines(today: today)
        let weakest = weakestTopics(lines)
        let semester = CoachRows.semester(for: nil, day: today, in: data.semesters)
        let week = semester.flatMap { TermWeek(day: today, semester: $0) }
        let courses = data.courseMap
        // Study data: some course has a lecture, a taught topic or a question.
        let hasStudyData = data.courses.contains { !$0.lectures.isEmpty || !$0.topics.isEmpty || !$0.questions.isEmpty }
        Group {
            if data.plan.current == nil && (!hasStudyData || lines.isEmpty) {
                // Nothing studied or to study yet: what feeds the screen (smart import, no course).
                EmptyDropPrompt(systemImage: "brain", line: "Study starts with your lectures' slides and recordings.", target: nil)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if data.plan.current != nil {
                            PlanHero(plan: data.plan, courses: courses, now: now)
                        }
                        if !lines.isEmpty {
                            StudyCoursesZone(lines: lines, now: now)
                        }
                        if !weakest.isEmpty {
                            WeakestTopicsZone(topics: weakest)
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 22)
                    .padding(.bottom, 16)
                    .padding(.horizontal, 20)
                }
            }
        }
        .screenTitle(String(localized: "Study"), subtitle: week.map { String(localized: "Week \($0.number) of \($0.count)") })
    }

    /// The courses with something to study: lectures, questions or due items (a timetable's course
    /// without any is left out).
    private func courseLines(today: CalendarDay) -> [StudyCourseLine] {
        let week = StudyTime.week(containing: today, in: timeZone)
        let studied = StudyTime.studied(answers: data.answers, blocks: data.blocks, in: week.range, days: week.days)
        let active = data.courses.filter { !$0.lectures.isEmpty || !$0.questions.isEmpty || !$0.dueItems.isEmpty }
        return active.map { rows in
            let semester = CoachRows.semester(for: rows.course, day: today, in: data.semesters)
            let measures = CourseMeasures(rows: rows, semester: semester, rules: data.rules, now: now)
            let share = measures.plansHours ? (measures.budget?.weeklyShare(containing: today) ?? 0) : 0
            return StudyCourseLine(
                measures: measures,
                studied: studied[rows.course.id] ?? 0,
                share: share
            )
        }
    }

    /// Seen topics that are not solid, weakest first (by mastery, then next due; ≤ 6).
    private func weakestTopics(_ lines: [StudyCourseLine]) -> [WeakTopic] {
        var seen: Set<TopicKey> = []
        var candidates: [WeakTopic] = []
        for line in lines {
            let measures = line.measures
            let lectures = Dictionary(measures.rows.lectures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for topic in measures.rows.topics {
                guard let key = TopicKey(topic: topic), seen.insert(key).inserted else { continue }
                let mastery = measures.mastery(of: topic)
                guard mastery.seen, !mastery.isSolid else { continue }
                candidates.append(WeakTopic(
                    course: measures.rows.course, topic: topic, lecture: topic.lectureID.flatMap { lectures[$0] },
                    mastery: mastery, isDue: measures.isDue(mastery)
                ))
            }
        }
        // Plan §6.2 and mockup 13: every seen topic that is not solid, by mastery then next due.
        return candidates
            .sorted { TopicMastery.weakestFirst($0.mastery, $1.mastery) }
            .prefix(CoachRules.weakestLimit)
            .map { $0 }
    }
}

struct StudyCourseLine: Identifiable {
    let measures: CourseMeasures
    /// Seconds studied this week.
    let studied: Double
    /// The week's share of the budget, in seconds (0: none).
    let share: Double

    var id: Course.ID { measures.rows.course.id }
    var course: Course { measures.rows.course }

    /// Ready once a question of the course was answered (never for a seminar): "0%" for a course
    /// never practised says nothing.
    var ready: Double? {
        guard !measures.isSeminar, measures.mastery.values.contains(where: \.seen) else { return nil }
        return measures.ready
    }
}

struct WeakTopic: Identifiable {
    let course: Course
    let topic: Annotation
    let lecture: Lecture?
    let mastery: TopicMastery
    let isDue: Bool

    var id: Annotation.ID { topic.id }
}

// MARK: - Courses

/// Zone 2: the header with its two column labels, then a row per course.
private struct StudyCoursesZone: View {
    let lines: [StudyCourseLine]
    let now: Date

    @State private var hovered: Course.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Courses")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // A column's label only while some row has a value in it (the column keeps its room).
                Text("Ready")
                    .frame(width: 128, alignment: .trailing)
                    .opacity(lines.contains { $0.ready != nil } ? 1 : 0)
                Text("This week")
                    .frame(width: 150, alignment: .trailing)
                    .opacity(lines.contains { $0.share > 0 } ? 1 : 0)
            }
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            VStack(spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    if index > 0 {
                        Hairline()
                            .padding(.leading, 32)
                            .padding(.trailing, 10)
                            .opacity(hovered == line.id || hovered == lines[index - 1].id ? 0 : 1)
                    }
                    StudyCourseRow(line: line, now: now, isHovered: hovered == line.id)
                        .onHover { inside in
                            if inside { hovered = line.id } else if hovered == line.id { hovered = nil }
                        }
                }
            }
            .padding(.horizontal, -10)
        }
    }
}

private struct StudyCourseRow: View {
    let line: StudyCourseLine
    let now: Date
    let isHovered: Bool

    @Environment(\.openDestination) private var openDestination
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale

    var body: some View {
        Button {
            openDestination(.courseProgress(line.course.id))
        } label: {
            HStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    CourseDot(course: line.course, size: 9)
                        .frame(width: 10)
                        .padding(.top, 4.5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.course.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if let subline {
                            subline
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ready
                    .frame(width: 128, alignment: .trailing)
                week
                    .frame(width: 150, alignment: .trailing)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .rowHover(isHovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    /// "Exam Tue 9 Feb, 10:00"; a seminar's next gate.
    private var subline: Text? {
        let measures = line.measures
        if !measures.isSeminar, let exam = CoachText.examLine(measures.exams, locale: locale, timeZone: timeZone) {
            return exam
        }
        return measures.nextDue.map { CoachText.itemLine($0, locale: locale, timeZone: timeZone) }
    }

    @ViewBuilder
    private var ready: some View {
        if let share = line.ready {
            HStack(spacing: 8) {
                Text(verbatim: "\(Int((share * 100).rounded()))%")
                    .font(.mono(12.5))
                    .monospacedDigit()
                    .frame(minWidth: 34, alignment: .trailing)
                Meter(value: share, color: .course(line.course))
                    .frame(width: 72)
            }
        }
    }

    @ViewBuilder
    private var week: some View {
        if line.share > 0 {
            Text("\(DurationText.text(seconds: line.studied, step: 5).foregroundStyle(.primary).fontWeight(.medium)) of \(DurationText.text(seconds: line.share, step: 5))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Weakest topics

private struct WeakestTopicsZone: View {
    let topics: [WeakTopic]

    @State private var hovered: Annotation.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Weakest topics")
                .font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
                    if index > 0 {
                        Hairline()
                            .padding(.leading, 32)
                            .padding(.trailing, 10)
                            .opacity(hovered == topic.id || hovered == topics[index - 1].id ? 0 : 1)
                    }
                    WeakTopicRow(topic: topic, isHovered: hovered == topic.id)
                        .onHover { inside in
                            if inside { hovered = topic.id } else if hovered == topic.id { hovered = nil }
                        }
                }
            }
            .padding(.horizontal, -10)
        }
    }
}

private struct WeakTopicRow: View {
    let topic: WeakTopic
    let isHovered: Bool

    @Environment(\.openDestination) private var openDestination
    @Environment(\.studyCoach) private var coach

    var body: some View {
        HStack(spacing: 12) {
            CourseDot(course: topic.course, size: 9)
                .frame(width: 10)
            Text("\(CoachText.shortName(topic.course)) · \(topic.topic.body)")
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isHovered, let time = topic.topic.startTime {
                TimeChip(time, prefix: CoachText.lecturePrefix(topic.lecture), showsPlayGlyph: true) { open() }
            }
            MasteryDots(topic.mastery)
        }
        .frame(minHeight: 34)
        .padding(.horizontal, 10)
        .rowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .contextMenu {
            if coach != nil {
                Button("Practice This Topic") { practice() }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }

    /// The lecture at the slide and second the topic was explained.
    private func open() {
        guard let lectureID = topic.topic.lectureID else { return }
        openDestination(.lecture(
            lectureID, ReviewTarget(page: topic.topic.pageNumber, time: topic.topic.startTime, recordingID: topic.topic.recordingID)
        ))
    }

    private func practice() {
        guard let coach, let key = TopicKey(topic: topic.topic) else { return }
        let scope = StudyScope(kind: .topic, courseIDs: [topic.course.id], topic: key)
        let open = openDestination
        Task {
            do {
                let session = try await coach.startRound(scope)
                open(.practice(session))
            } catch {
                CoachUILog.ui.error("Practice This Topic failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
