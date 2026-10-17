import CoursesUI
import FilingUI
import MailUI
import ReviewUI
import SearchUI
import StudyCore
import StudyUI
import SwiftUI

/// Routes the sidebar selection to its screen. Calendar (M3) is empty until its milestone.
struct DetailView: View {
    let item: SidebarItem
    let query: String
    var searchSubmits = 0
    let target: (lectureID: Lecture.ID, target: ReviewTarget)?
    /// The message selected on Mail (in Drafts, the draft).
    var mailSelection: Binding<MailMessage.ID?> = .constant(nil)
    let record: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        switch item {
        case .today:
            TodayView(record: record)
        case .calendar:
            PlaceholderScreen(item: item)
        case .mail:
            MailView(scope: .inbox, selection: mailSelection, query: query, now: model.fixedNow)
        case .mailScope(let scope):
            // The window's search field ("Search mail") filters the list.
            MailView(scope: scope, selection: mailSelection, query: query, now: model.fixedNow)
        case .search:
            SearchResultsView(query: query, submits: searchSubmits)
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
                .id(id)
        case .courseSlides(let id):
            CourseSlidesView(
                courseID: id,
                changeDeck: changeDeck,
                importFiles: { model.filingCenter?.importFiles(to: .course(id)) },
                importDropped: { file($0, into: id) }
            )
            .id(id)
        case .courseNotes(let id):
            CourseNotesView(courseID: id)
                .id(id)
        case .lecture(let id):
            if let services = model.services {
                LectureReviewView(
                    lectureID: id,
                    target: target?.lectureID == id ? target?.target ?? ReviewTarget() : ReviewTarget(),
                    realign: AppModel.realign(services: services)
                )
                .toolbar { RetryToolbarItem(lectureID: id) }
                .id(id)
            }
        }
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

struct PlaceholderScreen: View {
    let item: SidebarItem

    var body: some View {
        ContentUnavailableView {
            Image(systemName: item.systemImage)
        }
        .screenTitle(item.title, leadingInset: ScreenTitleInset.firstItem)
    }
}
