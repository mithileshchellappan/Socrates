import CalendarSync
import CoachUI
import Courses
import StudyCore
import StudyUI
import SwiftUI

/// Today (mockup 01): one first thing — the newest lecture to review, else the next class —
/// then Coming up, one dated list of the week's sessions (not the weekly lectures) and the
/// deadlines and events of the next three weeks, followed by the open tasks and the mail that
/// needs a reply (M3.5), and the unread mail as one counting line.
public struct TodayView: View {
    private let fixedNow: Date?
    private let record: (() -> Void)?

    @Fetch private var data: TodayData
    @State private var loaded: TodayRequest?
    private let initialRequest: TodayRequest
    @Dependency(\.defaultDatabase) private var database
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale
    @Environment(\.openDestination) private var openDestination
    /// M7: the iPhone's layout (mockup 16) at a compact width; the Mac's is unchanged.
    @PhoneLayout private var isPhone

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
        Group {
            if let fixedNow {
                content(now: fixedNow)
            } else {
                TimelineView(.everyMinute) { context in
                    content(now: context.date)
                }
            }
        }
        // ma: the agent panel's context ("Ask about today").
        .agentContext(.today)
    }

    private func content(now: Date) -> some View {
        let today = CalendarDay(now, in: timeZone)
        let plan = TodayPlan(data: data, now: now, timeZone: timeZone)
        let text = SessionText(locale: locale, timeZone: timeZone)
        return Group {
            if isPhone {
                phoneLayout(now: now, plan: plan, text: text)
            } else {
                macLayout(now: now, plan: plan, text: text)
            }
        }
        .task(id: TodayRequest(day: today, timeZone: timeZone)) {
            // A new day (or another time zone) needs a new window of sessions.
            let request = TodayRequest(day: today, timeZone: timeZone)
            guard request != (loaded ?? initialRequest) else { return }
            loaded = request
            _ = try? await $data.load(request, database: database)
        }
    }

    private func macLayout(now: Date, plan: TodayPlan, text: SessionText) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                hero(now: now, plan: plan, text: text)

                if !plan.comingUp.isEmpty {
                    ComingUpSection(entries: plan.comingUp, courses: data.courses, now: now, text: text)
                }

                if let mail = plan.mail {
                    TodayMailLine(line: mail, courses: data.courses)
                }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.top, 26)
            .padding(.bottom, 16)
            .padding(.horizontal, 20)
        }
        .overlay {
            if plan.isEmpty {
                ContentUnavailableView {
                    Image(systemName: "sun.max")
                }
            }
        }
        .screenTitle(String(localized: "Today"), subtitle: subtitle(now: now, plan: plan, text: text))
    }

    /// M7, the iPhone (mockup 16 with DESIGN 8.1 and section 4): the date line over the large
    /// title "Today" (the navigation bar's large title; "Today" inline once scrolled), the hero
    /// card with Start under the thumb, Coming up as a card of phone rows, the mail line.
    private func phoneLayout(now: Date, plan: TodayPlan, text: SessionText) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(now: now, plan: plan, text: text)

                if !plan.comingUp.isEmpty {
                    ComingUpSection(entries: plan.comingUp, courses: data.courses, now: now, text: text, isPhone: true)
                        .padding(.top, plan.hero == nil ? 0 : 18)
                }

                if let mail = plan.mail {
                    TodayMailLine(line: mail, courses: data.courses, isPhone: true)
                        .padding(.top, 18)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .padding(.horizontal, 16)
        }
        .overlay {
            if plan.isEmpty {
                ContentUnavailableView {
                    Image(systemName: "sun.max")
                }
            }
        }
        .navigationTitle(String(localized: "Today"))
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .largeTitle) {
                PhoneTodayTitle(line: phoneDateLine(now: now, plan: plan))
            }
        }
        #endif
    }

    @ViewBuilder
    private func hero(now: Date, plan: TodayPlan, text: SessionText) -> some View {
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
        case .plan:
            // mc: the plan's first open block (mockups 11–12, 16), the card Study shares.
            if let day = data.plan {
                PlanHero(plan: day, courses: data.courses, now: now)
            }
        case nil:
            EmptyView()
        }
    }

    /// The iPhone's date line: "Friday 23 October · 25 min planned" (the digits in SF Mono), or
    /// "· no classes" as the Mac's subtitle says it.
    private func phoneDateLine(now: Date, plan: TodayPlan) -> Text {
        let date = Text(verbatim: now.formatted(Date.VerbatimFormatStyle(
            format: "\(weekday: .wide) \(day: .defaultDigits) \(month: .wide)",
            locale: locale, timeZone: timeZone, calendar: Calendar(identifier: .gregorian)
        )))
        if let planned = plan.plannedMinutes {
            return Text("\(date) · \(DurationText.text(minutes: planned)) planned")
        }
        return plan.hasClassesToday ? date : Text("\(date) · no classes")
    }

    private func subtitle(now: Date, plan: TodayPlan, text: SessionText) -> String {
        let date = text.fullDate(now)
        // mc: with a plan, its total ("Tuesday, 20 October 2026 · 5 h 15 min planned").
        if let planned = plan.plannedMinutes {
            return String(localized: "\(date) · \(DurationText.string(minutes: planned)) planned")
        }
        return plan.hasClassesToday ? date : String(localized: "\(date) · no classes")
    }
}

// MARK: - Hero

// The hero card, its button label and style are CoachUI's (`HeroCard`, `HeroButtonLabel`,
// `heroButtonStyle()`), shared with the coach's screens.

/// The iPhone's large title (mockup 16 `.t-top`): the date line (13 semibold, secondary, in
/// capitals) over "Today" (34 bold).
private struct PhoneTodayTitle: View {
    let line: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            line
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.26)
                .lineLimit(1)
            Text("Today")
                .font(.largeTitle.bold())
                .tracking(-0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct Eyebrow: View {
    let course: Course?
    var detail: String?
    var isPhone = false

    var body: some View {
        HStack(spacing: 6) {
            CourseDot(course: course, size: isPhone ? 8 : 7)
            Text(course?.name ?? "")
                .foregroundStyle(.secondary)
            if let detail {
                Text("· \(detail)")
                    .fontWeight(.regular)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(isPhone ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
        .lineLimit(1)
    }
}

/// The hero's title: 22 semibold on the Mac, 26 bold on the iPhone (mockup 16 `.hero h3`).
private struct HeroTitle: View {
    let title: String
    let isPhone: Bool

    var body: some View {
        if isPhone {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.5)
                .padding(.top, 2)
                .padding(.bottom, 1)
        } else {
            Text(title)
                .font(.title.weight(.semibold))
                .tracking(-0.3)
                // The mockup's rhythm: eyebrow, title and meta 27 pt apart.
                .padding(.top, 3)
                .padding(.bottom, 4)
        }
    }
}

/// "Review Lecture 2 before Monday" with the one filled button.
private struct ReviewHero: View {
    let review: ReviewCandidate
    let course: Course?
    let next: LectureSession?
    let now: Date
    let text: SessionText
    let start: () -> Void

    @PhoneLayout private var isPhone

    var body: some View {
        HeroCard {
            Eyebrow(course: course, detail: review.recordedAt.map { String(localized: "recorded \(text.day($0))") }, isPhone: isPhone)
            HeroTitle(title: title, isPhone: isPhone)
            meta
                .font(isPhone ? .subheadline : .callout)
                .foregroundStyle(.secondary)
            if let studyLine {
                // M4: the study pass's one line, with the screen's only sparkle.
                Text("\(Text(Image(systemName: "sparkle")).font(.system(size: isPhone ? 12 : 10.5)).foregroundStyle(Color.ai)) \(studyLine)")
                    .font(isPhone ? .subheadline : .callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // The mockup's rhythm: meta and this line about 20 pt apart.
                    .padding(.top, isPhone ? 0 : 3)
                    .accessibilityLabel(Text(studyLine))
            }
            if isPhone {
                // M7: Start under the thumb, the next lecture centred under it.
                PhoneHeroButton(title: String(localized: "Start review"), systemImage: "play.fill", action: start)
                    .padding(.top, 8)
                if let aside {
                    aside
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            } else {
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
                .padding(.top, 14)
            }
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

    /// "5 highlights, 3 not on the slides" (M4): the professor's items and what was only said in
    /// class, hidden ones left out; a part that is zero is left out, and nothing shows before the
    /// study pass wrote rows.
    private var studyLine: String? {
        var parts: [String] = []
        switch review.highlights {
        case 0: break
        case 1: parts.append(String(localized: "1 highlight"))
        default: parts.append(String(localized: "\(review.highlights) highlights"))
        }
        if review.notOnSlides > 0 {
            parts.append(String(localized: "\(review.notOnSlides) not on the slides"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
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

    @PhoneLayout private var isPhone

    var body: some View {
        HeroCard {
            Eyebrow(course: course, isPhone: isPhone)
            HeroTitle(title: title, isPhone: isPhone)
            meta
                .font(isPhone ? .subheadline : .callout)
                .foregroundStyle(.secondary)
            if let record {
                if isPhone {
                    PhoneHeroButton(title: String(localized: "Record"), systemImage: "circle.fill", action: record)
                        .padding(.top, 8)
                } else {
                    Button(action: record) {
                        HeroButtonLabel(title: String(localized: "Record"), systemImage: "circle.fill")
                    }
                    .heroButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 14)
                }
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
