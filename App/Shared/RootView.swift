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
    /// The last three queries submitted, newest first, one per line (the sidebar lists them on
    /// the Search screen).
    @AppStorage("recentSearches") private var recentSearchText = ""
    /// Where the review screen opened from a search hit or Today's hero goes: one request, for
    /// that opening only (the sidebar going elsewhere drops it, so a later visit resumes where
    /// review left off).
    @State private var reviewTarget: (lectureID: Lecture.ID, target: ReviewTarget)?
    @FocusState private var searchFocused: Bool
    /// ↩ in the search field: the search screen opens its selected (or first) hit.
    @State private var searchSubmits = 0

    init(selection: SidebarItem? = .today, query: String = "", reviewTarget: (lectureID: Lecture.ID, target: ReviewTarget)? = nil) {
        _selection = State(initialValue: selection)
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
            NavigationSplitView(columnVisibility: $columns) {
                SidebarView(selection: $selection, center: center, recentSearches: recentSearches) { text in
                    query = text
                    selection = .search
                }
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
                    #if os(macOS)
                    .toolbar { sidebarToggle }
                    #endif
                }
                .id(selection)
                .toolbar { trailingItems(center: center) }
            }
            .searchable(text: $query, placement: .toolbar, prompt: Text("Search lectures and notes"))
            .searchFocused($searchFocused)
            .onChange(of: query) { _, text in
                if !text.trimmingCharacters(in: .whitespaces).isEmpty, selection != .search { selection = .search }
            }
            .onSubmit(of: .search) {
                let text = query.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return }
                selection = .search
                searchSubmits += 1
                remember(text)
            }
            .onChange(of: selection) { _, item in
                // The target was for the lecture `open` showed; anywhere else drops it.
                if case .lecture(let id) = item, id == reviewTarget?.lectureID { return }
                reviewTarget = nil
            }
            .environment(\.isSearchFieldFocused, searchFocused)
            .focusedSceneValue(\.sidebarSelection, $selection)
            .focusedSceneValue(\.focusSearch) {
                selection = .search
                searchFocused = true
            }
            .smartImport(center)
            .environment(\.openDestination, OpenDestinationAction(open))
            .environment(\.studyServices, model.services)
            .environment(\.calendarMirror, model.calendarMirror)
            .sheet(item: $model.sheet) { sheet in
                switch sheet {
                case .newCapture:
                    CaptureSetupView()
                case .newCourse:
                    NewCourseView { course in selection = .course(course.id) }
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
        }
    }

    private var isToday: Bool { (selection ?? .today) == .today }

    private var recentSearches: [String] {
        recentSearchText.split(separator: "\n").map(String.init)
    }

    private func remember(_ text: String) {
        let recent = [text] + recentSearches.filter { $0.localizedCaseInsensitiveCompare(text) != .orderedSame }
        recentSearchText = recent.prefix(3).joined(separator: "\n")
    }

    /// The content toolbar's trailing end (mockup 01): [● Record] […] in their own glass, then the
    /// search field, which macOS keeps at the trailing edge. Record is Today's while idle (File ▸
    /// New Lecture Capture, ⇧⌘N, starts one from anywhere); a running recording shows on every
    /// screen, so it is never forgotten, and brings the live screen back.
    @ToolbarContentBuilder
    private func trailingItems(center: FilingCenter) -> some ToolbarContent {
        if isToday {
            // Today's title is a toolbar item (`screenTitle`), not the flexible system title: this
            // keeps Record and More at the trailing end.
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
        if let session = model.live?.session, session.isCapturing, session.startedAt != nil {
            ToolbarItem(placement: .primaryAction) {
                Button(action: record) {
                    RecordingIndicator(session: session)
                }
            }
        } else if isToday {
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
                Menu {
                    Button("Import…") { center.importFiles() }
                    Button("New Course…") { model.sheet = .newCourse }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
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
                Button(columns == .detailOnly ? LocalizedStringKey("Show Sidebar") : "Hide Sidebar", systemImage: "sidebar.left") {
                    withAnimation {
                        columns = columns == .detailOnly ? .all : .detailOnly
                    }
                }
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
        case .course(let id): selection = .course(id)
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
