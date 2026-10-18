import StudyCore
import StudyUI
import SwiftUI

/// One day of the plan as the hero reads it (Today and Study): the day's blocks in order, the items
/// they are for (the eyebrow's "due …", the exam-admission star) and their source trails.
public struct PlanDay: Hashable, Sendable {
    public var day: CalendarDay
    public var blocks: [StudyBlock] = []
    public var items: [TrackedItem.ID: TrackedItem] = [:]
    public var trails: [TrackedItem.ID: [SourceTrailEntry]] = [:]

    public init(day: CalendarDay) {
        self.day = day
    }

    /// Reads `day`'s blocks (one indexed read) and their items, inside a `FetchKeyRequest`.
    public static func fetch(_ db: Database, day: CalendarDay) throws -> PlanDay {
        var plan = PlanDay(day: day)
        plan.blocks = try StudyBlock
            .where { $0.day.eq(day) }
            .order { ($0.sortOrder, $0.createdAt) }
            .fetchAll(db)
        let itemIDs = Array(Set(plan.blocks.compactMap(\.trackedItemID)))
        if !itemIDs.isEmpty {
            let items = try TrackedItem.where { $0.id.in(itemIDs) }.fetchAll(db)
            plan.items = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            plan.trails = try TrackedItemRepository.trails(itemIDs: itemIDs, in: db)
        }
        return plan
    }

    /// The day has a plan (Today's hero and subtitle switch to it).
    public var hasBlocks: Bool { !blocks.isEmpty }

    /// The first block not done (planned or started): Today's hero, Study's zone 1.
    public var current: StudyBlock? { blocks.first { $0.state.isOpen } }

    /// The open block after the current one (the hero's "Then …").
    public var next: StudyBlock? {
        guard let current, let index = blocks.firstIndex(where: { $0.id == current.id }) else { return nil }
        return blocks[blocks.index(after: index)...].first { $0.state.isOpen }
    }

    /// The day's planned minutes, done blocks included (Today's "5 h 15 min planned").
    public var plannedMinutes: Int {
        blocks.filter { $0.state != .skipped }.reduce(0) { $0 + $1.minutes }
    }

    /// The item the current block is for (Today leaves it out of Coming up).
    public var currentItemID: TrackedItem.ID? { current?.trackedItemID }
}

/// The card Today and Study share (mockups 11–13): the plan's current block. Eyebrow: the course
/// dot and name (a round: its courses' dots and names, "Data Centers · CL"; an item: "· due
/// Wed 21 Oct, 23:59" in tertiary; on an away day the `tram` leads); the title; the meta (the
/// block's scope, its length in SF Mono digits, then the star + "Exam admission" with the item's
/// source glyph, or the block's grey why); Start (filled, ↩) opens what the block opens; beside it
/// "Then Lecture 2 · slides 13–21 · 1 h 30 min". Without the coach Start is not offered.
public struct PlanHero: View {
    private let plan: PlanDay
    private let courses: [Course.ID: Course]
    private let now: Date

    @Environment(\.studyCoach) private var coach
    @Environment(\.openDestination) private var openDestination
    @Environment(\.openURL) private var openURL
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale
    @State private var examSheet: SheetCourse?
    @State private var isStarting = false

    public init(plan: PlanDay, courses: [Course.ID: Course], now: Date) {
        self.plan = plan
        self.courses = courses
        self.now = now
    }

    public var body: some View {
        if let block = plan.current {
            card(block)
                .sheet(item: $examSheet) { course in
                    PracticeExamSheet(courseID: course.id, now: now)
                }
        }
    }

    private func card(_ block: StudyBlock) -> some View {
        let item = block.trackedItemID.flatMap { plan.items[$0] }
        return HeroCard {
            eyebrow(block, item: item)
            Text(block.title)
                .font(.title.weight(.semibold))
                .tracking(-0.3)
                .lineLimit(2)
                // The mockup's rhythm: eyebrow, title and meta 27 pt apart (as Today's hero).
                .padding(.top, 3)
                .padding(.bottom, 4)
            meta(block, item: item)
                .font(.callout)
                .foregroundStyle(.secondary)
            if coach != nil || plan.next != nil {
                HStack(spacing: 14) {
                    if coach != nil {
                        Button {
                            start(block)
                        } label: {
                            HeroButtonLabel(title: String(localized: "Start"), systemImage: "play.fill")
                        }
                        .heroButtonStyle()
                        .keyboardShortcut(.defaultAction)
                        .disabled(isStarting)
                    }
                    if let next = plan.next {
                        PlanHero.then(next)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 14)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Eyebrow

    private func eyebrow(_ block: StudyBlock, item: TrackedItem?) -> some View {
        let ids = block.courses
        return HStack(spacing: 6) {
            if block.isAway {
                Image(systemName: "tram")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            ForEach(Array(ids.enumerated()), id: \.offset) { index, id in
                if index > 0 {
                    Text(verbatim: "·")
                }
                CourseDot(course: courses[id], size: 7)
                Text(ids.count > 1 ? CoachText.shortName(courses[id]) : (courses[id]?.name ?? ""))
            }
            if let item, let due = item.dueAt {
                Text("· due \(CoachText.dayTime(due, allDay: item.isAllDay, locale: locale, timeZone: timeZone))")
                    .fontWeight(.regular)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    // MARK: Meta

    @ViewBuilder
    private func meta(_ block: StudyBlock, item: TrackedItem?) -> some View {
        let admission = item?.relevance == .examAdmission
        let why = block.why.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(spacing: 5) {
            PlanHero.scope(block, why: admission ? "" : why, trailingSeparator: admission)
                .lineLimit(1)
            if admission, let item {
                Image(systemName: "star")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.professor)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text("Exam admission")
                    .lineLimit(1)
                SourceTrailButton(entries: plan.trails[item.id] ?? [], now: now, inCalendar: item.inCalendar)
            }
        }
    }

    /// "slides 13–21 · 1 h 30 min · embeddings, which the CL slides assume" (digits in SF Mono).
    static func scope(_ block: StudyBlock, why: String, trailingSeparator: Bool) -> Text {
        let detail = block.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let length = DurationText.text(minutes: block.minutes)
        var line = detail.isEmpty ? length : Text("\(detail) · \(length)")
        if !why.isEmpty { line = Text("\(line) · \(why)") }
        if trailingSeparator { line = Text("\(line) ·") }
        return line
    }

    /// "Then Lecture 2 · slides 13–21 · 1 h 30 min", "Then read J&M §4.9 · 15 min".
    static func then(_ next: StudyBlock) -> Text {
        let detail = next.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = next.kind == .read ? String(localized: "read \(next.title)") : next.title
        let what = detail.isEmpty ? name : "\(name) · \(detail)"
        let separator = Text(verbatim: " · ").foregroundStyle(.tertiary)
        return Text("Then \(what)\(separator)\(DurationText.text(minutes: next.minutes))")
    }

    // MARK: Start

    private func start(_ block: StudyBlock) {
        guard let coach, !isStarting else { return }
        isStarting = true
        let router = CoachRouter(openDestination: openDestination, openURL: openURL)
        let items = plan.items
        let trails = plan.trails
        Task {
            defer { isStarting = false }
            do {
                let target = try await coach.start(block: block.id)
                if let course = router.route(target, items: items, trails: trails) {
                    examSheet = SheetCourse(id: course)
                }
            } catch {
                CoachUILog.ui.error("Start failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
