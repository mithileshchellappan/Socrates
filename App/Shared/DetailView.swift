import StudyCore
import SwiftUI

/// Routes the sidebar selection to its screen. Screens are placeholders until their milestone.
struct DetailView: View {
    let item: SidebarItem

    var body: some View {
        switch item {
        case .today:
            TodayView()
        case .calendar, .mail, .search:
            PlaceholderScreen(item: item)
        case .course(let id):
            CourseView(courseID: id)
                .id(id)
        }
    }
}

struct TodayView: View {
    var body: some View {
        ContentUnavailableView {
            Image(systemName: SidebarItem.today.systemImage)
        }
        .navigationTitle(SidebarItem.today.title)
        .navigationSubtitle(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
    }
}

struct PlaceholderScreen: View {
    let item: SidebarItem

    var body: some View {
        ContentUnavailableView {
            Image(systemName: item.systemImage)
        }
        .navigationTitle(item.title)
    }
}

struct CourseView: View {
    @Environment(AppModel.self) private var model
    @FetchOne private var course: Course?
    @FetchAll private var lectures: [Lecture]
    @FetchAll private var jobs: [Job]
    private let courseID: Course.ID

    init(courseID: Course.ID) {
        self.courseID = courseID
        _course = FetchOne(Course.find(courseID))
        _lectures = FetchAll(
            Lecture.where { $0.courseID.eq(courseID) }.order { ($0.heldAt.desc(), $0.createdAt.desc()) }
        )
        _jobs = FetchAll(Job.where { $0.lectureID.isNot(nil) }.order(by: \.createdAt))
    }

    /// The latest job of each lecture: what it is doing now, or how its processing ended.
    private var latestJobs: [Lecture.ID: Job] {
        var latest: [Lecture.ID: Job] = [:]
        for job in jobs {
            if let lectureID = job.lectureID { latest[lectureID] = job }
        }
        return latest
    }

    var body: some View {
        let latest = latestJobs
        Group {
            if lectures.isEmpty {
                ContentUnavailableView {
                    Image(systemName: "books.vertical")
                } actions: {
                    Button("Import Lecture…") { model.sheet = .importLecture(courseID: courseID) }
                }
            } else {
                List(lectures) { lecture in
                    NavigationLink(value: LectureRoute(id: lecture.id)) {
                        LectureRow(lecture: lecture, job: latest[lecture.id])
                    }
                }
            }
        }
        .navigationTitle(course?.name ?? "")
        .navigationSubtitle(course?.professors.joined(separator: ", ") ?? "")
        .navigationDestination(for: LectureRoute.self) { route in
            LectureDetailView(lectureID: route.id)
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button("Import", systemImage: "square.and.arrow.down") {
                    model.sheet = .importLecture(courseID: courseID)
                }
            }
        }
    }
}

struct LectureRoute: Hashable {
    let id: Lecture.ID
}

struct LectureRow: View {
    let lecture: Lecture
    let job: Job?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lecture.title.isEmpty ? String(localized: "Lecture") : lecture.title)
                    .lineLimit(1)
                if let heldAt = lecture.heldAt {
                    Text(heldAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            JobStatusView(job: job, compact: true)
        }
    }
}

/// A lecture's processing state: determinate progress while queued or running, a mark when it
/// failed, nothing when done.
struct JobStatusView: View {
    let job: Job?
    var compact = false

    var body: some View {
        if let job {
            switch job.state {
            case .queued, .running:
                ProgressView(value: job.progress) {
                    if !compact { Text(job.progressTitle) }
                }
                .progressViewStyle(.linear)
                .frame(width: compact ? 72 : 140)
                .help(job.progressTitle)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(job.error ?? "")
            case .succeeded, .cancelled:
                EmptyView()
            }
        }
    }
}

extension Job {
    /// What the bar measures: model preparation (first use) or the stage itself.
    var progressTitle: String {
        if phase == .downloadingModel { return String(localized: "Downloading model") }
        if phase == .loadingModel { return String(localized: "Loading model") }
        return stage.progressTitle
    }
}

extension JobStage {
    var progressTitle: String {
        switch self {
        case .transcribe: String(localized: "Transcribing")
        case .align: String(localized: "Aligning")
        default: rawValue
        }
    }
}
