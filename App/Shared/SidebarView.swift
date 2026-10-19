import CalendarUI
import ChatUI
import Courses
import Filing
import FilingUI
import MailUI
import SearchUI
import StudyCore
import StudyUI
import SwiftUI

/// The main window's sidebar (mockups 01, 03, 05, 07, 08, 10): Today, Calendar, Mail (unread count;
/// on Mail, its lists under it: Inbox, the courses, University, Newsletters, Drafts, Sent), Notes
/// (M6; on Notes, All Notes and each course with notes under it, mockup 04), Search; then the courses as flat rows, on the mockups' 29 pt pitch. Courses start closed (01,
/// 07). On a lecture's screen every course with lectures opens to them ("L2 · Virtualization &
/// IaaS", Tue 13 Oct) and its next session in secondary text ("L3", "Mon 19 Oct, 12:15") (03); on a
/// course's screen that course shows its own screens instead: Lectures (count), Slides, Notes,
/// Course Settings, with no chevrons (08). While files are dragged in, the predicted course opens
/// with the predicted row lit (10, `filingDropTarget`). Courses opened that way close again on the
/// top-level screens; a course opened with its chevron stays open. Small disclosure chevrons show
/// once any course is open. Recent searches on the Search screen (07). The semester, the agent
/// panel's launcher and Settings at the bottom (New Course on a course's screen, 08). Files dropped on a course, lecture or
/// session row are filed exactly there.
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
    /// The courses that have notes (M6: the Notes row's children; one id per note, folded below).
    @FetchAll(Note.where { $0.courseID.isNot(nil) }.select(\.courseID)) private var noteCourseIDs: [Course.ID?]
    /// The courses that have mail (Mail's course lists, DESIGN 6.2 "each course with mail").
    @FetchAll(MailMessage.where { $0.courseID.isNot(nil) }.select(\.courseID).distinct()) private var mailCourseIDs: [Course.ID?]
    /// Without a mail account Mail has no lists under it (the screen offers Set Up Mail…).
    @FetchOne(MailAccount.count()) private var mailAccounts = 0
    /// The courses opened with their chevron, as comma-separated IDs (kept per window).
    @SceneStorage("sidebar.openCourses") private var openCourses = ""
    /// The Courses section, folded with its header's chevron (kept per window).
    @SceneStorage("sidebar.coursesExpanded") private var coursesExpanded = true
    /// Mail's lists under the Mail row, folded with the row's chevron (kept per window).
    @SceneStorage("sidebar.mailListsExpanded") private var mailListsExpanded = true
    /// Courses the open screen opened that were closed with their chevron (until the screen changes).
    @State private var closedCourses: Set<Course.ID> = []
    /// The course files were just dropped into: open, showing where they went, until the screen
    /// changes.
    @State private var droppedCourseID: Course.ID?
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
        let isDragging = center.drag != nil || dragCourseID != nil
        // The course whose screen shows lists its screens (08), unless files are dragged onto it.
        let screenCourseID = selection?.courseScreenID.flatMap { $0 == dragCourseID ? nil : $0 }
        let childrenOf = Dictionary(uniqueKeysWithValues: courses.map { course in
            let courseLectures = lectures.filter { $0.courseID == course.id }.sorted(by: Self.inOrder)
            return (course.id, (lectures: courseLectures, next: nextSession(course.id, now: now)))
        })
        let open = openCourseIDs(withChildren: Set(childrenOf.compactMap { !$1.lectures.isEmpty || $1.next != nil ? $0 : nil }))
        // While files are dragged in, lecture rows are titles only (mockup 10).
        let showsDates = !isDragging
        List(selection: $selection) {
            ForEach(SidebarItem.destinations, id: \.self) { item in
                let foldsMail = item == .mail && selection?.isMail == true && mailAccounts > 0
                NavigationLink(value: item) {
                    HStack(spacing: 0) {
                        SidebarRowLabel(item.title) {
                            Image(systemName: item.systemImage)
                                .foregroundStyle(.tint)
                        }
                        if foldsMail {
                            Spacer(minLength: 4)
                            foldChevron(isOpen: mailListsExpanded, open: "Show Mailboxes", close: "Hide Mailboxes") {
                                mailListsExpanded.toggle()
                            }
                        }
                    }
                }
                // On Mail the Inbox row below carries the count.
                .badge(item == .mail && selection?.isMail != true ? unreadMail : 0)
                .contextMenu {
                    if foldsMail {
                        Button(mailListsExpanded ? LocalizedStringKey("Hide Mailboxes") : "Show Mailboxes") {
                            withAnimation(.snappy(duration: 0.2)) { mailListsExpanded.toggle() }
                        }
                    }
                }
                if foldsMail, mailListsExpanded {
                    // Mockup 05: Mail's lists under the Mail row while one shows.
                    ForEach(mailScopes, id: \.self) { scope in
                        NavigationLink(value: SidebarItem.mailScope(scope)) {
                            MailScopeLabel(scope: scope)
                                .padding(.leading, courseScreenIndent)
                        }
                    }
                }
                if item == .notesRow, selection?.isNotes == true {
                    // Mockup 04 (DESIGN 6.2): All Notes, then each course with notes; no counts.
                    NavigationLink(value: SidebarItem.notes(.all)) {
                        SidebarRowLabel(String(localized: "All Notes")) {
                            Image(systemName: SidebarItem.notes(.all).systemImage)
                                .foregroundStyle(.tint)
                        }
                        .padding(.leading, courseScreenIndent)
                    }
                    ForEach(notesCourses) { course in
                        NavigationLink(value: SidebarItem.notes(.course(course.id))) {
                            SidebarRowLabel(course.name) {
                                CourseDot(hex: course.colorHex, size: 9)
                            }
                            .padding(.leading, courseScreenIndent)
                        }
                    }
                }
            }

            // The header's chevron folds the courses; a drag of files opens them for their rows.
            Section(isExpanded: Binding(get: { coursesExpanded || isDragging }, set: { coursesExpanded = $0 })) {
                ForEach(courses) { course in
                    let children = childrenOf[course.id] ?? ([], nil)
                    let isOpen = open.contains(course.id)
                    let hasChildren = !children.lectures.isEmpty || children.next != nil
                    courseRow(
                        course,
                        disclosure: screenCourseID != nil || open.isEmpty ? .none : (hasChildren ? .shown(isOpen: isOpen) : .hidden),
                        canOpen: hasChildren && screenCourseID == nil
                    )
                    if course.id == screenCourseID {
                        // Mockup 08: the course's own screens, its settings among them.
                        ForEach(SidebarItem.courseScreens(course.id), id: \.self) { item in
                            NavigationLink(value: item) {
                                CourseScreenSidebarRow(item: item, isSelected: selection == item)
                            }
                            .badge(item == .courseLectures(course.id) ? children.lectures.count : 0)
                        }
                    } else if isOpen {
                        ForEach(children.lectures) { lecture in
                            NavigationLink(value: SidebarItem.lecture(lecture.id)) {
                                LectureSidebarRow(lecture: lecture, job: latestJobs[lecture.id], showsDate: showsDates)
                            }
                            .filingDropTarget(.lecture(lecture.id), center: center)
                            .contextMenu {
                                if latestJobs[lecture.id]?.state == .failed {
                                    Button("Retry Processing") { model.retryProcessing(lectureID: lecture.id) }
                                    Divider()
                                }
                                // The confirmation names what goes; Edit ▸ Undo brings it back.
                                Button("Delete…", role: .destructive) { center.requestDelete(.lecture(lecture.id)) }
                            }
                        }
                        if let next = children.next {
                            SessionSidebarRow(session: next, showsDate: showsDates)
                                .filingDropTarget(.session(next.id), center: center)
                        }
                    }
                }
            } header: {
                SidebarSectionTitle("Courses")
            }

            if selection == .calendar {
                // The student's calendars as checkboxes, as Calendar.app (mockup 06); loaded again
                // when their calendars change.
                CalendarSidebarSection()
                    .id(model.calendarStoreRevision)
            }

            if selection == .search {
                // The last searches, newest first (mockup 07); nothing until something was searched.
                RecentSearchesSection()
            }
        }
        #if os(macOS)
        // The mockups' rows, whatever System Settings' sidebar size: the small row (24 pt, 11 pt
        // text) with each row's 13 pt content 21 pt high gives their 29 pt pitch (`.medium` is 32).
        .environment(\.sidebarRowSize, .small)
        #endif
        // A bar, not an inset: long lists (Mail, a lecture's screen) scroll under it with the
        // scroll-edge effect instead of drawing through the semester; the hard edge cuts them off
        // at the footer's hairline.
        .safeAreaBar(edge: .bottom, spacing: 0) {
            footer
        }
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .navigationTitle("Study Portal")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 200, ideal: Self.idealWidth, max: 320)
        #else
        .toolbar { SettingsToolbarItem() }
        #endif
        .onChange(of: selection) {
            // A course closed with its chevron stays closed only on the screen that opened it.
            closedCourses = []
            droppedCourseID = nil
        }
        .onChange(of: center.predictedCourseID) { _, courseID in
            followDrag(to: courseID)
        }
    }

    /// The courses with notes, in course order (the Notes row's children).
    private var notesCourses: [Course] {
        let ids = Set(noteCourseIDs.compactMap(\.self))
        return courses.filter { ids.contains($0.id) }
    }

    /// Mail's lists in mockup 05's order: Inbox; the courses with mail; University, Newsletters;
    /// Drafts, Sent.
    private var mailScopes: [MailScope] {
        var withMail = Set(mailCourseIDs.compactMap(\.self))
        // The open list keeps its row (its last mail may just have moved).
        if case .mailScope(.course(let id))? = selection { withMail.insert(id) }
        let courseScopes = courses.filter { withMail.contains($0.id) }.map { MailScope.course($0.id) }
        return [.inbox] + courseScopes + [.category(.university), .category(.newsletter), .drafts, .sent]
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
                    .font(.body)
                    .lineLimit(1)
            }
            .frame(minHeight: SidebarRowLabel<EmptyView>.minHeight)
        }
        .filingDropTarget(.course(course.id), center: center)
        .contextMenu {
            if canOpen {
                let isOpen = disclosure == .shown(isOpen: true)
                Button(isOpen ? LocalizedStringKey("Hide Lectures") : "Show Lectures") { setOpen(course.id, !isOpen) }
            }
        }
    }

    /// A small trailing chevron that folds a row's children (Mail's lists).
    private func foldChevron(
        isOpen: Bool,
        open: LocalizedStringKey,
        close: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { action() }
        } label: {
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isOpen ? close : open))
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
                if selection?.courseScreenID != nil {
                    // Mockup 08: New Course on a course's screen, the semester at the right.
                    Button {
                        model.sheet = .newCourse
                    } label: {
                        Label("New Course", systemImage: "plus")
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(.borderless)
                    Spacer(minLength: 0)
                    // The semester gives way first in a narrow sidebar.
                    semesterName
                        .layoutPriority(-1)
                    // ma: the agent panel's one launcher, the same on every screen (absent
                    // without Claude Code).
                    AgentPanelLauncher()
                } else {
                    semesterName
                    Spacer(minLength: 0)
                    AgentPanelLauncher()
                    #if os(macOS)
                    SettingsLink {
                        // The mockups' small, light gear.
                        Label {
                            Text("Settings")
                        } icon: {
                            Image(systemName: "gearshape")
                                .imageScale(.small)
                                .foregroundStyle(.tertiary)
                        }
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
        // Rows scrolling under the bar never show through the semester or the launcher.
        .background(.bar)
    }

    @ViewBuilder
    private var semesterName: some View {
        if !semesters.isEmpty {
            Text(Semester.current(among: semesters).name)
                .lineLimit(1)
        }
    }

    // MARK: - State

    /// The courses opened with their chevron (or by a drop).
    private var chevronOpenIDs: Set<Course.ID> {
        Set(openCourses.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    /// The courses that show their lectures: on a lecture's screen every course that has some
    /// (03), on a course's screen none (08 lists that course's screens), and those opened with
    /// their chevron; plus the course files being dragged in would go to (10).
    private func openCourseIDs(withChildren: Set<Course.ID>) -> Set<Course.ID> {
        var open: Set<Course.ID>
        switch selection {
        case .lecture?:
            open = withChildren.union(chevronOpenIDs).subtracting(closedCourses)
        case let item? where item.courseScreenID != nil:
            open = []
        default:
            open = chevronOpenIDs
        }
        if let dragCourseID { open.insert(dragCourseID) }
        if let droppedCourseID, selection?.courseScreenID == nil { open.insert(droppedCourseID) }
        return open
    }

    /// The chevron (or Show/Hide Lectures): open stays open on every screen (kept per window);
    /// closing a course the screen opened lasts while that screen shows.
    private func setOpen(_ id: Course.ID, _ isOpen: Bool) {
        var ids = chevronOpenIDs
        if isOpen {
            ids.insert(id)
            closedCourses.remove(id)
        } else {
            ids.remove(id)
            closedCourses.insert(id)
        }
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
            if let course = dragCourseID, center.dropCount != dropsBeforeDrag { droppedCourseID = course }
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
                    .font(.body)
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
        // Two-line rows breathe; title-only rows (during a drag, mockup 10) keep the 29 pt pitch.
        .padding(.vertical, showsDate ? 3 : 0)
        .frame(minHeight: showsDate ? nil : SidebarRowLabel<EmptyView>.minHeight)
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
                .font(.body)
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
        // Two-line rows breathe; title-only rows (during a drag, mockup 10) keep the 29 pt pitch.
        .padding(.vertical, showsDate ? 3 : 0)
        .frame(minHeight: showsDate ? nil : SidebarRowLabel<EmptyView>.minHeight)
    }

    static func title(_ session: LectureSession) -> String {
        if session.kind == .lecture {
            return session.number.map { "L\($0)" } ?? SessionKind.lecture.displayName
        }
        return [session.kind.displayName, session.number.map(String.init)].compactMap(\.self).joined(separator: " ")
    }
}

/// One of a course's screens under it while one of them shows (mockup 08): Lectures, Slides,
/// Notes, Course Settings. The glyph is secondary, accent on the selected row; the text sits 66 pt
/// into the window, under the course name's indent.
struct CourseScreenSidebarRow: View {
    let item: SidebarItem
    let isSelected: Bool

    var body: some View {
        SidebarRowLabel(item.title) {
            // Outline glyphs (08): "display" would otherwise fill its screen.
            Image(systemName: item.systemImage)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .padding(.leading, courseScreenIndent)
    }
}

/// A course screen row's glyph sits under the course's name (mockup 08: centre 50 pt, text 66 pt).
private let courseScreenIndent: CGFloat = 17.5

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

