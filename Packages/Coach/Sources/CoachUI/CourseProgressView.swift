import StudyCore
import StudyUI
import SwiftUI

/// A course's Progress (mockup 14; the course row `chart.bar` between Notes and Course Settings).
/// Two zones in a 760 pt column: the hero (the exam, its room and the second date in the eyebrow;
/// two figures, Ready and the hours of the self-study budget, with meters; Practice, filled, with
/// what the round would ask; in the runway the filled button (↩) becomes "Practice exam", a plain
/// button rather than a menu, that opens the sheet with the last settings beside it), then Topics and reading by lecture, newest first: its topics weakest
/// first with their dots and slides, then its readings with their length. A lecture that needs
/// nothing now is a closed group with its count.
public struct CourseProgressView: View {
    private let courseID: Course.ID
    private let fixedNow: Date?

    @Fetch private var data: ProgressData
    @State private var loaded: ProgressRequest?
    private let initialRequest: ProgressRequest
    @Dependency(\.defaultDatabase) private var database
    @Environment(\.timeZone) private var timeZone

    /// - Parameter now: a fixed "now" (renders); nil follows the clock.
    public init(courseID: Course.ID, now: Date? = nil) {
        self.courseID = courseID
        fixedNow = now
        let zone = TimeZone.current
        let request = ProgressRequest(courseID: courseID, day: CalendarDay(now ?? Date(), in: zone), timeZone: zone)
        initialRequest = request
        _data = Fetch(wrappedValue: ProgressData(), request)
    }

    public var body: some View {
        Group {
            if let fixedNow {
                ProgressContent(data: data, now: fixedNow)
            } else {
                TimelineView(.everyMinute) { context in
                    ProgressContent(data: data, now: context.date)
                }
            }
        }
        .agentContext(AgentContext(screen: .course, courseID: courseID, courseScreen: "progress"))
        .task(id: request) {
            guard request != (loaded ?? initialRequest) else { return }
            loaded = request
            _ = try? await $data.load(request, database: database)
        }
    }

    private var request: ProgressRequest {
        ProgressRequest(courseID: courseID, day: CalendarDay(fixedNow ?? Date(), in: timeZone), timeZone: timeZone)
    }
}

// MARK: - Rows

struct ProgressData: Hashable, Sendable {
    var rows: CourseRows?
    var semesters: [Semester] = []
    var rules = PlanRules.none
    var readings: [StudyReading] = []
    /// Every answer of the course and every done block (studied time over the term).
    var answers: [StudyAnswer] = []
    var doneBlocks: [StudyBlock] = []
    /// The course's practice exams, newest first.
    var exams: [StudySession] = []
}

struct ProgressRequest: FetchKeyRequest {
    let courseID: Course.ID
    let day: CalendarDay
    let timeZone: TimeZone

    func fetch(_ db: Database) throws -> ProgressData {
        var data = ProgressData()
        guard let course = try Course.find(courseID).fetchOne(db) else { return data }
        data.rows = try CoachRows.course(course, from: day.start(in: timeZone), db)
        data.semesters = try Semester.all.fetchAll(db)
        data.rules = try CoachRows.rules(db)
        let courseID = courseID
        data.readings = try StudyReading
            .where { $0.courseID.eq(courseID) && $0.hiddenAt.is(nil) }
            .order { ($0.sortOrder, $0.createdAt) }
            .fetchAll(db)
        data.answers = try StudyAnswer.where { $0.courseID.eq(courseID) }.fetchAll(db)
        data.doneBlocks = try StudyBlock.where { $0.state.eq(StudyBlockState.done) }.fetchAll(db)
        let owner = Course.ID?.some(courseID)
        data.exams = try StudySession
            .where { $0.kind.eq(StudySessionKind.exam) && $0.courseID.eq(owner) }
            .order { $0.createdAt.desc() }
            .fetchAll(db)
        return data
    }
}

// MARK: - Screen

private struct ProgressContent: View {
    let data: ProgressData
    let now: Date

    @Environment(\.timeZone) private var timeZone

    var body: some View {
        if let rows = data.rows {
            let today = CalendarDay(now, in: timeZone)
            let semester = CoachRows.semester(for: rows.course, day: today, in: data.semesters)
            let measures = CourseMeasures(rows: rows, semester: semester, rules: data.rules, now: now)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ProgressHero(measures: measures, studied: studied(rows.course.id), exams: data.exams, now: now)
                    TopicsAndReading(measures: measures, readings: data.readings)
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.top, 22)
                .padding(.bottom, 16)
                .padding(.horizontal, 22)
            }
            .screenTitle(String(localized: "Progress"), subtitle: rows.course.name)
        } else {
            ContentUnavailableView {
                Image(systemName: "chart.bar")
            }
            .screenTitle(String(localized: "Progress"))
        }
    }

    /// Seconds studied for the course over the whole term (`StudyTime`).
    private func studied(_ courseID: Course.ID) -> Double {
        let days = CalendarDay(year: 1970, month: 1, day: 1)...CalendarDay(year: 9999, month: 12, day: 31)
        return StudyTime.studied(answers: data.answers, blocks: data.doneBlocks, in: Date.distantPast..<Date.distantFuture, days: days)[courseID] ?? 0
    }
}

// MARK: - Hero

private struct ProgressHero: View {
    let measures: CourseMeasures
    let studied: Double
    let exams: [StudySession]
    let now: Date

    @Environment(\.studyCoach) private var coach
    @Environment(\.openDestination) private var openDestination
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale
    @State private var roundPreview: StudyRoundPreview?
    @State private var examPreview: StudyExamPreview?
    @State private var sheet: SheetCourse?
    @State private var isStarting = false

    private var course: Course { measures.rows.course }

    var body: some View {
        HeroCard(spacing: 12, top: 16, bottom: 20) {
            eyebrow
            HStack(alignment: .top, spacing: 34) {
                StatFigure(
                    value: CoachFigure.percent(measures.ready ?? 0),
                    caption: Text("ready"),
                    meter: (measures.ready ?? 0, Color.course(course))
                )
                if let budget = measures.budget, budget.totalHours > 0 {
                    StatFigure(
                        value: CoachFigure.duration(minutes: studiedMinutes),
                        caption: Text("of \(DurationText.text(minutes: Int((budget.totalHours * 60).rounded()))) self-study"),
                        meter: (studied / (budget.totalHours * 3_600), Color.secondary)
                    )
                }
            }
            actions
                .padding(.top, 2)
        }
        .sheet(item: $sheet) { course in
            PracticeExamSheet(courseID: course.id, now: now)
        }
        .task(id: PreviewKey(courseID: course.id, questions: measures.rows.questions.count, runway: isRunway, exams: exams.count)) {
            await loadPreview()
        }
    }

    // MARK: Eyebrow

    @ViewBuilder
    private var eyebrow: some View {
        let exams = measures.exams
        if !measures.isSeminar, let sat = exams.sitsSecondDate ? exams.second : exams.first, let due = sat.dueAt {
            HStack(spacing: 6) {
                primary(sat, due: due, second: exams.sitsSecondDate)
                if !exams.sitsSecondDate, let second = exams.second, let secondDue = second.dueAt {
                    Text("· Second date \(DayText.day(secondDue, locale: locale, timeZone: timeZone))")
                        .fontWeight(.regular)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else if let item = measures.nextDue {
            CoachText.itemLine(item, locale: locale, timeZone: timeZone)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// "Exam Tue 9 Feb, 10:00 · Hall A" (+ the form once announced: "Written, 90 min").
    private func primary(_ exam: TrackedItem, due: Date, second: Bool) -> Text {
        let when = CoachText.dayTime(due, allDay: exam.isAllDay, locale: locale, timeZone: timeZone)
        var line = second ? Text("Second date \(when)") : Text("Exam \(when)")
        let room = exam.room?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !room.isEmpty { line = Text("\(line) · \(room)") }
        if let form = examForm { line = Text("\(line) · \(form)") }
        return line
    }

    private var examForm: Text? {
        guard let rule = course.rules.first(where: { $0.kind == .examForm && $0.examForm != nil && $0.examForm != .seminar }),
              let form = rule.examForm
        else { return nil }
        let name = form == .oral ? String(localized: "Oral") : String(localized: "Written")
        guard let minutes = rule.minutes else { return Text(verbatim: name) }
        return Text("\(name), \(DurationText.text(minutes: minutes))")
    }

    /// Whole hours once the figure is large ("81 h"); 5-minute steps below ("2 h 10 min").
    private var studiedMinutes: Int {
        let minutes = DurationText.minutes(studied, step: 5)
        return minutes >= 600 ? Int((Double(minutes) / 60).rounded()) * 60 : minutes
    }

    private var isRunway: Bool {
        !measures.isSeminar && measures.budget?.isRunway(CalendarDay(now, in: timeZone)) == true
    }

    private var openExam: StudySession? { exams.first { $0.state.isOpen } }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        if coach != nil {
            HStack(spacing: 14) {
                if let openExam {
                    Button {
                        openDestination(.practice(openExam.id))
                    } label: {
                        HeroButtonLabel(title: String(localized: "Resume practice exam"), systemImage: "play.fill")
                    }
                    .heroButtonStyle()
                    .keyboardShortcut(.defaultAction)
                } else if isRunway {
                    Button {
                        sheet = SheetCourse(id: course.id)
                    } label: {
                        HeroButtonLabel(title: String(localized: "Practice exam"), systemImage: "play.fill")
                    }
                    .heroButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    if let aside = examAside {
                        aside
                    }
                } else {
                    Button {
                        practice()
                    } label: {
                        HeroButtonLabel(title: String(localized: "Practice"), systemImage: "play.fill")
                    }
                    .heroButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(isStarting)
                    if let roundPreview, roundPreview.questions > 0 {
                        aside(questions: roundPreview.questions, length: DurationText.text(minutes: roundPreview.minutes))
                    }
                }
            }
        }
    }

    /// The last practice exam's settings ("8 questions · 90 min"), else what the sheet would start.
    private var examAside: Text? {
        if let last = exams.first {
            return aside(questions: last.questionIDs.count, length: last.minutes.map { ExamLength.text(minutes: $0) } ?? Text("Untimed"))
        }
        guard let examPreview, examPreview.questions > 0 else { return nil }
        return aside(questions: examPreview.questions, length: examPreview.minutes.map { ExamLength.text(minutes: $0) } ?? Text("Untimed"))
    }

    private func aside(questions: Int, length: Text) -> Text {
        let separator = Text(verbatim: " · ").foregroundStyle(.tertiary)
        return Text("\(CoachText.questions(questions))\(separator)\(length)")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private struct PreviewKey: Hashable {
        var courseID: Course.ID
        var questions: Int
        var runway: Bool
        var exams: Int
    }

    private func loadPreview() async {
        guard let coach else { return }
        do {
            if isRunway {
                guard exams.isEmpty else { return }
                let minutes = course.rules.first { $0.kind == .examForm }?.minutes ?? UniversityProfile.current.defaultExamMinutes
                examPreview = try await coach.previewExam(
                    course: course.id, source: StudyScope(kind: .allLectures, courseIDs: [course.id]), minutes: minutes
                )
            } else {
                roundPreview = try await coach.previewRound(.course(course.id))
            }
        } catch {
            CoachUILog.ui.error("Preview failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func practice() {
        guard let coach, !isStarting else { return }
        isStarting = true
        let courseID = course.id
        let open = openDestination
        Task {
            defer { isStarting = false }
            do {
                let session = try await coach.startRound(.course(courseID))
                open(.practice(session))
            } catch {
                CoachUILog.ui.error("Practice failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Topics and reading

private struct LectureGroup: Identifiable {
    let lecture: Lecture
    let topics: [(topic: Annotation, mastery: TopicMastery)]
    let readings: [StudyReading]
    let isOpenByDefault: Bool

    var id: Lecture.ID { lecture.id }
}

private struct TopicsAndReading: View {
    let measures: CourseMeasures
    let readings: [StudyReading]

    /// Groups the student opened or closed (their default flipped).
    @State private var flipped: Set<Lecture.ID> = []
    @State private var hovered: UUID?

    var body: some View {
        let groups = self.groups
        let loose = readings.filter { $0.lectureID == nil }
        if !groups.isEmpty || !loose.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Topics and reading")
                    .font(.title3.weight(.semibold))
                    .padding(.bottom, 4)
                ForEach(groups) { group in
                    let isOpen = group.isOpenByDefault != flipped.contains(group.id)
                    GroupHead(lecture: group.lecture, isOpen: isOpen, showsChevron: !group.isOpenByDefault || flipped.contains(group.id), count: group.topics.count) {
                        if flipped.contains(group.id) { flipped.remove(group.id) } else { flipped.insert(group.id) }
                    }
                    .padding(.top, isOpen ? 0 : 4)
                    if isOpen {
                        rows(topics: group.topics, readings: group.readings, lecture: group.lecture)
                    }
                }
                if !loose.isEmpty {
                    rows(topics: [], readings: loose, lecture: nil)
                        .padding(.top, 8)
                }
            }
        }
    }

    private func rows(topics: [(topic: Annotation, mastery: TopicMastery)], readings: [StudyReading], lecture: Lecture?) -> some View {
        let ids: [UUID] = topics.map(\.topic.id) + readings.map(\.id)
        return VStack(spacing: 0) {
            ForEach(Array(topics.enumerated()), id: \.element.topic.id) { index, entry in
                separator(before: entry.topic.id, in: ids, index: index)
                TopicRow(
                    topic: entry.topic, mastery: entry.mastery, course: measures.rows.course,
                    reading: self.readings.first { $0.topicKey != nil && $0.topicKey == TopicKey(topic: entry.topic) },
                    isHovered: hovered == entry.topic.id
                )
                .onHover { inside in hover(entry.topic.id, inside) }
            }
            ForEach(Array(readings.enumerated()), id: \.element.id) { index, reading in
                separator(before: reading.id, in: ids, index: topics.count + index)
                ReadingRow(reading: reading, lectures: measures.rows.lectures, isHovered: hovered == reading.id)
                    .onHover { inside in hover(reading.id, inside) }
            }
        }
        .padding(.horizontal, -10)
    }

    @ViewBuilder
    private func separator(before id: UUID, in ids: [UUID], index: Int) -> some View {
        if index > 0 {
            Hairline()
                .padding(.leading, 54)
                .padding(.trailing, 10)
                .opacity(hovered == id || hovered == ids[index - 1] ? 0 : 1)
        }
    }

    private func hover(_ id: UUID, _ inside: Bool) {
        if inside { hovered = id } else if hovered == id { hovered = nil }
    }

    /// Lectures with topics or readings, newest first; topics weakest first (unseen last), then
    /// the readings, unread first. A group opens by default for the newest lecture, a topic that
    /// is new or due again, or a reading not read yet.
    private var groups: [LectureGroup] {
        let lectures = measures.rows.lectures.sorted { lhs, rhs in
            let left = lhs.heldAt ?? lhs.createdAt
            let right = rhs.heldAt ?? rhs.createdAt
            if left != right { return left > right }
            return (lhs.number ?? 0) > (rhs.number ?? 0)
        }
        var seen: Set<TopicKey> = []
        var groups: [LectureGroup] = []
        for lecture in lectures {
            let topics = measures.rows.topics
                .filter { $0.lectureID == lecture.id }
                .filter { topic in TopicKey(topic: topic).map { seen.insert($0).inserted } ?? false }
                .map { (topic: $0, mastery: measures.mastery(of: $0)) }
            let sorted = topics.enumerated().sorted { lhs, rhs in
                let left = lhs.element.mastery
                let right = rhs.element.mastery
                if TopicMastery.weakestFirst(left, right) { return true }
                if TopicMastery.weakestFirst(right, left) { return false }
                return lhs.offset < rhs.offset
            }.map(\.element)
            let lectureReadings = readings
                .filter { $0.lectureID == lecture.id }
                .sorted { ($0.doneAt == nil ? 0 : 1, $0.sortOrder) < ($1.doneAt == nil ? 0 : 1, $1.sortOrder) }
            guard !sorted.isEmpty || !lectureReadings.isEmpty else { continue }
            let needsWork = sorted.contains { !$0.mastery.seen || measures.isDue($0.mastery) }
                || lectureReadings.contains { $0.doneAt == nil }
            groups.append(LectureGroup(lecture: lecture, topics: sorted, readings: lectureReadings, isOpenByDefault: groups.isEmpty || needsWork))
        }
        return groups
    }
}

/// "L2 · Virtualization Basics  Tue 13 Oct" over a hairline; closed: a chevron first and the
/// count at the end.
private struct GroupHead: View {
    let lecture: Lecture
    let isOpen: Bool
    let showsChevron: Bool
    let count: Int
    let toggle: () -> Void

    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                if showsChevron {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                }
                Text(title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if let held = lecture.heldAt {
                    Text(DayText.day(held, locale: locale, timeZone: timeZone))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if !isOpen {
                    Text(verbatim: "\(count)")
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) {
                if isOpen { Hairline() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
    }

    private var title: String {
        let name = lecture.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = lecture.number else { return name }
        return name.isEmpty ? "L\(number)" : "L\(number) · \(name)"
    }
}

/// [dots | topic | "Slides 15–16"]; hover: the time chip; a click opens the lecture at the second.
private struct TopicRow: View {
    let topic: Annotation
    let mastery: TopicMastery
    let course: Course
    let reading: StudyReading?
    let isHovered: Bool

    @Environment(\.openDestination) private var openDestination
    @Environment(\.openURL) private var openURL
    @Environment(\.studyCoach) private var coach

    var body: some View {
        HStack(spacing: 10) {
            MasteryDots(mastery)
                .frame(width: 34, alignment: .leading)
            Text(topic.body)
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if isHovered, let time = topic.startTime {
                    TimeChip(time, showsPlayGlyph: true) { open() }
                }
                if let slides = CoachText.slides(topic.pageNumber, topic.lastPage) {
                    Text(slides)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
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
            if let reading, let url = reading.url {
                Button {
                    openURL(url)
                } label: {
                    Text("Read \(reading.section.isEmpty ? reading.title : reading.section) · \(DurationText.string(minutes: reading.minutes))")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }

    private func open() {
        guard let lectureID = topic.lectureID else { return }
        openDestination(.lecture(lectureID, ReviewTarget(page: topic.pageNumber, time: topic.startTime)))
    }

    private func practice() {
        guard let coach, let key = TopicKey(topic: topic) else { return }
        let scope = StudyScope(kind: .topic, courseIDs: [course.id], topic: key)
        let open = openDestination
        Task {
            do {
                open(.practice(try await coach.startRound(scope)))
            } catch {
                CoachUILog.ui.error("Practice This Topic failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// [book | title + source glyph | "Slides 5–21" | "1 h 15 min"]; a click opens it.
private struct ReadingRow: View {
    let reading: StudyReading
    let lectures: [Lecture]
    let isHovered: Bool

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "book")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .leading)
                .accessibilityHidden(true)
            HStack(spacing: 5) {
                Text(reading.title)
                    .fontWeight(.medium)
                    .foregroundStyle(reading.doneAt == nil ? .primary : .secondary)
                    .lineLimit(1)
                ReadingSourceButton(reading: reading, lectures: lectures, highlighted: isHovered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let slides = CoachText.slides(reading.firstPage, reading.lastPage) {
                Text(slides)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            DurationText.text(minutes: reading.minutes)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 76, alignment: .trailing)
        }
        .frame(minHeight: 34)
        .padding(.horizontal, 10)
        .rowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = reading.url { openURL(url) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A reading's faint source glyph(s) (`globe` a web page, `display` a slide, `waveform` the
/// lecture, `envelope` a mail) with its trail in a popover on hover (tap on iOS): the byline, then
/// each source with its quote.
private struct ReadingSourceButton: View {
    let reading: StudyReading
    let lectures: [Lecture]
    let highlighted: Bool

    @State private var isPresented = false
    @State private var overGlyph = false
    @State private var overPopover = false
    @State private var pending: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let symbols = self.symbols
        if !symbols.isEmpty {
            HStack(spacing: 2) {
                ForEach(symbols, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 11.5))
                        .frame(width: 14, height: 14)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .foregroundStyle(highlighted || isPresented ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .background(highlighted || isPresented ? Color.accentSoft(colorScheme) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { isPresented.toggle() }
            #if os(macOS)
            .onHover { inside in
                overGlyph = inside
                settle()
            }
            #endif
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                popover
                    #if os(macOS)
                    .onHover { inside in
                        overPopover = inside
                        settle()
                    }
                    #endif
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Sources"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isPresented.toggle() }
        }
    }

    private var symbols: [String] {
        var symbols: [String] = []
        for source in reading.sources {
            let symbol = Self.symbol(source.kind)
            if !symbols.contains(symbol) { symbols.append(symbol) }
        }
        return symbols
    }

    static func symbol(_ kind: SourceRef.Kind) -> String {
        switch kind {
        case .web: "globe"
        case .slide: "display"
        case .transcript: "waveform"
        case .mail: "envelope"
        default: "doc.text"
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 8) {
            let byline = reading.byline.trimmingCharacters(in: .whitespacesAndNewlines)
            if !byline.isEmpty {
                Text(byline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(reading.sources.enumerated()), id: \.offset) { _, source in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: Self.symbol(source.kind))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        name(source)
                            .font(.system(size: 12.5, weight: .medium))
                        if let quote = source.quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty {
                            Text(verbatim: SourceTrailText.quote(quote))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else if let host = source.url?.host() {
                            Text(verbatim: host)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 264, alignment: .leading)
    }

    /// "Lecture 2 · 2:05", "Slide 12", the page's title.
    private func name(_ source: SourceRef) -> Text {
        switch source.kind {
        case .transcript:
            let number = source.lectureID.flatMap { id in lectures.first { $0.id == id }?.number }
            let lecture = number.map { String(localized: "Lecture \($0)") } ?? String(localized: "Lecture")
            guard let time = source.time else { return Text(verbatim: lecture) }
            return Text("\(lecture) · \(Text(verbatim: TimeText.clock(time)).monospaced())")
        default:
            if let title = source.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return Text(verbatim: title) }
            if let page = source.pageNumber { return Text("Slide \(page)") }
            return Text(verbatim: source.url?.host() ?? reading.title)
        }
    }

    private func settle() {
        pending?.cancel()
        let wanted = overGlyph || overPopover
        guard wanted != isPresented else { return }
        pending = Task { @MainActor in
            try? await Task.sleep(for: wanted ? .milliseconds(350) : .milliseconds(250))
            guard !Task.isCancelled else { return }
            isPresented = wanted
        }
    }
}
