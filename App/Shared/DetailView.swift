import CalendarUI
import CoachUI
import CoursesUI
import FilingUI
import MailUI
import NotesUI
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
    /// The note selected on the Notes screen (M6).
    var noteSelection: Binding<Note.ID?> = .constant(nil)
    /// Search's query and selected hits (`SearchResultsView` writes it; the agent panel's context).
    var searchContext: Binding<ChatContext> = .constant(.none)
    /// mc renders (`ParityMode`): Progress opens with the practice exam sheet presented.
    var examSheet: Course.ID?
    let record: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        switch item {
        case .today:
            TodayView(now: model.fixedNow, record: record)
        case .calendar:
            CalendarScreen(week: model.fixedCalendarWeek, now: model.fixedNow)
        case .mail:
            MailView(scope: .inbox, selection: mailSelection, query: query, now: model.fixedNow)
        case .mailScope(let scope):
            // The window's search field ("Search mail") filters the list.
            MailView(scope: scope, selection: mailSelection, query: query, now: model.fixedNow)
        case .notesRow:
            notes(.all)
        case .notes(let scope):
            notes(scope)
        case .study:
            // mc (mockup 13): no search field; the title stays leading.
            StudyView(now: model.fixedNow)
                .modifier(CourseToolbarSpacer())
        case .search:
            SearchResultsView(query: query, submits: searchSubmits, context: searchContext)
        case .course(let id), .courseSettings(let id):
            CourseSettingsView(
                courseID: id,
                changeDeck: changeDeck,
                importFiles: { model.filingCenter?.importFiles(to: .course(id)) },
                importDropped: { file($0, into: id) },
                newCourse: { model.sheet = .newCourse }
            )
            .id(id)
        case .courseLectures(let id):
            CourseLecturesView(courseID: id)
                .modifier(CourseToolbarSpacer())
                .id(id)
        case .courseSlides(let id):
            CourseSlidesView(
                courseID: id,
                changeDeck: changeDeck,
                importFiles: { model.filingCenter?.importFiles(to: .course(id)) },
                importDropped: { file($0, into: id) }
            )
            .modifier(CourseToolbarSpacer())
            .id(id)
        case .courseNotes(let id):
            // The Notes screen scoped to the course (DESIGN 8.4), as under the Notes row; a course's
            // screens have no search field.
            NotesView(scope: .course(id), selection: noteSelection)
                .modifier(CourseToolbarSpacer())
                .id(id)
        case .courseProgress(let id):
            // mc (mockup 14): presents the practice exam sheet itself (17).
            CourseProgressView(courseID: id, now: model.fixedNow)
                .modifier(CourseToolbarSpacer())
                .modifier(ExamSheetPreview(courseID: id, now: model.fixedNow, preview: examSheet))
                .id(id)
        case .practice(let id):
            // mc: full window (mockups 15, 18); RootView hides the sidebar, and for an exam the
            // agent panel and the search field.
            PracticeScreen(sessionID: id, now: model.fixedNow)
                .id(id)
        case .practiceResults(let id, _):
            // mc (mockup 19): pushed on the course's Progress, with Back.
            PracticeExamResultsView(sessionID: id)
                .modifier(CourseToolbarSpacer())
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

    /// Mockup 04: All Notes or a course's notes under the Notes row; the window's search field
    /// ("Search notes") filters the list in place. One screen per scope (it fetches its notes for
    /// the scope).
    private func notes(_ scope: NotesScope) -> some View {
        NotesView(scope: scope, selection: noteSelection, query: query)
            .id(scope)
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

/// A course screen without toolbar items of its own (Lectures, Slides, Notes): a flexible spacer
/// keeps the toolbar's title and history chevrons at the leading end, as on Course Settings.
private struct CourseToolbarSpacer: ViewModifier {
    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .toolbar { ToolbarSpacer(.flexible) }
            #endif
    }
}

/// Debug renders and parity shots (mockup 17): Progress with its practice exam sheet presented, as
/// Progress's own "Practice exam" presents it.
private struct ExamSheetPreview: ViewModifier {
    let courseID: Course.ID
    let now: Date?
    let preview: Course.ID?
    @State private var isPresented = false

    func body(content: Content) -> some View {
        if preview == courseID {
            content
                .sheet(isPresented: $isPresented) {
                    PracticeExamSheet(courseID: courseID, now: now)
                }
                .task { isPresented = true }
        } else {
            content
        }
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
