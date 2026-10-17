import CalendarSync
import CaptureUI
import CoursesUI
import FilingUI
import Processing
import StudyCore
import StudyUI
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var selection: SidebarItem?
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

    init(selection: SidebarItem? = .today, query: String = "", reviewTarget: (lectureID: Lecture.ID, target: ReviewTarget)? = nil) {
        _selection = State(initialValue: selection?.screen)
        _query = State(initialValue: query)
        _reviewTarget = State(initialValue: reviewTarget)
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
                .environment(\.openDestination, OpenDestinationAction(open))
                .environment(\.studyServices, model.services)
                .environment(\.calendarMirror, model.calendarMirror)
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
                    record: record
                )
                #if os(iOS)
                // The search field (mockups 01, 07), not on a lecture or a course (03, 08: the
                // slide stepper and inspector header, Import, own the toolbar there; ⌘F still
                // searches). Here, not on the split view: there it shows on every screen. (The Mac
                // draws its own field in `trailingItems`.)
                .modifier(SearchFieldModifier(isShown: showsSearchField, text: $query, focused: $searchFocused, submit: submitSearch))
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
            if !text.trimmingCharacters(in: .whitespaces).isEmpty, selection != .search { selection = .search }
        }
        .onChange(of: selection) { old, item in
            history.visit(from: old, to: item)
            // The target was for the lecture `open` showed; anywhere else drops it.
            if case .lecture(let id) = item, id == reviewTarget?.lectureID { return }
            reviewTarget = nil
        }
    }

    private var isToday: Bool { (selection ?? .today) == .today }

    /// The toolbar search field shows on the top-level screens, not on a lecture or a course.
    private var showsSearchField: Bool {
        (selection ?? .today).isTopLevel
    }

    /// ↩ in the search field: the Search screen opens its selected (or first) hit.
    private func submitSearch() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
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
                // "Search lectures, notes, mail" once mail is searchable (M2).
                ToolbarSearchField(text: $query, prompt: "Search lectures and notes", focused: $searchFocused, submit: submitSearch)
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
        case .mail:
            // M2 integration routes the scope and message to the Mail screen (docs/plan-m2.md §6).
            selection = .mail
        case .lecture(let id, var target):
            // A fresh request: opening the same hit again moves there again.
            target.request = UUID()
            reviewTarget = (id, target)
            selection = .lecture(id)
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
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let submit: () -> Void

    func body(content: Content) -> some View {
        if isShown {
            content
                .searchable(text: $text, placement: .toolbar, prompt: Text("Search lectures and notes"))
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
