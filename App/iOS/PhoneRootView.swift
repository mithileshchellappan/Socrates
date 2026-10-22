import CalendarSync
import CalendarUI
import ChatUI
import CoachUI
import CoursesUI
import MailUI
import PhoneUI
import Recorder
import RecorderUI
import ReviewUI
import SearchUI
import StudyCore
import StudyUI
import SwiftUI

/// What the iPhone presents over its shell, one at a time, full screen.
enum PhoneCover: Identifiable, Hashable {
    /// The recorder (mockup 09): a new recording, the one running, or the outbox after Stop.
    case recorder
    /// A practice round (mockup 16 right), from the plan card's Start or Progress.
    case round(StudySession.ID)
    /// A lecture's review (a search hit, Today's "Continue review"), until the phone has its own.
    case lecture(Lecture.ID, ReviewTarget)
    /// The header's search.
    case search

    var id: Self { self }
}

/// How the phone's root starts (DEBUG parity renders); the app starts on Today with nothing over it.
struct PhoneLaunch {
    var tab: PhoneTab = .today
    var cover: PhoneCover?
    /// Renders: the agent sheet open from the start (with `showsAgent`).
    var agentLaunch: AgentSheetLaunch?
    /// Renders: the agent shows as available (the real phone: only while iCloud sync runs).
    var showsAgent = false
    /// Renders: the recorder the cover shows (a preview that never records); nil: the app's.
    var recorder: PhoneRecorder?
}

/// The iPhone's root (M7, docs/plan-m7.md §7.2; mockups 09, 16, agent panel §7): `PhoneShell`
/// with Today (its phone layout), Courses (the course screens the iPad's sidebar opens), Calendar
/// and Mail (their iOS screens; phone layouts for these three are not M7). Record and Today's
/// Record present the recorder full screen; Start on the plan card presents the round. The iPad
/// keeps the split view (`RootView`).
struct PhoneRootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: PhoneTab
    @State private var cover: PhoneCover?
    @State private var mailScope = MailScope.inbox
    @State private var mailSelection: MailMessage.ID?
    private let launch: PhoneLaunch

    init(launch: PhoneLaunch = PhoneLaunch()) {
        self.launch = launch
        _tab = State(initialValue: launch.tab)
        _cover = State(initialValue: launch.cover)
    }

    private var recorder: PhoneRecorder? { launch.recorder ?? model.phoneRecorder }

    var body: some View {
        if let launchError = model.launchError {
            ContentUnavailableView("Library unavailable", systemImage: "exclamationmark.triangle", description: Text(launchError))
        } else {
            PhoneShell(
                selection: $tab,
                recordingPhase: recorder?.snapshot?.phase,
                record: { cover = .recorder },
                search: { cover = .search },
                agentLaunch: launch.agentLaunch
            ) {
                TodayView(now: model.fixedNow, record: { cover = .recorder })
            } courses: {
                PhoneCoursesView(record: { cover = .recorder })
            } calendar: {
                CalendarScreen(week: model.fixedCalendarWeek, now: model.fixedNow)
            } mail: {
                MailView(scope: mailScope, selection: $mailSelection, now: model.fixedNow)
            }
            .fullScreenCover(item: $cover) { cover in
                coverView(cover)
            }
            .environment(\.openDestination, OpenDestinationAction(open))
            .environment(\.studyServices, model.services)
            .environment(\.calendarMirror, model.calendarMirror)
            .environment(\.mailActions, model.mailActions)
            .environment(\.deadlineActions, model.deadlineActions)
            // The agent sheet: the relay to the Mac, shown only while iCloud sync runs.
            .environment(\.agentPanelActions, launch.showsAgent ? AgentPanelActions(isAvailable: true) : model.agentPanelActions)
            // The phone's coach (no Claude): Start and the round's choices work on the phone.
            .environment(\.studyCoach, model.screenCoach)
            .environment(\.searchProviders, SearchProviders())
            .environment(\.calendarVisibility, model.calendarVisibility)
        }
    }

    @ViewBuilder
    private func coverView(_ cover: PhoneCover) -> some View {
        switch cover {
        case .recorder:
            if let recorder {
                RecorderScreen(recorder: recorder)
            }
        case .round(let id):
            // The round sets its own title ("Practice", "6 / 12") and End.
            NavigationStack {
                PracticeView(sessionID: id, now: model.fixedNow)
            }
        case .lecture(let id, let target):
            NavigationStack {
                if let services = model.services {
                    LectureReviewView(lectureID: id, target: target, realign: AppModel.realign(services: services, studyPass: nil))
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(role: .close) { self.cover = nil }
                            }
                        }
                }
            }
        case .search:
            PhoneSearchScreen(close: { self.cover = nil })
        }
    }

    /// A screen's request on the phone: a tab, or a full-screen cover (a round, a lecture).
    private func open(_ destination: StudyDestination) {
        switch destination {
        case .today, .study:
            cover = nil
            tab = .today
        case .calendar:
            cover = nil
            tab = .calendar
        case .mail(let scope, let message):
            cover = nil
            mailScope = scope
            mailSelection = message
            tab = .mail
        case .course, .courseProgress, .notes, .practiceResults:
            cover = nil
            tab = .courses
        // md: documents stay on the Mac (never synced): the phone has no Documents screen.
        case .documents:
            break
        // mt: the files and the reader stay on the Mac; the phone has no Materials screen yet.
        case .material:
            break
        case .search:
            cover = .search
        case .lecture(let id, var target):
            // A fresh request: opening the same place again moves there again.
            target.request = UUID()
            cover = .lecture(id, target)
        // ln: lecture notes are Mac-only in this milestone: the lecture opens.
        case .lectureNotes(let id):
            cover = .lecture(id, ReviewTarget(request: UUID()))
        case .practice(let id):
            // Practice exams stay on the Mac: an exam's session shows the course instead.
            guard let services = model.services else { return }
            Task {
                let session = try? await services.records.fetch(StudySession.self, id: id)
                if session?.kind == .exam {
                    cover = nil
                    tab = .courses
                } else {
                    cover = .round(id)
                }
            }
        }
    }
}

/// The Courses tab: each course's screens as the iPad's sidebar lists them (Lectures, Slides,
/// Notes, Progress, Course Settings), pushed in the tab's stack.
private struct PhoneCoursesView: View {
    let record: () -> Void
    @FetchAll(Course.order { ($0.sortOrder, $0.name) }) private var courses

    var body: some View {
        List {
            ForEach(courses) { course in
                Section(course.name) {
                    ForEach(SidebarItem.courseScreens(course.id), id: \.self) { item in
                        NavigationLink(value: item) {
                            Label(item.title, systemImage: item.systemImage)
                        }
                    }
                }
            }
        }
        .navigationDestination(for: SidebarItem.self) { item in
            DetailView(item: item, query: "", target: nil, record: record)
        }
    }
}

/// The header's search on the phone: the library's search (lectures, notes, mail) with the field
/// at the top; a hit opens over it.
private struct PhoneSearchScreen: View {
    let close: () -> Void
    @State private var query = ""
    @State private var submits = 0
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            SearchResultsView(query: query, submits: submits)
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search lectures, notes, mail"))
                .searchFocused($focused)
                .onSubmit(of: .search) { submits += 1 }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close, action: close)
                    }
                }
                .task { focused = true }
        }
    }
}
