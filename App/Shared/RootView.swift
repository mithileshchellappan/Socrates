import CalendarSync
import CalendarUI
import CaptureUI
import ChatUI
import CoursesUI
#if os(macOS)
import DocumentsUI
#endif
import Filing
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
    /// The note selected on the Notes screen (M6).
    @State private var noteSelection: Note.ID?
    /// md: the document selected on Documents, and the page a search hit or chip opened it at
    /// (dropped when another screen opens).
    @State private var documentSelection: StudyDocument.ID?
    @State private var documentPage: Int?
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
    /// Search's query and the hits selected on it (`SearchResultsView` writes it): what the agent
    /// panel's next message on Search is about.
    @State private var searchContext = ChatContext.none
    /// How the agent panel starts (renders); closed otherwise.
    private let panel: AgentPanelLaunch
    /// mc renders: Progress opens with its practice exam sheet presented (mockup 17).
    private let examSheet: Course.ID?
    /// mc: what the practice session on screen asks of the window (`PracticeStateWatcher`).
    @State private var practiceState: PracticeWindowState?
    /// The sidebar as it was before a round or an exam hid it (restored after).
    @State private var columnsBeforePractice: NavigationSplitViewVisibility?
    /// The sidebar column's width (rounded up to 4 pt), for the room the agent's sidebar has.
    @State private var sidebarWidth = SidebarView.idealWidth
    /// The agent panel is the window's right sidebar.
    @State private var agentExpanded = false

    init(
        selection: SidebarItem? = .today,
        query: String = "",
        reviewTarget: (lectureID: Lecture.ID, target: ReviewTarget)? = nil,
        mailSelection: MailMessage.ID? = nil,
        noteSelection: Note.ID? = nil,
        documentSelection: StudyDocument.ID? = nil,
        documentPage: Int? = nil,
        panel: AgentPanelLaunch = AgentPanelLaunch(),
        examSheet: Course.ID? = nil
    ) {
        _selection = State(initialValue: selection?.screen)
        _query = State(initialValue: query)
        _reviewTarget = State(initialValue: reviewTarget)
        _mailSelection = State(initialValue: mailSelection)
        _noteSelection = State(initialValue: noteSelection)
        _documentSelection = State(initialValue: documentSelection)
        _documentPage = State(initialValue: documentPage)
        // A round or an exam opens full window (renders start on one).
        if selection?.isPractice == true {
            _columns = State(initialValue: .detailOnly)
            _columnsBeforePractice = State(initialValue: .all)
        }
        self.panel = panel
        self.examSheet = examSheet
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
                // ma: ONE agent panel for the window (compact and movable, or the full-height right
                // sidebar), inside the search field's focus value (the panel folds its composer's
                // focus into it, so every screen's plain keys stand down while the student types).
                .agentPanel(
                    context: agentContext, launch: panel, floatingLauncher: columns == .detailOnly,
                    room: panelRoom, expandedChanged: { agentExpanded = $0 }
                )
                .environment(\.isSearchFieldFocused, searchFocused)
                .focusedSceneValue(\.sidebarSelection, $selection)
                // ⌘F would leave a practice exam being written: not while one is.
                .focusedSceneValue(\.focusSearch, focusSearchAction)
                .focusedSceneValue(\.screenHistory, ScreenHistoryActions(
                    canGoBack: history.canGoBack,
                    canGoForward: history.canGoForward,
                    back: { go(back: true) },
                    forward: { go(back: false) }
                ))
                .smartImport(center)
                .timetableImport(center: center)
                .environment(\.openDestination, OpenDestinationAction(open))
                // Empty Lectures, Slides, Progress, Study and Review's slides: Import… and drops
                // go through smart import (filed to the screen's course or lecture).
                .environment(\.importFiles, ImportFilesAction(
                    open: { target in center.importFiles(to: target.map(FilingDestination.init)) },
                    drop: { urls, target in Task { await center.file(urls, to: target.map(FilingDestination.init)) } }
                ))
                // Delete… on decks, lectures and recordings: one confirmation for the window
                // naming what goes, then Edit ▸ Undo.
                .environment(\.deleteFromLibrary, DeleteFromLibraryAction { item in center.requestDelete(item) })
                .libraryDeleteConfirmation(center: center, willDelete: leave, didDelete: { item in
                    // A course's sessions and items leave the "Socrates" calendar.
                    if case .course = item { await model.syncCalendar() }
                }, failed: { model.failure = $0 })
                .environment(\.studyServices, model.services)
                .environment(\.calendarMirror, model.calendarMirror)
                .environment(\.mailActions, mailActions)
                .environment(\.deadlineActions, model.deadlineActions)
                #if os(macOS)
                // md: the Documents screen's writes, over the app's document bank.
                .environment(\.documentActions, model.documentActions)
                #endif
                // The agent panel: absent until Claude Code is available, and while a practice exam
                // is being written (mc: the panel, its launcher and ⌘J go until it is handed in).
                .environment(\.agentPanelActions, panelActions)
                // mc: the study coach (Start, Practice, practice exams, grading); nil on iOS and in
                // renders, where the coach's screens draw their rows and offer no actions.
                .environment(\.studyCoach, model.screenCoach)
                // Search's planner ("Also searched") and on-device meaning search (Mac only).
                .environment(\.searchProviders, SearchProviders(planner: model.queryPlanner, semantic: model.semanticIndex))
                // Calendar: the student's other calendars, read-only (Mac only, like the mirror).
                .environment(\.foreignCalendars, model.calendarMirror.map { $0 as any ForeignCalendarSource })
                .environment(\.calendarVisibility, model.calendarVisibility)
                .onOpenURL(perform: openURL)
                #if os(macOS)
                // Links and opened captures go to the library window already open (not a new one).
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                #endif
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
                .background { practiceWatcher }
                #if os(macOS)
                .background { MainWindowReader() }
                .background {
                    SidebarFit(
                        columns: $columns, sidebarWidth: sidebarWidth, screenMin: screenMinWidth,
                        agentExpanded: agentExpanded, isPaused: selection?.isPractice == true
                    )
                }
                #endif
        }
    }

    /// What the window keeps beside the agent's right sidebar: the screen's minimum, and the
    /// sidebar while it shows (the Mac's window; iOS has no limit).
    private var panelRoom: AgentPanelRoom? {
        #if os(macOS)
        AgentPanelRoom(screen: screenMinWidth, sidebar: shownSidebarWidth)
        #else
        nil
        #endif
    }

    /// The screen on display's declared minimum (480; Mail's list and reader need more). From the
    /// selection, so it changes in the same update as the screen.
    private var screenMinWidth: CGFloat {
        WindowColumns.detailMin(for: selection)
    }

    /// The sidebar's column while it shows (its glass inset included), else 0.
    private var shownSidebarWidth: CGFloat {
        columns == .detailOnly ? 0 : sidebarWidth + WindowColumns.sidebarInset
    }

    /// The sidebar and the screen, with the window's search field.
    private func splitView(center: FilingCenter) -> some View {
        NavigationSplitView(columnVisibility: $columns) {
            // A course's row shows its settings, selected as the course's "Course Settings"
            // row (mockup 08).
            // A practice exam's results show as their course's Progress row (mockup 19).
            SidebarView(selection: Binding(get: { selection?.sidebarRow }, set: { selection = $0?.screen }), center: center)
                #if os(macOS)
                // Rounded up to 4 pt: dragging the sidebar's edge re-renders this view every few
                // points, not on every frame. A hidden sidebar keeps its last width.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    (proxy.size.width / 4).rounded(.up) * 4
                } action: { width in
                    if width > 10 { sidebarWidth = width }
                }
                // The toggle is the content toolbar's (`sidebarToggle`), as in mockups 01 and
                // 10. Removing the system one (or measuring after the width) drops the sidebar's
                // column width: set it again, last.
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: WindowColumns.sidebarMin, ideal: SidebarView.idealWidth, max: WindowColumns.sidebarMax)
                #endif
        } detail: {
            NavigationStack {
                DetailView(
                    item: selection ?? .today,
                    query: query,
                    searchSubmits: searchSubmits,
                    target: reviewTarget,
                    mailSelection: $mailSelection,
                    noteSelection: $noteSelection,
                    documentSelection: $documentSelection,
                    documentPage: documentPage,
                    searchContext: $searchContext,
                    examSheet: examSheet,
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
            #if os(macOS)
            // The screen's minimum and ideal are declared, never measured from its content: a
            // screen's rigid rows or one-line ideals never widen the window or push the sidebar
            // and the agent's sidebar out of it (screens adapt to their declared minimum).
            .frame(minWidth: screenMinWidth, idealWidth: max(WindowColumns.detailIdeal, screenMinWidth), maxWidth: .infinity)
            #endif
            // A new stack per screen; the top-level screens share one, so the search field (and
            // its focus while typing on Today opens Search) stays.
            .id(selection.map(DetailIdentity.init) ?? .topLevel)
            .toolbar { trailingItems(center: center) }
            // What Review and Calendar publish (`.agentContext`) may stop at the column: read it here.
            .agentPanelContextReader()
        }
        #if os(macOS)
        // The split view's minimum is declared too: the sidebar while it shows and the screen's
        // minimum (a frame with both bounds reports its own minimum, not its content's). On macOS 26
        // the split view runs under the agent's right sidebar, so its own minimum (the detail's,
        // which spans under both side columns) already holds that column's width, and the window
        // added it once more (sidebar 236 + 480 + a 560 pt agent column needed 1836, not 1276): a
        // window that cannot grow overflowed and cut the sidebar and the agent column off at its
        // edges. Under the agent's column as before (AppKit still insets the detail's content by
        // it), so the window's minimum counts that column once: sidebar + screen + its width.
        .frame(minWidth: screenMinWidth + shownSidebarWidth, maxWidth: .infinity)
        .ignoresSafeArea(.container, edges: .trailing)
        #endif
        .onChange(of: query) { _, text in
            // Typing on Mail or Notes filters its list ("Search mail", "Search notes"); elsewhere
            // it opens Search.
            guard searchOwner == .library else { return }
            if !text.trimmingCharacters(in: .whitespaces).isEmpty, selection != .search { selection = .search }
        }
        .onChange(of: selection) { old, item in
            history.visit(from: old, to: item)
            // Mail's search, Notes' and the library's are different questions: entering or leaving
            // Mail or Notes starts with an empty field.
            if (old ?? .today).searchOwner != (item ?? .today).searchOwner, !query.isEmpty { query = "" }
            // Another list starts with nothing selected (a Drafts selection is a draft's id),
            // unless the message was asked for with the list.
            if keepsMailSelection {
                keepsMailSelection = false
            } else if item?.isMail == true, old != item {
                mailSelection = nil
            }
            fullWindow(from: old, to: item)
            if item != .documents { documentPage = nil }
            // The target was for the lecture `open` showed; anywhere else drops it.
            if case .lecture(let id) = item, id == reviewTarget?.lectureID { return }
            reviewTarget = nil
        }
    }

    private var isToday: Bool { (selection ?? .today) == .today }

    /// ⌘F: not while a practice exam is written (it would leave the exam).
    private var focusSearchAction: (() -> Void)? {
        isWritingExam ? nil : { focusSearch() }
    }

    /// The agent panel's effects: none while a practice exam is written (panel, launcher and ⌘J go).
    private var panelActions: AgentPanelActions {
        isWritingExam ? AgentPanelActions() : model.agentPanelActions
    }

    /// Follows the practice session on screen (its kind, whether it was handed in).
    @ViewBuilder
    private var practiceWatcher: some View {
        if case .practice(let id) = selection {
            PracticeStateWatcher(sessionID: id, state: $practiceState)
                .id(id)
        }
    }

    /// ⌘F: Search with the caret in its field.
    private func focusSearch() {
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

    /// mc: a practice exam is being written: nothing but the exam (no sidebar, agent panel,
    /// launcher, search field or sidebar toggle) until it is handed in.
    private var isWritingExam: Bool {
        selection?.isPractice == true && practiceState?.isExam == true
    }

    /// mc: a round or an exam hides the sidebar; leaving brings it back as it was.
    private func fullWindow(from old: SidebarItem?, to new: SidebarItem?) {
        let entering = new?.isPractice == true
        if entering, old?.isPractice != true {
            columnsBeforePractice = columns
            columns = .detailOnly
        } else if !entering {
            practiceState = nil
            if let restored = columnsBeforePractice {
                columnsBeforePractice = nil
                withAnimation { columns = restored }
            }
        }
    }

    /// Whose question the search field holds on this screen (Mail and Notes: their own list's).
    private var searchOwner: SidebarItem.SearchOwner {
        (selection ?? .today).searchOwner
    }

    /// "Search mail" on Mail (mockup 05), "Search notes" on Notes (04), the whole library
    /// elsewhere (01).
    private var searchPrompt: LocalizedStringKey {
        switch searchOwner {
        case .mail: "Search mail"
        case .notes: "Search notes"
        case .library: "Search lectures, notes, mail"
        }
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
    /// not on Calendar, Study or Documents (mockups 06, 13; plan-docs §6; ⌘F still opens Search).
    private var showsSearchField: Bool {
        let item = selection ?? .today
        return item.isTopLevel && item != .calendar && item != .study && item != .documents
    }

    /// ↩ in the search field: the Search screen opens its selected (or first) hit. (On Mail and
    /// Notes the list filters as the student types.)
    private func submitSearch() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, searchOwner == .library else { return }
        selection = .search
        searchSubmits += 1
    }

    /// A lecture about to be deleted while its review shows: its course's Lectures instead. A
    /// course about to be deleted while one of its screens, lectures, notes or mail shows: Today.
    private func leave(_ item: StudyCore.LibraryItem) async {
        guard let services = model.services else { return }
        switch item {
        case .lecture(let id):
            guard selection == .lecture(id) else { return }
            let courseID = try? await services.database.read { db in try Lecture.find(id).fetchOne(db)?.courseID }
            selection = courseID.map { .courseLectures($0) } ?? .today
        case .course(let id):
            switch selection {
            case let screen? where screen.courseScreenID == id:
                selection = .today
            case .notes(.course(id))?, .mailScope(.course(id))?:
                selection = .today
            case .lecture(let lectureID)?:
                let courseID = try? await services.database.read { db in try Lecture.find(lectureID).fetchOne(db)?.courseID }
                if courseID == id { selection = .today }
            default:
                break
            }
        case .deck, .recording:
            break
        }
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
                // Notes' field is narrower (mockup 04: 180 pt).
                ToolbarSearchField(
                    text: $query, prompt: searchPrompt, focused: $searchFocused, submit: submitSearch,
                    width: searchOwner == .notes ? ToolbarSearchField.notesWidth : ToolbarSearchField.width
                )
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
    }

    /// What the agent panel's next message is about, from this window's state (ma): the screen, the
    /// course, the open mail, the note, Search's query and selected hits. Review and Calendar
    /// refine it with what they show (the slide and playhead; the week and the selection).
    private var agentContext: AgentContext {
        switch selection ?? .today {
        case .today:
            return .today
        case .calendar:
            return AgentContext(screen: .calendar)
        case .mail:
            return mailContext(.inbox)
        case .mailScope(let scope):
            return mailContext(scope)
        case .notesRow:
            return AgentContext(screen: .notes, noteID: noteSelection)
        case .notes(let scope):
            return AgentContext(screen: .notes, courseID: scope.courseID, noteID: noteSelection)
        case .documents:
            // md: the screen's publication (the selected document) is merged over it.
            return AgentContext(screen: .documents)
        case .search:
            if case .search(let text, let sources) = searchContext {
                return AgentContext(screen: .search, query: text, selection: sources)
            }
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentContext(screen: .search, query: text.isEmpty ? nil : text)
        case .course(let id), .courseSettings(let id):
            return AgentContext(screen: .course, courseID: id, courseScreen: "settings")
        case .courseLectures(let id):
            return AgentContext(screen: .course, courseID: id, courseScreen: "lectures")
        case .courseSlides(let id):
            return AgentContext(screen: .course, courseID: id, courseScreen: "slides")
        case .courseNotes(let id):
            return AgentContext(screen: .course, courseID: id, courseScreen: "notes", noteID: noteSelection)
        case .lecture(let id):
            return AgentContext(screen: .lecture, lectureID: id)
        // mc: Study and a round, the course's Progress and an exam's results (the views refine it).
        case .study, .practice:
            return AgentContext(screen: .study)
        case .courseProgress(let id), .practiceResults(_, let id):
            return AgentContext(screen: .course, courseID: id, courseScreen: "progress")
        }
    }

    /// Mail: the list and the open message (in Drafts the selection is a draft, not a message).
    private func mailContext(_ scope: MailScope) -> AgentContext {
        let filter = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var context = AgentContext(
            screen: .mail,
            mailScope: scope.agentName,
            mailMessageID: scope == .drafts ? nil : mailSelection,
            query: filter.isEmpty ? nil : filter
        )
        if case .course(let id) = scope { context.courseID = id }
        return context
    }

    #if os(macOS)
    /// The sidebar toggle in its own glass at the content toolbar's leading end, before the
    /// screen's title: on Today (mockups 01, 10), and on any screen while the sidebar is hidden so
    /// it can come back. View ▸ Show/Hide Sidebar (⌃⌘S) works everywhere.
    @ToolbarContentBuilder
    private var sidebarToggle: some ToolbarContent {
        if (isToday || columns == .detailOnly) && !isWritingExam {
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
        case .notes(let scope, let note):
            // The Notes row's All Notes or its course child, with the note selected (Search's hits
            // of lecture and course notes).
            if let note { noteSelection = note }
            selection = .notes(scope)
        case .lecture(let id, var target):
            // A fresh request: opening the same hit again moves there again.
            target.request = UUID()
            reviewTarget = (id, target)
            selection = .lecture(id)
        // mc (docs/plan-coach.md §8.2): Study, a course's Progress, a round or an exam full window
        // (by the session's kind), an exam's results pushed on its course's Progress.
        case .study: selection = .study
        case .courseProgress(let id): selection = .courseProgress(id)
        case .practice(let id): selection = .practice(id)
        case .practiceResults(let id):
            guard let services = model.services else { return }
            Task {
                let course = try? await services.database.read { db in try StudySession.find(id).fetchOne(db)?.courseID }
                if let course { selection = .practiceResults(id, course: course) }
            }
        // md: Documents with the document selected (nil: the screen's own) at the page named.
        case .documents(let id, let page):
            if let id { documentSelection = id }
            documentPage = page
            selection = .documents
        // ln: until the integrator pushes the notes page on the course's Lectures
        // (`SidebarItem.lectureNotes`), the lecture's review.
        case .lectureNotes(let id):
            open(.lecture(id))
        }
    }

    /// `socrates://` (and, on events written before the rename, `studyportal://`) links from the
    /// Socrates calendar: a session opens its lecture (else its
    /// course), a deadline the mail it was read from (else its course). M7, the Mac: an opened
    /// capture (a `.lecturebundle` AirDropped from the iPhone, or a `.lecture` package) is filed by
    /// smart import like a drop (a bundle is unpacked, never changed; one already in the library is
    /// "known").
    private func openURL(_ url: URL) {
        #if os(macOS)
        if url.isFileURL, ["lecture", "lecturebundle"].contains(url.pathExtension.lowercased()), let center = model.filingCenter {
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                await center.file([url])
            }
            return
        }
        #endif
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

/// The main window's columns (DESIGN 3.3, 6.1): the sidebar 200–320, the screen at least 480 (Mail
/// 700), the agent's right sidebar 300–560. The screen's minimum is declared per screen, never
/// measured from its content, and the window's minimum is the sidebar's width while it shows + the
/// screen's minimum + the agent column's width while it shows (`.windowResizability(.contentMinSize)`).
enum WindowColumns {
    static let sidebarMin: CGFloat = 200
    static let sidebarMax: CGFloat = 320
    /// The screen's narrowest: Course Settings, Notes, Calendar and the others adapt to it.
    static let detailMin: CGFloat = 480
    /// Mail's narrowest: its 318 pt list, the divider and the reader's rigid rows (a found row's
    /// text, lecture chip, Add to Calendar and its 64 pt trailing action; the route menu), about
    /// 380 pt with the reader's 26 pt margins. At 480 the list and reader were laid out wider than
    /// the column, centred, and drawn over the sidebar and under the agent's column.
    static let mailMin: CGFloat = 700
    /// The screen's own ideal, so no one-line text ideal of a screen sizes the window.
    static let detailIdeal: CGFloat = 720
    /// macOS 26's floating sidebar sits this far in from the window's edge.
    static let sidebarInset: CGFloat = 8
    /// The room past the agent's minimum before a sidebar it hid comes back (no flicker at the edge).
    static let sidebarReturn: CGFloat = 40

    /// What `screen` declares as its narrowest: the detail column's minimum, the room the agent's
    /// sidebar leaves it and `SidebarFit`'s measure.
    static func detailMin(for screen: SidebarItem?) -> CGFloat {
        switch screen {
        case .mail?, .mailScope?: mailMin
        default: detailMin
        }
    }
}

#if os(macOS)
/// When the window cannot hold the sidebar, the screen's minimum and the agent's right sidebar
/// together (a window as wide as the screen, full screen, a tile), the sidebar hides while the
/// panel is expanded (the panel's column shows once it has), and comes back when the panel shrinks
/// or closes or the window has room again, as Xcode and Finder collapse theirs; the window is never
/// made wider. The student's own toggle (the toolbar's button, View ▸ Show Sidebar ⌃⌘S, dragging
/// it shut) always wins, and a practice round or exam owns the sidebar while it runs.
private struct SidebarFit: View {
    @Binding var columns: NavigationSplitViewVisibility
    let sidebarWidth: CGFloat
    /// The screen on display's declared minimum (`WindowColumns.detailMin(for:)`).
    let screenMin: CGFloat
    let agentExpanded: Bool
    let isPaused: Bool

    /// Measured here, so a window resize re-renders only this view.
    @State private var windowWidth: CGFloat = 0
    /// The sidebar is hidden by this, not by the student.
    @State private var hidSidebar = false
    /// What this view last wrote (its own changes are not the student's).
    @State private var wrote: NavigationSplitViewVisibility?

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { windowWidth = $0 }
            .onChange(of: agentExpanded) { fit() }
            .onChange(of: windowWidth) { fit() }
            // Another screen (Mail needs more than 480): the sidebar makes room or comes back.
            .onChange(of: screenMin) { fit() }
            .onChange(of: columns) { _, visibility in
                if visibility != wrote { hidSidebar = false }
                wrote = nil
            }
    }

    private func fit() {
        guard !isPaused, windowWidth > 0 else { return }
        let screen = screenMin
        let sidebar = sidebarWidth + WindowColumns.sidebarInset
        let showsSidebar = columns != .detailOnly
        let fitsAlone = AgentPanelLayout.fits(windowWidth: windowWidth, beside: screen)
        let fitsBeside = AgentPanelLayout.fits(windowWidth: windowWidth, beside: screen + sidebar)
        if agentExpanded, showsSidebar, !fitsBeside, fitsAlone {
            hidSidebar = true
            // At once: the panel's column shows only after the sidebar has made room for it.
            write(.detailOnly, animated: false)
        } else if hidSidebar, !showsSidebar {
            let returnsAt = screen + sidebar + WindowColumns.sidebarReturn
            let roomReturned = AgentPanelLayout.fits(windowWidth: windowWidth, beside: returnsAt)
            if !agentExpanded || roomReturned {
                hidSidebar = false
                write(.all, animated: true)
            }
        }
    }

    private func write(_ visibility: NavigationSplitViewVisibility, animated: Bool) {
        guard columns != visibility else { return }
        wrote = visibility
        var transaction = Transaction(animation: animated ? .default : nil)
        transaction.disablesAnimations = !animated
        withTransaction(transaction) { columns = visibility }
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

private extension MailScope {
    /// The list's name in the agent's context (`AgentContext.mailScope`).
    var agentName: String {
        switch self {
        case .inbox: "inbox"
        case .course: "course"
        case .category(let category): category == .newsletter ? "newsletters" : category.rawValue
        case .drafts: "drafts"
        case .sent: "sent"
        }
    }
}

private extension NotesScope {
    var courseID: Course.ID? {
        if case .course(let id) = self { return id }
        return nil
    }
}

private extension FilingDestination {
    /// Where a screen's Import… or drop files go.
    init(_ target: ImportTarget) {
        switch target {
        case .course(let id): self = .course(id)
        case .lecture(let id): self = .lecture(id)
        }
    }
}
