import CalendarSync
import Courses
import StudyCore
import StudyUI
import SwiftUI

/// Today (mockup 01, light): one first thing — the newest lecture to review, else the next
/// class — and the next seven days' sessions other than the weekly lectures in one dated list.
public struct TodayView: View {
    private let fixedNow: Date?
    private let record: (() -> Void)?

    @Fetch private var data: TodayData
    @State private var loaded: TodayRequest?
    private let initialRequest: TodayRequest
    @Dependency(\.defaultDatabase) private var database
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale
    @Environment(\.studyServices) private var services
    @Environment(\.calendarMirror) private var mirror
    @Environment(\.openDestination) private var openDestination

    /// - Parameters:
    ///   - now: a fixed "now" (previews, snapshots); nil follows the clock.
    ///   - record: starts a live capture; offered when a recorded course's class is about to begin.
    public init(now: Date? = nil, record: (() -> Void)? = nil) {
        fixedNow = now
        self.record = record
        let zone = TimeZone.current
        initialRequest = TodayRequest(day: CalendarDay(now ?? Date(), in: zone), timeZone: zone)
        _data = Fetch(wrappedValue: TodayData(), initialRequest)
    }

    public var body: some View {
        if let fixedNow {
            content(now: fixedNow)
        } else {
            TimelineView(.everyMinute) { context in
                content(now: context.date)
            }
        }
    }

    private func content(now: Date) -> some View {
        let today = CalendarDay(now, in: timeZone)
        let plan = TodayPlan(data: data, now: now, timeZone: timeZone)
        let text = SessionText(locale: locale, timeZone: timeZone)
        return ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                switch plan.hero {
                case .review(let review):
                    ReviewHero(review: review, course: data.courses[review.lecture.courseID], next: plan.nextLecture, now: now, text: text) {
                        openDestination(.lecture(review.lecture.id, ReviewTarget(time: review.lecture.reviewPosition)))
                    }
                case .session(let session):
                    SessionHero(
                        session: session, course: data.courses[session.courseID], now: now, text: text,
                        record: plan.canRecord(session, courses: data.courses, now: now) ? record : nil
                    )
                case nil:
                    EmptyView()
                }

                if !plan.comingUp.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Coming up")
                            .font(.title3.weight(.semibold))
                        VStack(spacing: 0) {
                            ForEach(Array(plan.comingUp.enumerated()), id: \.element.id) { index, session in
                                if index > 0 {
                                    // From the title's leading edge to the column's trailing edge.
                                    Divider()
                                        .padding(.leading, 32)
                                        .padding(.trailing, 10)
                                }
                                ComingUpRow(session: session, course: data.courses[session.courseID], text: text)
                                    .contextMenu {
                                        if session.isCancelled {
                                            Button("Restore Session") { actions.restore(session.id) }
                                        } else {
                                            Button("Cancel Session") { actions.cancel(session.id) }
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, -10)
                    }
                }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.top, 26)
            .padding(.bottom, 16)
            .padding(.horizontal, 20)
        }
        .overlay {
            if plan.hero == nil, plan.comingUp.isEmpty {
                ContentUnavailableView {
                    Image(systemName: "sun.max")
                }
            }
        }
        .screenTitle(String(localized: "Today"), subtitle: subtitle(now: now, plan: plan, text: text))
        .task(id: TodayRequest(day: today, timeZone: timeZone)) {
            // A new day (or another time zone) needs a new window of sessions.
            let request = TodayRequest(day: today, timeZone: timeZone)
            guard request != (loaded ?? initialRequest) else { return }
            loaded = request
            _ = try? await $data.load(request, database: database)
        }
    }

    private func subtitle(now: Date, plan: TodayPlan, text: SessionText) -> String {
        let date = text.fullDate(now)
        return plan.hasClassesToday ? date : String(localized: "\(date) · no classes")
    }

    private var actions: ScheduleActions { ScheduleActions(services: services, mirror: mirror) }
}

/// What Today puts where, for one moment.
struct TodayPlan: Equatable {
    enum Hero: Equatable {
        case review(ReviewCandidate)
        case session(LectureSession)
    }

    var hero: Hero?
    /// The review course's next lecture (the hero's aside).
    var nextLecture: LectureSession?
    var comingUp: [LectureSession]
    var hasClassesToday: Bool

    /// A class this close lets the hero offer Record.
    static let recordLead: TimeInterval = 30 * 60

    init(data: TodayData, now: Date, timeZone: TimeZone) {
        let today = CalendarDay(now, in: timeZone)
        let horizon = today.adding(days: 8).start(in: timeZone)
        let known = data.sessions.filter { data.courses[$0.courseID] != nil }
        hasClassesToday = known.contains { !$0.isCancelled && CalendarDay($0.startsAt, in: timeZone) == today }

        var shown: Set<LectureSession.ID> = []
        if let review = data.review {
            hero = .review(review)
            nextLecture = data.nextLectures.first { $0.startsAt > now }
            if let nextLecture { shown.insert(nextLecture.id) }
        } else if let next = known.first(where: { !$0.isCancelled && $0.endsAt > now }) {
            hero = .session(next)
            shown.insert(next.id)
        }
        // Everything but the weekly lectures (mockup 01): exercises, tutorials, seminars and
        // one-off sessions; a cancelled lecture stays, struck through, so it can be restored.
        comingUp = known.filter {
            $0.endsAt > now && $0.startsAt < horizon && !shown.contains($0.id) && ($0.kind != .lecture || $0.isCancelled)
        }
    }

    func canRecord(_ session: LectureSession, courses: [Course.ID: Course], now: Date) -> Bool {
        guard let course = courses[session.courseID], course.recordsLectures, !session.isCancelled else { return false }
        return session.startsAt.addingTimeInterval(-Self.recordLead) <= now && now < session.endsAt
    }
}

// MARK: - Hero

private struct HeroCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            content
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }
}

/// The hero's one filled button (mockup 01 `.btn.primary.lg`): accent, 32 pt tall (the large
/// control's 28 pt plus 2 pt above and below the title), corner radius 9, a 13 pt medium title
/// after a small glyph.
private struct HeroButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
                .fontWeight(.medium)
        } icon: {
            Image(systemName: systemImage)
                .imageScale(.small)
        }
        .padding(.vertical, 2)
    }
}

private extension View {
    func heroButtonStyle() -> some View {
        buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 9))
            .controlSize(.large)
    }
}

private struct Eyebrow: View {
    let course: Course?
    var detail: String?

    var body: some View {
        HStack(spacing: 6) {
            CourseDot(course: course, size: 7)
            Text(course?.name ?? "")
                .foregroundStyle(.secondary)
            if let detail {
                Text("· \(detail)")
                    .fontWeight(.regular)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
    }
}

/// "Review Lecture 2 before Wednesday" with the one filled button.
private struct ReviewHero: View {
    let review: ReviewCandidate
    let course: Course?
    let next: LectureSession?
    let now: Date
    let text: SessionText
    let start: () -> Void

    var body: some View {
        HeroCard {
            Eyebrow(course: course, detail: review.recordedAt.map { String(localized: "recorded \(text.day($0))") })
            Text(title)
                .font(.title.weight(.semibold))
                .tracking(-0.3)
                .padding(.top, 2)
                .padding(.bottom, 3)
            meta
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Button(action: start) {
                    HeroButtonLabel(title: String(localized: "Start review"), systemImage: "play.fill")
                }
                .heroButtonStyle()
                .keyboardShortcut(.defaultAction)
                if let aside {
                    aside
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.top, 11)
        }
    }

    private var name: String {
        if let number = review.lecture.number { return String(localized: "Lecture \(number)") }
        return review.lecture.title.isEmpty ? String(localized: "the lecture") : review.lecture.title
    }

    private var title: String {
        if let next, next.startsAt.timeIntervalSince(now) <= 7 * 86_400 {
            return String(localized: "Review \(name) before \(text.weekday(next.startsAt))")
        }
        return String(localized: "Review \(name)")
    }

    private var meta: Text {
        var parts: [Text] = []
        if !review.lecture.title.isEmpty, review.lecture.number != nil {
            parts.append(Text(review.lecture.title))
        }
        if let duration = review.duration {
            parts.append(Text(TimeText.clock(duration)).monospaced())
        }
        if let first = review.firstPage, let last = review.lastPage {
            let range = first == last ? "\(first)" : "\(first)–\(last)"
            if let count = review.pageCount {
                parts.append(Text("slides \(range) of \(count)"))
            } else {
                parts.append(Text("slides \(range)"))
            }
        }
        guard var line = parts.first else { return Text(verbatim: "") }
        for part in parts.dropFirst() {
            line = Text("\(line) · \(part)")
        }
        return line
    }

    private var aside: Text? {
        guard let next else { return nil }
        let lecture = next.number.map { String(localized: "Lecture \($0)") } ?? String(localized: "The next lecture")
        let time = Text(text.time(next.startsAt)).monospaced()
        let room = next.room.trimmingCharacters(in: .whitespacesAndNewlines)
        if room.isEmpty {
            return Text("\(lecture) is \(text.day(next.startsAt)) at \(time)")
        }
        return Text("\(lecture) is \(text.day(next.startsAt)) at \(time), \(room)")
    }
}

/// The next class; Record appears when a recorded course's class is about to begin.
private struct SessionHero: View {
    let session: LectureSession
    let course: Course?
    let now: Date
    let text: SessionText
    let record: (() -> Void)?

    var body: some View {
        HeroCard {
            Eyebrow(course: course)
            Text(title)
                .font(.title.weight(.semibold))
                .tracking(-0.3)
                .padding(.top, 2)
                .padding(.bottom, 3)
            meta
                .font(.callout)
                .foregroundStyle(.secondary)
            if let record {
                Button(action: record) {
                    HeroButtonLabel(title: String(localized: "Record"), systemImage: "circle.fill")
                }
                .heroButtonStyle()
                .keyboardShortcut(.defaultAction)
                .padding(.top, 11)
            }
        }
    }

    private var name: String {
        if session.kind == .lecture, let number = session.number { return String(localized: "Lecture \(number)") }
        return session.kind.displayName
    }

    private var title: String {
        let today = CalendarDay(now, in: text.timeZone)
        let day = CalendarDay(session.startsAt, in: text.timeZone)
        switch today.days(to: day) {
        case ...0: return String(localized: "\(name) today")
        case 1: return String(localized: "\(name) tomorrow")
        case 2...6: return String(localized: "\(name) on \(text.weekday(session.startsAt))")
        default: return String(localized: "\(name) on \(text.day(session.startsAt))")
        }
    }

    private var meta: Text {
        let times = Text(text.timeRange(session.startsAt, session.endsAt)).monospaced()
        let room = session.room.trimmingCharacters(in: .whitespacesAndNewlines)
        return room.isEmpty ? times : Text("\(times) · \(room)")
    }
}

// MARK: - Coming up

private struct ComingUpRow: View {
    let session: LectureSession
    let course: Course?
    let text: SessionText

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.course(course))
                .frame(width: 4)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 2)
                .frame(width: 10)
            Text(SessionText.title(of: session, courseName: course?.name ?? ""))
                .fontWeight(.medium)
                .frame(minHeight: 18)
                .strikethrough(session.isCancelled)
                .foregroundStyle(session.isCancelled ? .tertiary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(text.day(session.startsAt))
                    .frame(minHeight: 18)
                Text(text.timeRange(session.startsAt, session.endsAt))
                    .font(.system(.callout, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 16)
            }
            .strikethrough(session.isCancelled)
            .foregroundStyle(session.isCancelled ? .tertiary : .primary)
            .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(course?.name ?? ""), \(SessionText.title(of: session, courseName: course?.name ?? "")), \(text.day(session.startsAt)), \(text.timeRange(session.startsAt, session.endsAt))"))
    }
}
