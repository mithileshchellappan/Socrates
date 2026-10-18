import CalendarUI
import ChatUI
import CoursesUI
import FilingUI
import MailUI
import ReviewUI
import SearchUI
import StudyCore
import StudyUI
import SwiftUI

/// Routes the sidebar selection to its screen.
struct DetailView: View {
    let item: SidebarItem
    let query: String
    var searchSubmits = 0
    let target: (lectureID: Lecture.ID, target: ReviewTarget)?
    /// The message selected on Mail (in Drafts, the draft).
    var mailSelection: Binding<MailMessage.ID?> = .constant(nil)
    /// The chat inspector is shown (Today, Mail, a course's screens, Search; one per window; only
    /// with Claude Code).
    var showsChat: Binding<Bool> = .constant(false)
    let record: () -> Void

    @Environment(AppModel.self) private var model
    /// Search's tutor context: the query and the selected hits (`SearchResultsView` writes it).
    @State private var searchContext = ChatContext.none

    var body: some View {
        switch item {
        case .today:
            // Show Chat is placed by the window's toolbar, after Record and More (RootView).
            TodayView(now: model.fixedNow, record: record)
                .chatInspector(isPresented: showsChat, showsToolbarItem: false)
        case .calendar:
            CalendarScreen(week: model.fixedCalendarWeek, now: model.fixedNow)
        case .mail:
            MailView(scope: .inbox, selection: mailSelection, query: query, now: model.fixedNow)
                .chatInspector(isPresented: showsChat, context: chatContext(.inbox), showsToolbarItem: false)
        case .mailScope(let scope):
            // The window's search field ("Search mail") filters the list.
            MailView(scope: scope, selection: mailSelection, query: query, now: model.fixedNow)
                .chatInspector(isPresented: showsChat, context: chatContext(scope), showsToolbarItem: false)
        case .search:
            // The Tutor toggle is placed by the window's toolbar, after the search field (RootView).
            SearchResultsView(query: query, submits: searchSubmits, context: $searchContext)
                .chatInspector(isPresented: showsChat, context: searchContext, showsToolbarItem: false, toolbarStyle: .tutorToggle)
        case .course(let id), .courseSettings(let id):
            CourseSettingsView(
                courseID: id,
                changeDeck: changeDeck,
                importFiles: { model.filingCenter?.importFiles(to: .course(id)) },
                importDropped: { file($0, into: id) },
                newCourse: { model.sheet = .newCourse },
                // Show Chat after the screen's own [Import + | ⋯] (DESIGN §6.3).
                showsChat: showsChat
            )
            .chatInspector(isPresented: showsChat, context: .course(id), showsToolbarItem: false)
            .id(id)
        case .courseLectures(let id):
            CourseLecturesView(courseID: id)
                .modifier(CourseChat(courseID: id, showsChat: showsChat))
                .id(id)
        case .courseSlides(let id):
            CourseSlidesView(
                courseID: id,
                changeDeck: changeDeck,
                importFiles: { model.filingCenter?.importFiles(to: .course(id)) },
                importDropped: { file($0, into: id) }
            )
            .modifier(CourseChat(courseID: id, showsChat: showsChat))
            .id(id)
        case .courseNotes(let id):
            CourseNotesView(courseID: id)
                .modifier(CourseChat(courseID: id, showsChat: showsChat))
                .id(id)
        case .lecture(let id):
            if let services = model.services {
                LectureReviewView(
                    lectureID: id,
                    target: target?.lectureID == id ? target?.target ?? ReviewTarget() : ReviewTarget(),
                    realign: AppModel.realign(services: services, studyPass: model.studyPass)
                )
                .toolbar { RetryToolbarItem(lectureID: id) }
                .onAppear { model.reviewOpened(id) }
                .onDisappear { model.reviewClosed(id) }
                .id(id)
            }
        }
    }

    /// The open message the chat's next message carries (in Drafts the selection is a draft).
    private func chatContext(_ scope: MailScope) -> ChatContext {
        guard scope != .drafts, let id = mailSelection.wrappedValue else { return .none }
        return .mail(id)
    }

    /// Files dropped on a course's empty Slides group: filed into that course.
    private func file(_ urls: [URL], into courseID: Course.ID) {
        guard let center = model.filingCenter else { return }
        Task { await center.file(urls, to: .course(courseID)) }
    }

    /// Course Settings' Change… on a deck: the change sheet for the deck's latest filing.
    private func changeDeck(_ deckID: Deck.ID) {
        guard let services = model.services, let center = model.filingCenter else { return }
        Task {
            if let filing = try? await FilingRepository(store: services.records).latest(deckID: deckID) {
                center.presentChange(filing.id)
            }
        }
    }
}

/// The tutor about a course on a course screen without toolbar items of its own (Lectures,
/// Slides, Notes). Toolbar items of an outer modifier come first, so the flexible spacer goes
/// outside the inspector's Show Chat to keep it at the trailing end, as on Course Settings.
private struct CourseChat: ViewModifier {
    let courseID: Course.ID
    let showsChat: Binding<Bool>

    func body(content: Content) -> some View {
        content
            .chatInspector(isPresented: showsChat, context: .course(courseID))
            #if os(macOS)
            .toolbar { ToolbarSpacer(.flexible) }
            #endif
    }
}

/// Retry, while the lecture's processing has failed (the review screen shows the error).
private struct RetryToolbarItem: ToolbarContent {
    let lectureID: Lecture.ID
    @Environment(AppModel.self) private var model
    @FetchAll private var jobs: [Job]

    init(lectureID: Lecture.ID) {
        self.lectureID = lectureID
        _jobs = FetchAll(Job.where { $0.lectureID.eq(lectureID) }.order(by: \.createdAt))
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if jobs.last?.state == .failed {
                Button("Retry", systemImage: "arrow.clockwise") { model.retryProcessing(lectureID: lectureID) }
                    .help(jobs.last?.error ?? "")
            }
        }
    }
}
