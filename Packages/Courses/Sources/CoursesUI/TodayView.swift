import CalendarSync
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
            // The mockup's small play triangle (about 7 pt tall).
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
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
                // The mockup's rhythm: eyebrow, title and meta 27 pt apart.
                .padding(.top, 3)
                .padding(.bottom, 4)
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
            .padding(.top, 14)
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
                // The mockup's rhythm: eyebrow, title and meta 27 pt apart.
                .padding(.top, 3)
                .padding(.bottom, 4)
            meta
                .font(.callout)
                .foregroundStyle(.secondary)
            if let record {
                Button(action: record) {
                    HeroButtonLabel(title: String(localized: "Record"), systemImage: "circle.fill")
                }
                .heroButtonStyle()
                .keyboardShortcut(.defaultAction)
                .padding(.top, 14)
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
