import CalendarSync
import CalendarUI
import CaptureUI
import ChatUI
import CoursesUI
import FilingUI
import MailUI
import Processing
import SearchUI
import StudyCore
import StudyUI
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    #endif
    /// The Settings window's tab ("Set Up Mail…" opens Accounts).
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.semester
    @State private var selection: SidebarItem?
    /// The message selected on Mail (in Drafts, the draft).
    @State private var mailSelection: MailMessage.ID?
    /// `open(.mail(scope, message:))` chose the message along with the list: keep it.
    @State private var keepsMailSelection = false
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var query = ""
    /// Back and Forward (Go menu; the course screen's toolbar chevrons, mockup 08).
    @State private var history = ScreenHistory()
    /// Where the review screen opened from a search hit or Today's hero goes: one request, for
    /// that opening only (the sidebar going elsewhere drops it, so a later visit resumes where
    /// review left off).
    @State private var reviewTarget: (lectureID: Lecture.ID, target: ReviewTarget)?
    @FocusState private var searchFocused: Bool
    /// ↩ in the search field: the search screen opens its selected (or first) hit.
    @State private var searchSubmits = 0
    /// The chat inspector (Today, Mail: the mail chat; a course's screens, Search: the tutor),
    /// kept per window.
    @SceneStorage("chat.shown") private var showsChat = false

    init(
        selection: SidebarItem? = .today,
        query: String = "",
        reviewTarget: (lectureID: Lecture.ID, target: ReviewTarget)? = nil,
        mailSelection: MailMessage.ID? = nil,
        showsChat: Bool = false
    ) {
        _selection = State(initialValue: selection?.screen)
        _query = State(initialValue: query)
        _reviewTarget = State(initialValue: reviewTarget)
        _mailSelection = State(initialValue: mailSelection)
        _showsChat = SceneStorage(wrappedValue: showsChat, "chat.shown")
    }

    var body: some View {
        @Bindable var model = model
        if let launchError = model.launchError {
            ContentUnavailableView(
                "Library unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(launchError)
            )
        } else if let center = model.filingCenter {
            splitView(center: center)
                .environment(\.isSearchFieldFocused, searchFocused)
                .focusedSceneValue(\.sidebarSelection, $selection)
                .focusedSceneValue(\.focusSearch) {
                    let hadField = showsSearchField
                    selection = .search
                    searchFocused = true
                    if !hadField {
                        // The field comes back with the Search screen: focus it once it is there.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(80))
                            searchFocused = true
                        }
                    }
                }
                .focusedSceneValue(\.screenHistory, ScreenHistoryActions(
                    canGoBack: history.canGoBack,
                    canGoForward: history.canGoForward,
                    back: { go(back: true) },
                    forward: { go(back: false) }
                ))
                .smartImport(center)
                .timetableImport(center: center)
                .environment(\.openDestination, OpenDestinationAction(open))
                .environment(\.studyServices, model.services)
                .environment(\.calendarMirror, model.calendarMirror)
                .environment(\.mailActions, mailActions)
                .environment(\.deadlineActions, model.deadlineActions)
                // The chat and the tutor: absent until Claude Code is available.
                .environment(\.chatActions, model.chatActions)
                // Search's planner ("Also searched") and on-device meaning search (Mac only).
                .environment(\.searchProviders, SearchProviders(planner: model.queryPlanner, semantic: model.semanticIndex))
                // Calendar: the student's other calendars, read-only (Mac only, like the mirror).
                .environment(\.foreignCalendars, model.calendarMirror.map { $0 as any ForeignCalendarSource })
                .environment(\.calendarVisibility, model.calendarVisibility)
                .onOpenURL(perform: openURL)
                .sheet(item: $model.sheet) { sheet in
                    switch sheet {
                    case .newCapture:
                        CaptureSetupView()
                    case .newCourse:
                        NewCourseView { course in selection = .courseSettings(course.id) }
                            .environment(\.studyServices, model.services)
                    }
                }
                .alert(
                    "Couldn’t finish",
                    isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
                    presenting: model.failure
                ) { _ in
                    Button("OK") {}
                } message: { message in
                    Text(message)
                }
                #if os(iOS)
                .fullScreenCover(isPresented: $model.isLivePresented, onDismiss: { model.closeLiveLecture() }) {
                    NavigationStack {
                        LiveLectureScreen()
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button(role: .close) { model.isLivePresented = false }
                                }
                            }
                    }
                    .environment(model)
                }
                #endif
                .background { CalendarSessionsWatcher() }
                .background { CalendarItemsWatcher() }
                .background { ChatFailureWatcher() }
                #if os(macOS)
                .background { MainWindowReader() }
                #endif
        }
    }

    /// The sidebar and the screen, with the window's search field.
    private func splitView(center: FilingCenter) -> some View {
        NavigationSplitView(columnVisibility: $columns) {
            // A course's row shows its settings, selected as the course's "Course Settings"
            // row (mockup 08).
            SidebarView(selection: Binding(get: { selection }, set: { selection = $0?.screen }), center: center)
                #if os(macOS)
                // The toggle is the content toolbar's (`sidebarToggle`), as in mockups 01 and
                // 10. Removing the system one drops the sidebar's column width: set it again.
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 200, ideal: SidebarView.idealWidth, max: 320)
                #endif
        } detail: {
            NavigationStack {
                DetailView(
                    item: selection ?? .today,
                    query: query,
                    searchSubmits: searchSubmits,
                    target: reviewTarget,
                    mailSelection: $mailSelection,
                    showsChat: $showsChat,
                    record: record
                )
                #if os(iOS)
                // The search field (mockups 01, 07), not on a lecture or a course (03, 08: the
                // slide stepper and inspector header, Import, own the toolbar there; ⌘F still
                // searches). Here, not on the split view: there it shows on every screen. (The Mac
                // draws its own field in `trailingItems`.)
                .modifier(SearchFieldModifier(isShown: showsSearchField, prompt: searchPrompt, text: $query, focused: $searchFocused, submit: submitSearch))
                #endif
                #if os(macOS)
                .toolbar {
                    sidebarToggle
                    historyButtons
                }
                #endif
            }
            // A new stack per screen; the top-level screens share one, so the search field (and
            // its focus while typing on Today opens Search) stays.
            .id(selection.map(DetailIdentity.init) ?? .topLevel)
            .toolbar { trailingItems(center: center) }
        }
        .onChange(of: query) { _, text in
            // Typing on Mail filters the mail list ("Search mail"); elsewhere it opens Search.
            guard selection?.isMail != true else { return }
            if !text.trimmingCharacters(in: .whitespaces).isEmpty, selection != .search { selection = .search }
        }
        .onChange(of: selection) { old, item in
            history.visit(from: old, to: item)
            // Mail's search and the library's are different questions: entering or leaving Mail
            // starts with an empty field.
            if (old?.isMail == true) != (item?.isMail == true), !query.isEmpty { query = "" }
            // Another list starts with nothing selected (a Drafts selection is a draft's id),
            // unless the message was asked for with the list.
            if keepsMailSelection {
                keepsMailSelection = false
            } else if item?.isMail == true, old != item {
                mailSelection = nil
            }
            // The target was for the lecture `open` showed; anywhere else drops it.
            if case .lecture(let id) = item, id == reviewTarget?.lectureID { return }
            reviewTarget = nil
        }
    }

    private var isToday: Bool { (selection ?? .today) == .today }

    /// "Search mail" on Mail (mockup 05), the whole library elsewhere (mockup 01).
    private var searchPrompt: LocalizedStringKey {
        selection?.isMail == true ? "Search mail" : "Search lectures, notes, mail"
    }

    /// The Mail screen's actions with "Set Up Mail…" opening Settings on its Accounts tab.
    private var mailActions: MailActions {
        var actions = model.mailActions
        #if os(macOS)
        let openSettings = openSettings
        let settingsTab = $settingsTab
        actions.openAccountSettings = {
            settingsTab.wrappedValue = .accounts
            openSettings()
        }
        #endif
        return actions
    }

    /// The toolbar search field shows on the top-level screens, not on a lecture or a course, and
    /// not on Calendar (mockup 06: its own toolbar; ⌘F still opens Search).
    private var showsSearchField: Bool {
        let item = selection ?? .today
        return item.isTopLevel && item != .calendar
    }

    /// ↩ in the search field: the Search screen opens its selected (or first) hit. (On Mail the
    /// list filters as the student types.)
    private func submitSearch() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, selection?.isMail != true else { return }
        selection = .search
        searchSubmits += 1
    }

    /// Back or Forward through the screens this window showed.
    private func go(back: Bool) {
        guard let item = history.step(back: back, from: selection) else { return }
        selection = item
    }

    /// The content toolbar's trailing end (mockups 01, 10): [search] [● Record] […], each in its
    /// own glass. The search field shows on the top-level screens (not on a lecture or a course,
    /// mockups 03 and 08, where ⌘F still opens Search). Record is Today's while idle (File ▸ New
    /// Lecture Capture, ⇧⌘N, starts one from anywhere); a running recording shows on every screen,
    /// so it is never forgotten, and brings the live screen back.
    @ToolbarContentBuilder
    private func trailingItems(center: FilingCenter) -> some ToolbarContent {
        if showsSearchField {
            // The top-level screens' titles are toolbar items (`screenTitle`), not the flexible
            // system title: this keeps the field, Record and More at the trailing end.
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
        #if os(macOS)
        if showsSearchField {
            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField(text: $query, prompt: searchPrompt, focused: $searchFocused, submit: submitSearch)
            }
        }
        #endif
        if let session = model.live?.session, session.isCapturing, session.startedAt != nil {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button(action: record) {
                    RecordingIndicator(session: session)
                }
            }
        } else if isToday {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button(action: record) {
                    Label {
                        Text("Record")
                    } icon: {
                        Image(systemName: "circle.fill")
                            .imageScale(.small)
                    }
                }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.red)
            }
        }
        if isToday {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                // A plain view around the menu: the toolbar then keeps the glyph's room (a Menu
                // item alone is drawn as the system's near-circle).
                HStack(spacing: 0) {
                    Menu {
                        Button("Import…") { center.importFiles() }
                        Button("New Course…") { model.sheet = .newCourse }
                    } label: {
                        ToolbarGlyph("More", systemImage: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                }
                .frame(width: ToolbarGlyph.pillWidth)
            }
        }
        // Show Chat at the trailing end of Today and Mail, only while the chat is hidden; on Search
        // the "Tutor" toggle after the field, shown on and off (mockup 07). Only with Claude Code
        // (DESIGN §6.3). A course's screens place their own Show Chat after their items
        // (DetailView).
        if hasChat {
            ChatToolbarItem(
                isPresented: $showsChat, isAvailable: model.chatActions.isAvailable,
                style: selection == .search ? .tutorToggle : .showChat
            )
        }
    }

    /// The screens whose chat button the window's toolbar places: Today and Mail (the mail chat)
    /// and Search (the tutor). A course's screens add theirs (DetailView); Review has its own Tutor
    /// tab.
    private var hasChat: Bool {
        isToday || selection?.isMail == true || selection == .search
    }

    #if os(macOS)
    /// The sidebar toggle in its own glass at the content toolbar's leading end, before the
    /// screen's title: on Today (mockups 01, 10), and on any screen while the sidebar is hidden so
    /// it can come back. View ▸ Show/Hide Sidebar (⌃⌘S) works everywhere.
    @ToolbarContentBuilder
    private var sidebarToggle: some ToolbarContent {
        if isToday || columns == .detailOnly {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation {
                        columns = columns == .detailOnly ? .all : .detailOnly
                    }
                } label: {
                    ToolbarGlyph(columns == .detailOnly ? LocalizedStringKey("Show Sidebar") : "Hide Sidebar", systemImage: "sidebar.left")
                        .frame(width: ToolbarGlyph.pillWidth, height: 34)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.leading, 9)
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    /// ‹ › before the course screen's title (mockup 08), in one glass group. Go ▸ Back and Forward
    /// (⌘[ ⌘]) work on every screen.
    @ToolbarContentBuilder
    private var historyButtons: some ToolbarContent {
        if selection?.courseScreenID != nil {
            ToolbarItemGroup(placement: .navigation) {
                Button { go(back: true) } label: {
                    ToolbarGlyph("Back", systemImage: "chevron.left")
                }
                .disabled(!history.canGoBack)
                .help("Back")
                Button { go(back: false) } label: {
                    ToolbarGlyph("Forward", systemImage: "chevron.right")
                }
                .disabled(!history.canGoForward)
                .help("Forward")
            }
        }
    }
    #endif

    /// Routes a feature screen's request: the sidebar selection, plus where a lecture opens.
    private func open(_ destination: StudyDestination) {
        switch destination {
        case .today: selection = .today
        case .calendar: selection = .calendar
        case .search(let text):
            query = text
            selection = .search
        case .course(let id): selection = .courseSettings(id)
        case .mail(let scope, let message):
            mailSelection = message
            keepsMailSelection = selection != .mailScope(scope)
            selection = .mailScope(scope)
        case .lecture(let id, var target):
            // A fresh request: opening the same hit again moves there again.
            target.request = UUID()
            reviewTarget = (id, target)
            selection = .lecture(id)
        }
    }

    /// `studyportal://` links from the Study Portal calendar: a session opens its lecture (else its
    /// course), a deadline the mail it was read from (else its course).
    private func openURL(_ url: URL) {
        guard let services = model.services else { return }
        if let sessionID = CalendarMirror.sessionID(from: url) {
            Task {
                let (lecture, session) = try await services.database.read { db in
                    (
                        try Lecture.where { $0.lectureSessionID.eq(LectureSession.ID?.some(sessionID)) }.fetchOne(db),
                        try LectureSession.find(sessionID).fetchOne(db)
                    )
                }
                if let lecture {
                    open(.lecture(lecture.id))
                } else if let session {
                    open(.course(session.courseID))
                }
            }
        } else if let itemID = CalendarMirror.itemID(from: url) {
            Task {
                let (item, source) = try await services.database.read { db in
                    (
                        try TrackedItem.find(itemID).fetchOne(db),
                        try TrackedItemSource
                            .where { $0.trackedItemID.eq(itemID) && $0.mailMessageID.isNot(nil) }
                            .order(by: \.createdAt)
                            .fetchOne(db)
                    )
                }
                if let messageID = source?.mailMessageID {
                    open(.mail(messageID))
                } else if let courseID = item?.courseID {
                    open(.course(courseID))
                }
            }
        }
    }

    /// Shows the running (or not yet started) live lecture, or sets up a new one.
    private func record() {
        guard model.hasOpenCapture else {
            model.sheet = .newCapture
            return
        }
        #if os(macOS)
        openWindow(id: LiveLectureScene.id)
        #else
        model.isLivePresented = true
        #endif
    }
}

/// An icon-only toolbar button's label as the mockups draw it: a small glyph in a wide glass pill
/// (57 × 34 pt) rather than the system's near-circle.
struct ToolbarGlyph: View {
    let title: LocalizedStringKey
    let systemImage: String

    /// The glyph's room inside the pill: the system adds its padding on both sides of a button.
    static let glyphWidth: CGFloat = 43
    /// The mockups' pill, for a view the toolbar's glass hugs (no padding of its own).
    static let pillWidth: CGFloat = 57

    init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .imageScale(.small)
                .frame(width: Self.glyphWidth)
        }
        .labelStyle(.iconOnly)
    }
}

#if os(iOS)
/// The window's search field (in the toolbar), on the screens that have one; ↩ runs `submit`.
private struct SearchFieldModifier: ViewModifier {
    let isShown: Bool
    let prompt: LocalizedStringKey
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let submit: () -> Void

    func body(content: Content) -> some View {
        if isShown {
            content
                .searchable(text: $text, placement: .toolbar, prompt: Text(prompt))
                .searchFocused(focused)
                .onSubmit(of: .search, submit)
        } else {
            content
        }
    }
}
#endif

/// The detail column's stack identity: one for the top-level screens, one per course or lecture.
private enum DetailIdentity: Hashable {
    case topLevel
    case screen(SidebarItem)

    init(_ item: SidebarItem) {
        self = item.isTopLevel ? .topLevel : .screen(item)
    }
}

/// Mirrors deadlines from mail as they come, go (Undo) or change: asks for Calendar access the
/// first time one wants an event.
private struct CalendarItemsWatcher: View {
    @Environment(AppModel.self) private var model
    @FetchAll(TrackedItem.where { $0.inCalendar || $0.calendarEventID.isNot(nil) }) private var items

    var body: some View {
        Color.clear
            .task(id: items.map(\.updatedAt)) {
                guard items.contains(where: \.needsCalendarSync) else { return }
                await model.syncCalendar()
            }
    }
}

/// A chat answer failed: Claude Code's state is read again (no new check), so a usage pause shows
/// as "Paused until 17:20" in the chat.
private struct ChatFailureWatcher: View {
    @Environment(AppModel.self) private var model
    @FetchAll(AgentConversation.where { $0.state.eq(ConversationState.failed) }) private var failed

    var body: some View {
        Color.clear
            .task(id: failed.count) {
                guard !failed.isEmpty else { return }
                await model.refreshClaudeAvailability(force: false)
            }
    }
}

/// Asks for Calendar access the first time a course shown in the calendar gets a session (weekly
/// slots entered in Course Settings), then keeps the calendar in step.
private struct CalendarSessionsWatcher: View {
    @Environment(AppModel.self) private var model
    @FetchAll(LectureSession.where { !$0.isCancelled }) private var sessions

    var body: some View {
        Color.clear
            .task(id: sessions.count) {
                guard !sessions.isEmpty else { return }
                await model.syncCalendar()
            }
    }
}
