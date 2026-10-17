import Courses
import Filing
import FilingUI
import SearchUI
import StudyCore
import StudyUI
import SwiftUI

/// The main window's sidebar (mockups 01, 03, 07, 08, 10): Today, Calendar, Mail (unread count),
/// Search; then the courses as flat rows. A course opens to its lectures ("L2 · Virtualization &
/// IaaS", Tue 13 Oct) and its next session in secondary text ("L3", "Mon 19 Oct, 12:15"), and on
/// its screen to a selected "Course Settings" row (08). Courses start closed (01, 07); the course
/// of the open lecture or course opens itself (03), and while files are dragged in, the predicted
/// course opens with the predicted row lit (10, `filingDropTarget`). Small disclosure chevrons show
/// once any course is open. Recent searches on the Search screen (07). The semester and Settings at
/// the bottom (New Course on a course's screen, 08). Files dropped on a course, lecture or session
/// row are filed exactly there.
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
    /// Unread messages in the Inbox (M2 sync fills the table; 0 shows nothing).
    @FetchOne(
        MailMessage
            .where {
                !$0.isSeen && $0.moveToMailboxID.is(nil)
                    && $0.mailboxID.in(Mailbox.where { $0.role.eq(MailboxRole?.some(.inbox)) }.select(\.id))
            }
            .count()
    ) private var unreadMail = 0
    /// The open courses, as comma-separated IDs (kept per window).
    @SceneStorage("sidebar.openCourses") private var openCourses = ""
    /// The course files being dragged in would go to: open while they are dragged, and a little
    /// longer, since moving from the window onto a sidebar row ends one drop target's drag a
    /// moment before the row's begins.
    @State private var dragCourseID: Course.ID?
    @State private var dragEnding: Task<Void, Never>?
    /// `center.dropCount` when the drag began: a drop keeps the course open.
    @State private var dropsBeforeDrag = 0

    /// The mockups' 228 pt glass panel (a 236 pt column with its inset).
    static let idealWidth: CGFloat = 228

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
        let open = openCourseIDs.union(dragCourseID.map { [$0] } ?? [])
        // While files are dragged in, lecture rows are titles only (mockup 10).
        let showsDates = center.drag == nil && dragCourseID == nil
        List(selection: $selection) {
            ForEach(SidebarItem.destinations, id: \.self) { item in
                NavigationLink(value: item) {
                    Label {
                        Text(item.title)
                    } icon: {
                        Image(systemName: item.systemImage)
                            .foregroundStyle(.tint)
                    }
                }
                .badge(item == .mail ? unreadMail : 0)
            }

            Section("Courses") {
                ForEach(courses) { course in
                    let courseLectures = lectures.filter { $0.courseID == course.id }.sorted(by: Self.inOrder)
                    let next = nextSession(course.id, now: now)
                    let isOpen = open.contains(course.id)
                    let hasChildren = !courseLectures.isEmpty || next != nil
                    courseRow(
                        course,
                        disclosure: open.isEmpty ? .none : (hasChildren ? .shown(isOpen: isOpen) : .hidden),
                        canOpen: hasChildren
                    )
                    if isOpen {
                        ForEach(courseLectures) { lecture in
                            NavigationLink(value: SidebarItem.lecture(lecture.id)) {
                                LectureSidebarRow(lecture: lecture, job: latestJobs[lecture.id], showsDate: showsDates)
                            }
                            .filingDropTarget(.lecture(lecture.id), center: center)
                            .contextMenu {
                                if latestJobs[lecture.id]?.state == .failed {
                                    Button("Retry Processing") { model.retryProcessing(lectureID: lecture.id) }
                                }
                            }
                        }
                        if let next {
                            SessionSidebarRow(session: next, showsDate: showsDates)
                                .filingDropTarget(.session(next.id), center: center)
                        }
                        if selection == .courseSettings(course.id) {
                            // Mockup 08: the course's screen is its settings, selected in its course.
                            NavigationLink(value: SidebarItem.courseSettings(course.id)) {
                                CourseSettingsSidebarRow()
                            }
                        }
                    }
                }
            }

            if selection == .search {
                // The last searches, newest first (mockup 07); nothing until something was searched.
                RecentSearchesSection()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
        }
        .navigationTitle("Study Portal")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 200, ideal: Self.idealWidth, max: 320)
        #else
        .toolbar { SettingsToolbarItem() }
        #endif
        .onChange(of: selection, initial: true) { _, item in
            // The open lecture or course shows in its course (from the sidebar, search or Today).
            switch item {
            case .lecture(let id):
                if let courseID = lectures.first(where: { $0.id == id })?.courseID { setOpen(courseID, true) }
            case .course(let id), .courseSettings(let id):
                setOpen(id, true)
            default:
                break
            }
        }
        .onChange(of: center.predictedCourseID) { _, courseID in
            followDrag(to: courseID)
        }
    }

    // MARK: - Rows

    enum Disclosure: Equatable {
        /// No course is open: plain rows (01, 07).
        case none
        /// Some course is open; this one has nothing to show (the chevron's room is kept).
        case hidden
        case shown(isOpen: Bool)
    }

    private func courseRow(_ course: Course, disclosure: Disclosure, canOpen: Bool) -> some View {
        NavigationLink(value: SidebarItem.course(course.id)) {
            HStack(spacing: 8) {
                if disclosure != .none {
                    chevron(course, disclosure: disclosure)
                        .padding(.trailing, -4)
                }
                CourseDot(hex: course.colorHex, size: 9)
                Text(course.name)
                    .lineLimit(1)
            }
        }
        .filingDropTarget(.course(course.id), center: center)
        .contextMenu {
            if canOpen {
                let isOpen = openCourseIDs.contains(course.id)
                Button(isOpen ? LocalizedStringKey("Hide Lectures") : "Show Lectures") { setOpen(course.id, !isOpen) }
            }
        }
    }

    @ViewBuilder
    private func chevron(_ course: Course, disclosure: Disclosure) -> some View {
        if case .shown(let isOpen) = disclosure {
            Button {
                withAnimation(.snappy(duration: 0.2)) { setOpen(course.id, !isOpen) }
            } label: {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isOpen ? LocalizedStringKey("Hide Lectures") : "Show Lectures"))
        } else {
            Color.clear.frame(width: 10, height: 16)
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if selection?.settingsCourseID != nil {
                    // Mockup 08: New Course on a course's screen, the semester at the right.
                    Button {
                        model.sheet = .newCourse
                    } label: {
                        Label("New Course", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    Spacer(minLength: 0)
                    semesterName
                } else {
                    semesterName
                    Spacer(minLength: 0)
                    #if os(macOS)
                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Settings")
                    #else
                    Button("New Course", systemImage: "plus") { model.sheet = .newCourse }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    #endif
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var semesterName: some View {
        if !semesters.isEmpty {
            Text(Semester.current(among: semesters).name)
                .lineLimit(1)
        }
    }

    // MARK: - State

    private var openCourseIDs: Set<Course.ID> {
        Set(openCourses.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private func setOpen(_ id: Course.ID, _ isOpen: Bool) {
        var ids = openCourseIDs
        if isOpen { ids.insert(id) } else { ids.remove(id) }
        let text = ids.map(\.uuidString).sorted().joined(separator: ",")
        if text != openCourses { openCourses = text }
    }

    /// Opens the course files being dragged in would go to, for that drag only: when it ends
    /// without a drop, the course closes again (after a moment, see `dragCourseID`); a drop
    /// leaves it open, showing where the files went.
    private func followDrag(to courseID: Course.ID?) {
        dragEnding?.cancel()
        dragEnding = nil
        if let courseID {
            if dragCourseID == nil { dropsBeforeDrag = center.dropCount }
            dragCourseID = courseID
            return
        }
        guard dragCourseID != nil else { return }
        dragEnding = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            if let course = dragCourseID, center.dropCount != dropsBeforeDrag { setOpen(course, true) }
            dragCourseID = nil
            dragEnding = nil
        }
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

/// Lecture and session rows sit under their course, their titles in line with Today, Calendar …
private let childIndent: CGFloat = 23

/// "L2 · Virtualization & IaaS" over "Tue 13 Oct"; while it is processed, a small determinate
/// ring; a failed run, a warning glyph.
struct LectureSidebarRow: View {
    let lecture: Lecture
    let job: Job?
    var showsDate = true

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(lecture))
                    .lineLimit(1)
                if showsDate, let heldAt = lecture.heldAt {
                    Text(heldAt.formatted(DayText.style()))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 4)
            ProcessingMark(job: job)
        }
        .padding(.leading, childIndent)
        .padding(.vertical, 3)
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
/// secondary. The time is proportional here, as in mockup 03 (decisions.md: the one place times
/// are not SF Mono).
struct SessionSidebarRow: View {
    let session: LectureSession
    var showsDate = true
    /// Lit as the place files being dragged in go (mockup 10): the title then reads as primary.
    @Environment(\.isFilingTarget) private var isFilingTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Self.title(session))
                .lineLimit(1)
            if showsDate {
                Text(verbatim: "\(DayText.day(session.startsAt)), \(SessionText().time(session.startsAt))")
                    .font(.subheadline)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isFilingTarget ? .primary : .secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, childIndent)
        .padding(.vertical, 3)
    }

    static func title(_ session: LectureSession) -> String {
        if session.kind == .lecture {
            return session.number.map { "L\($0)" } ?? SessionKind.lecture.displayName
        }
        return [session.kind.displayName, session.number.map(String.init)].compactMap(\.self).joined(separator: " ")
    }
}

/// A course's "Course Settings" row, under its lectures while its settings are open (mockup 08).
struct CourseSettingsSidebarRow: View {
    var body: some View {
        Label {
            Text("Course Settings")
                .lineLimit(1)
        } icon: {
            Image(systemName: "gearshape")
                .foregroundStyle(.tint)
        }
        .padding(.leading, childIndent)
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
