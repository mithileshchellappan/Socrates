import Courses
import FilingUI
import StudyCore
import StudyUI
import SwiftUI

/// The main window's sidebar (mockups 03 and 10): Today, Calendar, Mail, Search; each course with
/// its lectures ("L2 · Virtualization & IaaS", Tue 13 Oct) and its next session in secondary text
/// ("L3", "Mon 19 Oct, 12:15"); the semester and New Course at the bottom. Files dropped on a
/// course, lecture or session row are filed exactly there.
struct SidebarView: View {
    @Binding var selection: SidebarItem?
    let center: FilingCenter

    @Environment(AppModel.self) private var model
    @FetchAll(Course.order { ($0.sortOrder, $0.name) }) private var courses
    @FetchAll(Lecture.order(by: \.createdAt)) private var lectures
    @FetchAll(Semester.order(by: \.lectureStart)) private var semesters
    @FetchAll private var sessions: [LectureSession]
    /// Each lecture's jobs, oldest first: the last one says what processing is doing.
    @FetchAll(Job.where { $0.lectureID.isNot(nil) }.order(by: \.createdAt)) private var jobs
    @State private var collapsed: Set<Course.ID> = []

    init(selection: Binding<SidebarItem?>, center: FilingCenter) {
        _selection = selection
        self.center = center
        // Sessions from yesterday on: enough to find each course's next one. Rounded to the day,
        // so the request stays the same while the window re-creates the sidebar (each keystroke
        // in the search field) and its observation is not restarted.
        let since = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86_400)
        _sessions = FetchAll(LectureSession.where { !$0.isCancelled && $0.endsAt.gte(since) }.order(by: \.startsAt))
    }

    var body: some View {
        let latestJobs = Self.latestJobs(jobs)
        let now = Date()
        List(selection: $selection) {
            ForEach(SidebarItem.destinations, id: \.self) { item in
                NavigationLink(value: item) {
                    Label(item.title, systemImage: item.systemImage)
                }
            }

            Section("Courses") {
                ForEach(courses) { course in
                    let courseLectures = lectures.filter { $0.courseID == course.id }.sorted(by: Self.inOrder)
                    let next = nextSession(course.id, now: now)
                    if courseLectures.isEmpty, next == nil {
                        courseRow(course)
                    } else {
                        DisclosureGroup(isExpanded: expansion(course.id)) {
                            ForEach(courseLectures) { lecture in
                                NavigationLink(value: SidebarItem.lecture(lecture.id)) {
                                    LectureSidebarRow(lecture: lecture, job: latestJobs[lecture.id])
                                }
                                .filingDropTarget(.lecture(lecture.id), center: center)
                                .contextMenu {
                                    if latestJobs[lecture.id]?.state == .failed {
                                        Button("Retry Processing") { model.retryProcessing(lectureID: lecture.id) }
                                    }
                                }
                            }
                            if let next {
                                SessionSidebarRow(session: next)
                                    .filingDropTarget(.session(next.id), center: center)
                            }
                        } label: {
                            courseRow(course)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                if !semesters.isEmpty {
                    Text(Semester.current(among: semesters).name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("New Course", systemImage: "plus") { model.sheet = .newCourse }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("New Course")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .navigationTitle("Study Portal")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 320)
        #else
        .toolbar { SettingsToolbarItem() }
        #endif
        .onChange(of: selection) { _, item in
            // Opening a lecture from elsewhere (search, Today) shows it in its course.
            guard case .lecture(let id) = item, let courseID = lectures.first(where: { $0.id == id })?.courseID else { return }
            collapsed.remove(courseID)
        }
    }

    private func courseRow(_ course: Course) -> some View {
        NavigationLink(value: SidebarItem.course(course.id)) {
            Label {
                Text(course.name)
            } icon: {
                CourseDot(hex: course.colorHex, size: 9)
            }
        }
        .filingDropTarget(.course(course.id), center: center)
    }

    private func expansion(_ id: Course.ID) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { expanded in
                if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
            }
        )
    }

    /// The course's next lecture that has no lecture row yet (one in progress counts); for a
    /// course without lecture sessions (a seminar), its next session of any kind.
    private func nextSession(_ courseID: Course.ID, now: Date) -> LectureSession? {
        let filed = Set(lectures.compactMap(\.lectureSessionID))
        let course = sessions.filter { $0.courseID == courseID }
        let numbered = course.contains { $0.kind == .lecture } ? course.filter { $0.kind == .lecture } : course
        return numbered.first { $0.endsAt > now && !filed.contains($0.id) }
    }

    /// By number, then date, then when they were added.
    static func inOrder(_ lhs: Lecture, _ rhs: Lecture) -> Bool {
        let left = (lhs.number ?? .max, lhs.heldAt ?? .distantFuture, lhs.createdAt)
        let right = (rhs.number ?? .max, rhs.heldAt ?? .distantFuture, rhs.createdAt)
        if left.0 != right.0 { return left.0 < right.0 }
        if left.1 != right.1 { return left.1 < right.1 }
        return left.2 < right.2
    }

    static func latestJobs(_ jobs: [Job]) -> [Lecture.ID: Job] {
        var latest: [Lecture.ID: Job] = [:]
        for job in jobs {
            if let lectureID = job.lectureID { latest[lectureID] = job }
        }
        return latest
    }
}

/// "L2 · Virtualization & IaaS" over "Tue 13 Oct"; while it is processed, a small determinate
/// ring; a failed run, a warning glyph.
struct LectureSidebarRow: View {
    let lecture: Lecture
    let job: Job?

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(lecture))
                    .lineLimit(1)
                if let heldAt = lecture.heldAt {
                    Text(heldAt.formatted(DayText.style()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 4)
            ProcessingMark(job: job)
        }
        .padding(.leading, 4)
    }

    /// "L2 · Virtualization & IaaS", "L2", "Virtualization & IaaS" or "Lecture".
    static func title(_ lecture: Lecture) -> String {
        let title = lecture.title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (lecture.number, title.isEmpty) {
        case (let number?, false): return "L\(number) · \(title)"
        case (let number?, true): return "L\(number)"
        case (nil, false): return title
        case (nil, true): return String(localized: "Lecture")
        }
    }
}

/// The next session of a course that has no lecture yet: "L3" over "Mon 19 Oct, 12:15", both
/// secondary.
struct SessionSidebarRow: View {
    let session: LectureSession

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Self.title(session))
                .lineLimit(1)
            HStack(spacing: 0) {
                Text(session.startsAt.formatted(DayText.style()))
                Text(verbatim: ", ")
                Text(SessionText().time(session.startsAt))
                    .font(.caption.monospaced())
            }
            .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
    }

    static func title(_ session: LectureSession) -> String {
        if session.kind == .lecture {
            return session.number.map { "L\($0)" } ?? SessionKind.lecture.displayName
        }
        return [session.kind.displayName, session.number.map(String.init)].compactMap(\.self).joined(separator: " ")
    }
}

/// Processing state in a sidebar row: a determinate ring while queued or running, a warning glyph
/// (with the error as help) when it failed, nothing when done.
struct ProcessingMark: View {
    let job: Job?

    var body: some View {
        if let job {
            switch job.state {
            case .queued, .running:
                ProgressView(value: job.progress)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .help(job.progressTitle)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .help(job.error ?? "")
            case .succeeded, .cancelled:
                EmptyView()
            }
        }
    }
}

extension Job {
    /// What the ring measures: model preparation (first use) or the stage itself.
    var progressTitle: String {
        if phase == .downloadingModel { return String(localized: "Downloading model") }
        if phase == .loadingModel { return String(localized: "Loading model") }
        switch stage {
        case .transcribe: return String(localized: "Transcribing")
        case .align: return String(localized: "Aligning")
        default: return stage.rawValue
        }
    }
}
