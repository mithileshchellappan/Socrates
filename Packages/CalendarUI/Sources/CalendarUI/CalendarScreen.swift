import CalendarSync
import Courses
import StudyCore
import StudyUI
import SwiftUI

/// Calendar & deadlines (PRD #36, #37; mockup 06; docs/DESIGN.md §8.3): the week grid (Mon–Sun:
/// sessions, due lines and tags, all-day pills, waiting proposals, the composer's dashed parse,
/// other calendars read-only) and the inspector "Deadlines" (proposal cards, what is due from
/// today, the "New deadline" composer). Draws its own title, toolbar items and inspector.
///
/// Reads rows itself (one request per week); every effect goes through `\.deadlineActions`,
/// navigation through `\.openDestination`, other calendars through `\.foreignCalendars`,
/// checkboxes through `\.calendarVisibility`. The app also installs `CalendarCommands`.
public struct CalendarScreen: View {
    private let fixedNow: Date?

    @State private var week: CalendarWeek
    @State private var selection: CalendarSelection?
    @State private var composer: ComposerModel
    @State private var showsInspector = true
    @State private var gridWidth: CGFloat = 0
    @State private var scroll = ScrollPosition(y: GridMetrics.openingOffset)
    @State private var foreignList = ForeignCalendarList.empty
    @State private var foreignEvents: [ForeignEvent] = []
    @FocusState private var composerFocused: Bool

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

    /// - Parameters:
    ///   - week: a day of the week to open on; nil: this week.
    ///   - now: a fixed "now" (previews, snapshots); nil follows the clock.
    public init(week: CalendarDay? = nil, now: Date? = nil) {
        self.init(week: week, now: now, selection: nil, composerText: "")
    }

    /// Opens with an item or session selected and text in the composer (snapshots).
    init(week: CalendarDay?, now: Date?, selection: CalendarSelection?, composerText: String) {
        fixedNow = now
        let zone = TimeZone.current
        let today = CalendarDay(now ?? Date(), in: zone)
        let shown = CalendarWeek(containing: week ?? today)
        _week = State(initialValue: shown)
        _selection = State(initialValue: selection)
        _composer = State(initialValue: ComposerModel(text: composerText))
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
            foreignColors: Dictionary(foreignList.calendars.map { ($0.id, $0.colorHex) }, uniquingKeysWith: { first, _ in first }),
            preview: composer.shownPreview
        )
        let title = CalendarText.title(shown, locale: locale)
        let subtitle = CalendarText.subtitle(shown)
        return Group {
            switch chrome {
            case .window:
                grid(plan: plan, week: shown, now: now, today: today)
                    .screenTitle(title, subtitle: subtitle, leadingInset: ScreenTitleInset.firstItem)
                    .toolbar { toolbar }
                    .inspector(isPresented: $showsInspector) {
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
        .task(id: request) {
            // Another week, a new day or another time zone: one read per week.
            guard request != (loaded ?? initialRequest) else { return }
            loaded = request
            _ = try? await $data.load(request, database: database)
        }
        .task(id: ForeignKey(week: week, checked: visibility?.checkedCalendarIDs ?? [], hasSource: foreignSource != nil)) {
            await loadForeign()
        }
        .onChange(of: composer.text) { composer.textChanged(actions: actions, now: now) }
        .task {
            // Text given at open (snapshots) is parsed as typed text is.
            if composer.hasText { await composer.updatePreview(for: composer.text, actions: actions, now: now) }
        }
        .background {
            if let id = composer.conversationID {
                ConversationObserver(id: id) { composer.conversationChanged($0) }
            }
        }
    }

    /// Day headers, the all-day row, then the hours, scrolling, opened at 08:00.
    private func grid(plan: WeekPlan, week: CalendarWeek, now: Date, today: CalendarDay) -> some View {
        let columns = WeekColumns(width: gridWidth)
        let handlers = gridHandlers(now: now)
        let nowSlot = week.index(of: today).map { (day: $0, minute: WallClock.minute(of: now, in: timeZone)) }
        return VStack(spacing: 0) {
            WeekHeader(week: week, columns: columns, today: today)
            Hairline()
            AllDayRow(
                plan: plan, columns: columns, height: GridMetrics.allDayHeight(pills: plan.maxPills), selection: selection,
                handlers: handlers
            )
            Hairline()
            ScrollView(.vertical) {
                WeekBody(plan: plan, columns: columns, now: nowSlot, selection: selection, handlers: handlers)
            }
            .scrollPosition($scroll)
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        .background(Color.calendarContent)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard case .session(let id)? = selection, let event = plan.events.first(where: { $0.sessionID == id }) else {
                return .ignored
            }
            open(event)
            return .handled
        }
    }

    private func inspector(now: Date) -> some View {
        DeadlinesInspector(
            data: data, now: now, selection: selection, composer: composer, composerFocused: $composerFocused,
            handlers: inspectorHandlers(now: now)
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
        if !showsInspector {
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

    /// [+] and New Deadline: the composer takes focus (the inspector opens first when hidden).
    private func newDeadline() {
        let wasHidden = !showsInspector
        showsInspector = true
        if wasHidden {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                composerFocused = true
            }
        } else {
            composerFocused = true
        }
    }

    private func open(_ event: WeekPlan.Event) {
        if let lectureID = event.lectureID {
            openDestination(.lecture(lectureID))
        } else if let courseID = event.courseID {
            openDestination(.course(courseID))
        }
    }

    private func submit() {
        let composer = composer
        let actions = actions
        Task { await composer.submit(actions: actions, now: fixedNow ?? Date()) }
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

    /// The newest active source that put the item in the calendar on its own or changed it:
    /// what Undo takes back.
    private func undoSource(_ entries: [SourceTrailEntry]) -> TrackedItemSource.ID? {
        entries.last { $0.isActive && ($0.source.calendarAdded || $0.source.previous != nil) }?.id
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
        return GridHandlers(
            select: { selection = $0 },
            open: open,
            cancelSession: { id in perform("Cancelling a session") { try await actions.cancelSession(id) } },
            restoreSession: { id in perform("Restoring a session") { try await actions.restoreSession(id) } },
            trail: trail,
            now: now
        )
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
            trail: trail,
            submit: submit
        )
    }

    private var commandActions: CalendarActions {
        let proposal = targetProposal
        return CalendarActions(
            isEditingText: composerFocused || isSearchFieldFocused,
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

/// Follows the conversation the composer handed its text to; reports its state.
private struct ConversationObserver: View {
    let report: (ConversationState?) -> Void
    @FetchOne private var conversation: AgentConversation?

    init(id: AgentConversation.ID, report: @escaping (ConversationState?) -> Void) {
        self.report = report
        _conversation = FetchOne(AgentConversation.find(id))
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: conversation?.state, initial: true) { _, state in report(state) }
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
