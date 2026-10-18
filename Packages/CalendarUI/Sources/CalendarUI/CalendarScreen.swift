import CalendarSync
import Courses
import StudyCore
import StudyUI
import SwiftUI

/// Calendar & deadlines (PRD #36, #37; mockup 06; docs/DESIGN.md §8.3): the week grid (Mon–Sun:
/// sessions, due lines and tags, all-day pills, waiting proposals, other calendars read-only) and
/// the inspector "Deadlines" (proposal cards, what is due from today). Draws its own title,
/// toolbar items and inspector. ma: [+] opens the agent panel (`\.openAgentPanel`; the "New
/// deadline" composer is gone), the screen publishes its week and selection for it
/// (`.agentContext`), and the inspector yields to the expanded panel (`\.agentPanelExpanded`).
///
/// Reads rows itself (one request per week); every effect goes through `\.deadlineActions`,
/// navigation through `\.openDestination`, other calendars through `\.foreignCalendars`,
/// checkboxes through `\.calendarVisibility`. The app also installs `CalendarCommands`.
public struct CalendarScreen: View {
    private let fixedNow: Date?

    @State private var week: CalendarWeek
    @State private var selection: CalendarSelection?
    /// The grid item whose detail popover is open (a click opens it, Esc closes it).
    @State private var detailTarget: CalendarSelection?
    @State private var showsInspector = true
    @State private var gridWidth: CGFloat = 0
    @State private var scroll = ScrollPosition(y: GridMetrics.openingOffset)
    /// The body has been scrolled to the opening hour at its real height.
    @State private var isOpened = false
    @State private var foreignList = ForeignCalendarList.empty
    @State private var foreignEvents: [ForeignEvent] = []

    @Fetch private var data: CalendarData
    @State private var loaded: CalendarRequest?
    private let initialRequest: CalendarRequest

    @Dependency(\.defaultDatabase) private var database
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale
    @Environment(\.calendarChrome) private var chrome
    @Environment(\.deadlineActions) private var actions
    @Environment(\.openDestination) private var openDestination
    @Environment(\.foreignCalendars) private var foreignSource
    @Environment(\.calendarVisibility) private var visibility
    @Environment(\.isSearchFieldFocused) private var isSearchFieldFocused
    @Environment(\.calendarDetailPreview) private var detailPreview
    @Environment(\.openAgentPanel) private var openAgentPanel
    @Environment(\.agentPanelExpanded) private var agentPanelExpanded

    /// - Parameters:
    ///   - week: a day of the week to open on; nil: this week.
    ///   - now: a fixed "now" (previews, snapshots); nil follows the clock.
    public init(week: CalendarDay? = nil, now: Date? = nil) {
        self.init(week: week, now: now, selection: nil)
    }

    /// Opens with an item or session selected (snapshots).
    init(week: CalendarDay?, now: Date?, selection: CalendarSelection?) {
        fixedNow = now
        let zone = TimeZone.current
        let today = CalendarDay(now ?? Date(), in: zone)
        let shown = CalendarWeek(containing: week ?? today)
        _week = State(initialValue: shown)
        _selection = State(initialValue: selection)
        initialRequest = CalendarRequest(week: shown, today: today, timeZone: zone)
        _data = Fetch(wrappedValue: CalendarData(), initialRequest)
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

    // MARK: Layout

    private func content(now: Date) -> some View {
        let today = CalendarDay(now, in: timeZone)
        let request = CalendarRequest(week: week, today: today, timeZone: timeZone)
        // The week whose rows are loaded: the previous one stays up until the next one's land.
        let shown = data.week ?? week
        let plan = WeekPlan.make(
            data: data, week: shown, timeZone: timeZone,
            showsStudyPortal: visibility?.showsStudyPortal ?? true,
            foreignEvents: foreignEvents,
            foreignColors: Dictionary(foreignList.calendars.map { ($0.id, $0.colorHex) }, uniquingKeysWith: { first, _ in first })
        )
        let title = CalendarText.title(shown, locale: locale)
        let subtitle = CalendarText.subtitle(shown)
        return Group {
            switch chrome {
            case .window:
                grid(plan: plan, week: shown, now: now, today: today)
                    .screenTitle(title, subtitle: subtitle, leadingInset: ScreenTitleInset.firstItem)
                    .toolbar { toolbar }
                    .inspector(isPresented: inspectorShown) {
                        inspector(now: now)
                            .inspectorColumnWidth(min: 260, ideal: DeadlinesInspector.width, max: 440)
                    }
            case .snapshot:
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        SnapshotToolbar(title: title, subtitle: subtitle)
                        grid(plan: plan, week: shown, now: now, today: today)
                    }
                    Divider()
                    inspector(now: now)
                        .frame(width: DeadlinesInspector.width)
                }
            }
        }
        .focusedSceneValue(\.calendarScreen, commandActions)
        .agentContext(agentContext(week: shown))
        .task(id: request) {
            // Another week, a new day or another time zone: one read per week.
            guard request != (loaded ?? initialRequest) else { return }
            loaded = request
            _ = try? await $data.load(request, database: database)
        }
        .task(id: ForeignKey(week: week, checked: visibility?.checkedCalendarIDs ?? [], hasSource: foreignSource != nil)) {
            await loadForeign()
        }
    }

    /// What the agent panel knows of the screen: the week on screen, the selected item or session.
    private func agentContext(week: CalendarWeek) -> AgentContext {
        var context = AgentContext(screen: .calendar, week: week.monday)
        switch selection {
        case .item(let id)?: context.itemID = id
        case .session(let id)?: context.sessionID = id
        case nil: break
        }
        return context
    }

    /// The inspector shows unless hidden, or while the agent panel is expanded in its place.
    private var inspectorShown: Binding<Bool> {
        let expanded = agentPanelExpanded
        return Binding(
            get: { showsInspector && !expanded },
            set: { shown in if !expanded { showsInspector = shown } }
        )
    }

    /// Day headers, the all-day row, then the hours, scrolling, opened at 08:00.
    private func grid(plan: WeekPlan, week: CalendarWeek, now: Date, today: CalendarDay) -> some View {
        let columns = WeekColumns(width: gridWidth)
        let handlers = gridHandlers(now: now)
        let nowSlot = week.index(of: today).map { (day: $0, minute: WallClock.minute(of: now, in: timeZone)) }
        // Off-screen renders: the previewed item drawn selected, its detail inline.
        let previewTarget = detailPreview?.target(plan: plan, data: data)
        let shown = previewTarget ?? selection
        let allDayHeight = GridMetrics.allDayHeight(pills: plan.maxPills)
        return VStack(spacing: 0) {
            WeekHeader(week: week, columns: columns, today: today)
            Hairline()
            AllDayRow(
                plan: plan, columns: columns, height: allDayHeight, selection: shown,
                handlers: handlers
            )
            Hairline()
            ScrollView(.vertical) {
                WeekBody(plan: plan, columns: columns, now: nowSlot, selection: shown, handlers: handlers)
                    .overlay(alignment: .topLeading) {
                        if let previewTarget {
                            handlers.detail(previewTarget)
                                .modifier(DetailCard())
                                .offset(previewOffset(previewTarget, plan: plan, columns: columns))
                        }
                    }
            }
            .scrollPosition($scroll)
            // Never a legacy scroller: it would narrow the body under the day headers.
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
                // Opens at 08:00 once the body has its height: AppKit resets the offset when the
                // scroll view first grows, so a position set before that is lost.
                guard !isOpened, height > GridMetrics.hourHeight * 2 else { return }
                isOpened = true
                scroll.scrollTo(y: GridMetrics.openingOffset)
            }
        }
        // `minWidth: 0`: the rows are laid out at the measured width, which must not become the
        // window's minimum (the window would grow to fit it, the grid with it, without end).
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        .background(Color.contentBackground)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard let shown, let event = plan.events.first(where: { $0.target == shown }) else { return .ignored }
            open(event)
            return .handled
        }
        .onKeyPress(.escape) {
            guard detailTarget != nil else { return .ignored }
            detailTarget = nil
            return .handled
        }
    }

    private func inspector(now: Date) -> some View {
        DeadlinesInspector(
            data: data, now: now, selection: selection, handlers: inspectorHandlers(now: now), isShown: showsInspector && !agentPanelExpanded
        )
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Without the system title nothing pushes the items to the trailing edge.
        ToolbarSpacer(.flexible)
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Previous Week", systemImage: "chevron.left") { move(by: -1) }
                .help(Text("Previous Week"))
            Button("Today") { goToToday() }
            Button("Next Week", systemImage: "chevron.right") { move(by: 1) }
                .help(Text("Next Week"))
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button("New Deadline", systemImage: "plus", action: newDeadline)
                .help(Text("New Deadline"))
        }
        if !showsInspector, !agentPanelExpanded {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button("Show Inspector", systemImage: "sidebar.trailing") { showsInspector = true }
                    .help(Text("Show Inspector"))
            }
        }
    }

    // MARK: Actions

    private func move(by weeks: Int) {
        week = week.adding(weeks: weeks)
    }

    private func goToToday() {
        week = CalendarWeek(containing: CalendarDay(fixedNow ?? Date(), in: timeZone))
        scroll.scrollTo(y: GridMetrics.openingOffset)
    }

    /// [+] and New Deadline: the agent panel opens (compact, its composer focused).
    private func newDeadline() {
        openAgentPanel()
    }

    private func open(_ event: WeekPlan.Event) {
        if let lectureID = event.lectureID {
            openDestination(.lecture(lectureID))
        } else if let courseID = event.courseID {
            openDestination(.course(courseID))
        }
    }

    /// The proposal ⌘↩ / ⌘⌫ act on: the selected one (or the selected session's), else the first.
    private var targetProposal: TrackedItem.ID? {
        switch selection {
        case .item(let id)? where data.proposals.contains(where: { $0.id == id }):
            return id
        case .session(let id)?:
            if let proposal = data.proposals.first(where: { $0.lectureSessionID == id }) { return proposal.id }
        default:
            break
        }
        return data.proposals.first?.id
    }

    private func confirm(_ id: TrackedItem.ID) {
        let actions = actions
        perform("Confirming a proposal") { try await actions.confirmProposal(id) }
    }

    private func discard(_ id: TrackedItem.ID) {
        let actions = actions
        perform("Discarding a proposal") { try await actions.discardProposal(id) }
    }

    /// The newest active source that put the item in the calendar on its own or changed it (ma: or
    /// whose change the agent applied on its own, a session change): what Undo takes back.
    private func undoSource(_ entries: [SourceTrailEntry]) -> TrackedItemSource.ID? {
        entries.last {
            $0.isActive && ($0.source.calendarAdded || $0.source.previous != nil || data.appliedSources.contains($0.id))
        }?.id
    }

    private func trail(_ itemID: TrackedItem.ID) -> TrailInfo {
        let entries = data.trails[itemID] ?? []
        let item = data.item[itemID]
        let details = item?.details.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let undo: (@MainActor @Sendable () -> Void)? = undoSource(entries).map { sourceID in
            let actions = actions
            return { perform("Undo") { try await actions.undo(sourceID) } }
        }
        return TrailInfo(
            entries: entries, header: details.isEmpty ? nil : details, inCalendar: item?.inCalendar ?? false, undo: undo
        )
    }

    private func gridHandlers(now: Date) -> GridHandlers {
        let actions = actions
        let data = data
        let details = detailHandlers()
        return GridHandlers(
            select: { target in
                selection = target
                detailTarget = target
            },
            open: open,
            cancelSession: { id in perform("Cancelling a session") { try await actions.cancelSession(id) } },
            restoreSession: { id in perform("Restoring a session") { try await actions.restoreSession(id) } },
            remove: { id in perform("Delete") { try await actions.remove(id) } },
            addToCalendar: { id in perform("Add to Calendar") { try await actions.addToCalendar(id) } },
            trail: trail,
            detailTarget: detailTarget,
            closeDetail: { target in
                if detailTarget == target { detailTarget = nil }
            },
            detail: { target in CalendarDetail(target: target, data: data, now: now, handlers: details) },
            now: now
        )
    }

    private func detailHandlers() -> DetailHandlers {
        let actions = actions
        return DetailHandlers(
            openLecture: { id in openDestination(.lecture(id)) },
            openCourse: { id in openDestination(.course(id)) },
            cancelSession: { id in perform("Cancelling a session") { try await actions.cancelSession(id) } },
            restoreSession: { id in perform("Restoring a session") { try await actions.restoreSession(id) } },
            confirm: confirm,
            discard: discard,
            complete: { id in perform("Mark as Done") { try await actions.complete(id) } },
            remove: { id in perform("Delete") { try await actions.remove(id) } },
            addToCalendar: { id in perform("Add to Calendar") { try await actions.addToCalendar(id) } },
            trail: trail,
            selectItem: { item in
                detailTarget = nil
                selection = .item(item.id)
                if let due = item.dueAt { week = CalendarWeek(containing: CalendarDay(due, in: timeZone)) }
            }
        )
    }

    /// Where a render's inline detail sits in the scrolling body: beside its item, where the
    /// popover opens (to its left from Wednesday on), kept in view of the body opened at 08:00.
    private func previewOffset(_ target: CalendarSelection, plan: WeekPlan, columns: WeekColumns) -> CGSize {
        var day = 0
        var top = GridMetrics.openingOffset
        if let event = plan.events.first(where: { $0.target == target }) {
            day = event.day
            top = GridMetrics.y(minute: event.startMinute)
        } else if case .item(let id) = target, let due = plan.dues.first(where: { $0.id == id }) {
            day = due.day
            top = GridMetrics.y(minute: due.minute)
        } else if case .item(let id) = target, let pill = plan.pills.first(where: { $0.itemID == id }) {
            day = pill.day
        }
        let x = day >= 2 ? columns.x(day) - CalendarDetail.width - 12 : columns.x(day) + columns.width(day) + 12
        let y = min(max(GridMetrics.openingOffset + 8, top - 30), GridMetrics.openingOffset + 220)
        return CGSize(width: max(GridMetrics.gutter, x), height: y)
    }

    private func inspectorHandlers(now: Date) -> InspectorHandlers {
        let actions = actions
        return InspectorHandlers(
            select: { item in
                selection = .item(item.id)
                // The grid follows to the item's week.
                if let due = item.dueAt { week = CalendarWeek(containing: CalendarDay(due, in: timeZone)) }
            },
            confirm: confirm,
            discard: discard,
            complete: { id in perform("Mark as Done") { try await actions.complete(id) } },
            addToCalendar: { id in perform("Add to Calendar") { try await actions.addToCalendar(id) } },
            remove: { id in perform("Delete") { try await actions.remove(id) } },
            trail: trail
        )
    }

    private var commandActions: CalendarActions {
        let proposal = targetProposal
        return CalendarActions(
            isEditingText: isSearchFieldFocused,
            hasProposal: proposal != nil,
            goToToday: goToToday,
            previousWeek: { move(by: -1) },
            nextWeek: { move(by: 1) },
            confirm: { if let proposal { confirm(proposal) } },
            discard: { if let proposal { discard(proposal) } },
            newDeadline: newDeadline
        )
    }

    // MARK: Other calendars

    private struct ForeignKey: Hashable {
        var week: CalendarWeek
        var checked: Set<String>
        var hasSource: Bool
    }

    private func loadForeign() async {
        guard let foreignSource else {
            foreignList = .empty
            foreignEvents = []
            return
        }
        foreignList = await foreignSource.foreignCalendars()
        let checked = foreignList.calendars.map(\.id).filter { visibility?.isChecked($0) ?? false }
        guard !checked.isEmpty else {
            foreignEvents = []
            return
        }
        foreignEvents = await foreignSource.foreignEvents(
            calendarIDs: checked, from: week.start(in: timeZone), to: week.end(in: timeZone)
        )
    }
}

/// The toolbar of the snapshot layout: the title and the same groups, drawn inline (off-screen
/// rendering has no window toolbar).
private struct SnapshotToolbar: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 2) {
                glyph("chevron.left")
                Text("Today")
                    .font(.system(size: 13))
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                glyph("chevron.right")
            }
            .padding(3)
            .modifier(SnapshotCapsule())
            glyph("plus")
                .padding(3)
                .modifier(SnapshotCapsule())
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(height: 52)
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .medium))
            .frame(width: 32, height: 28)
    }
}

/// A toolbar group's capsule in the snapshot layout.
private struct SnapshotCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
    }
}
