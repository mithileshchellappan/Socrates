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
    @State private var query = ""
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
            NavigationSplitView {
                SidebarView(selection: $selection, center: center)
            } detail: {
                NavigationStack {
                    DetailView(
                        item: selection ?? .today,
                        query: query,
                        searchSubmits: searchSubmits,
                        target: reviewTarget,
                        record: record
                    )
                }
                .id(selection)
            }
            .searchable(text: $query, placement: .toolbar, prompt: Text("Search lectures and notes"))
            .searchFocused($searchFocused)
            .onChange(of: query) { _, text in
                if !text.trimmingCharacters(in: .whitespaces).isEmpty, selection != .search { selection = .search }
            }
            .onSubmit(of: .search) {
                guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                selection = .search
                searchSubmits += 1
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // A recording keeps going with its screen closed; show it here, on every
                    // screen, so it is never forgotten. Clicking brings the live screen back.
                    if let session = model.live?.session, session.isCapturing, session.startedAt != nil {
                        Button(action: record) {
                            RecordingIndicator(session: session)
                        }
                    } else if (selection ?? .today) == .today {
                        // Idle, Record is Today's (mockups 01, 10); File ▸ New Lecture Capture
                        // (⇧⌘N) starts one from anywhere.
                        Button("Record", systemImage: "record.circle", action: record)
                            .labelStyle(.titleAndIcon)
                    }
                }
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

    /// Routes a feature screen's request: the sidebar selection, plus where a lecture opens.
    private func open(_ destination: StudyDestination) {
        switch destination {
        case .today: selection = .today
        case .calendar: selection = .calendar
        case .search(let text):
            query = text
            selection = .search
        case .course(let id): selection = .course(id)
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
