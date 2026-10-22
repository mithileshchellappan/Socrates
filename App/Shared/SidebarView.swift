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
/// (M6; on Notes, All Notes and each course with notes under it, mockup 04), Documents, Study,
/// Search; then the courses as one tree, the same on every screen, on the mockups' 29 pt pitch:
///
///     ▾ ● Data Centers
///         ▾ Lectures                3
///               L1 · Introduction           (its day in secondary text under the title)
///               L2 · Virtualization & IaaS
///               L3                          (the next class: "Mon 26 Oct, 10:15", secondary)
///           Slides
///           Materials (Mac), Notes, Progress, Course Settings
///     ▸ ● Computational Linguistics
///
/// Every course has a chevron and opens to its screens; Lectures has its own chevron (while it has
/// rows) and its count, and lists the course's lectures and its next class. A course and its
/// Lectures row open and close only by their chevrons (or ← and → on the selected row, as in an
/// outline) and stay as the student left them on every screen, kept per window
/// (`SidebarExpansion`), so the sidebar never jumps as screens change. The one exception: opening
/// a lecture (from anywhere) opens its course and its Lectures row, so the lecture's row shows.
/// Choosing a screen row opens that screen; the course's own row opens its Lectures. While the
/// selected row is folded away, the nearest row that shows stands for it (its Lectures row, else
/// its course), as an outline selects the parent of a row it folds. Recent searches on the Search
/// screen (07). The semester, the agent panel's launcher and Settings at the bottom (New Course on
/// a course's screen, 08). A file drag never moves the sidebar (no course or Lectures row opens or
/// closes, no row changes height, nothing spring-loads): the row under the cursor lights and files
/// dropped on a course, lecture or session row are filed exactly there (a course's screen rows and
/// its Notes and Mail lists stand for the course); over the screen, the predicted lecture or
/// session row lights if it shows (10, `filingDropTarget`). The whole sidebar is one drop area
/// (`filingDropZone`), so the window's HUD stays away while the cursor is over it.
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
    /// The open courses and Lectures rows (kept per window; the key is the one the open courses
    /// had before the tree, so a window keeps them; set up in `init`).
    @SceneStorage private var expansion: SidebarExpansion
    /// The Courses section, folded with its header's chevron (kept per window).
    @SceneStorage("sidebar.coursesExpanded") private var coursesExpanded = true
    /// Mail's lists under the Mail row, folded with the row's chevron (kept per window).
    @SceneStorage("sidebar.mailListsExpanded") private var mailListsExpanded = true
    /// The course whose own row was chosen: that row, not its Lectures row, shows the Lectures
    /// screen as selected (both open it), until another screen opens.
    @State private var courseRowPicked: Course.ID?

    /// The mockups' 228 pt glass panel (a 236 pt column with its inset).
    static let idealWidth: CGFloat = 228

    /// `expansion`: what a new window shows open (nothing; renders open some).
    init(selection: Binding<SidebarItem?>, center: FilingCenter, expansion: SidebarExpansion = SidebarExpansion()) {
        _selection = selection
        self.center = center
        _expansion = SceneStorage(wrappedValue: expansion, "sidebar.openCourses")
        // Sessions from yesterday on: enough to find each course's next one. Rounded to the day,
        // so the request stays the same while the window re-creates the sidebar (each keystroke
        // in the search field) and its observation is not restarted.
        let since = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86_400)
        _sessions = FetchAll(LectureSession.where { !$0.isCancelled && $0.endsAt.gte(since) }.order(by: \.startsAt))
    }

    var body: some View {
        let latestJobs = Self.latestJobs(jobs)
        let now = Date()
        let lectureRows = Dictionary(uniqueKeysWithValues: courses.map { course in
            let courseLectures = lectures.filter { $0.courseID == course.id }.sorted(by: Self.inOrder)
            return (course.id, LectureRows(lectures: courseLectures, next: nextSession(course.id, now: now)))
        })
        let shown = shownRow(selection)
        List(selection: listSelection) {
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
                            chevron(
                                isOpen: mailListsExpanded, width: 16,
                                label: mailListsExpanded ? Text("Hide Mailboxes") : Text("Show Mailboxes")
                            ) {
                                withAnimation(.snappy(duration: 0.2)) { mailListsExpanded.toggle() }
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
                        if case .course(let courseID) = scope {
                            // A course's list stands for its course: files dropped on it go there.
                            NavigationLink(value: SidebarItem.mailScope(scope)) {
                                MailScopeLabel(scope: scope)
                                    .padding(.leading, listChildIndent)
                            }
                            .filingDropTarget(.course(courseID), center: center, showsPrediction: false)
                        } else {
                            NavigationLink(value: SidebarItem.mailScope(scope)) {
                                MailScopeLabel(scope: scope)
                                    .padding(.leading, listChildIndent)
                            }
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
                        .padding(.leading, listChildIndent)
                    }
                    ForEach(notesCourses) { course in
                        NavigationLink(value: SidebarItem.notes(.course(course.id))) {
                            SidebarRowLabel(course.name) {
                                CourseDot(hex: course.colorHex, size: 9)
                            }
                            .padding(.leading, listChildIndent)
                        }
                        .filingDropTarget(.course(course.id), center: center, showsPrediction: false)
                    }
                }
            }

            // The header's chevron folds the courses (a drag of files leaves them as they are).
            Section(isExpanded: $coursesExpanded) {
                ForEach(courses) { course in
                    courseRow(course)
                    if expansion.showsScreens(of: course.id) {
                        let rows = lectureRows[course.id] ?? LectureRows()
                        // Mockup 08's screens, one level in, its settings among them.
                        ForEach(SidebarItem.courseScreens(course.id), id: \.self) { item in
                            screenRow(item, course: course.id, rows: rows, shown: shown)
                            if item == .courseLectures(course.id), expansion.showsLectures(of: course.id) {
                                // Mockup 03's rows, one level under Lectures.
                                ForEach(rows.lectures) { lecture in
                                    lectureRow(lecture, job: latestJobs[lecture.id])
                                }
                                if let next = rows.next {
                                    SessionSidebarRow(session: next)
                                        .filingDropTarget(.session(next.id), center: center)
                                }
                            }
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
        // ← and → fold the tree as in an outline (↑ and ↓ are the list's own).
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            fold(opening: press.key == .rightArrow, from: shown, rows: lectureRows)
        }
        #if os(macOS)
        // The mockups' rows, whatever System Settings' sidebar size: the small row (24 pt, 11 pt
        // text) with each row's 13 pt content 21 pt high gives their 29 pt pitch (`.medium` is 32).
        .environment(\.sidebarRowSize, .small)
        #endif
        // A file drag never opens a row's screen by hovering on it: the selection, and with it
        // the rows, stay put until the drop.
        .springLoadingBehavior(.disabled)
        // A bar, not an inset: long lists (Mail, a lecture's screen) scroll under it with the
        // scroll-edge effect instead of drawing through the semester; the hard edge cuts them off
        // at the footer's hairline.
        .safeAreaBar(edge: .bottom, spacing: 0) {
            footer
        }
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        // The whole sidebar is one drop area around its row targets: the window's HUD stays away
        // while files are over it, so only the row under the cursor lights.
        .filingDropZone(center)
        .navigationTitle("Socrates")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 200, ideal: Self.idealWidth, max: 320)
        #else
        .toolbar { SettingsToolbarItem() }
        #endif
        .onChange(of: openedLecture, initial: true) { _, opened in
            // Opening a lecture (from anywhere) opens its course and its Lectures row, so its row
            // shows; they stay open on the next screens. Nothing else moves.
            guard let opened else { return }
            var revealed = expansion
            revealed.reveal(lecturesOf: opened.courseID)
            if revealed != expansion { expansion = revealed }
        }
        .onChange(of: selection) { _, item in
            if let picked = courseRowPicked, item != .courseLectures(picked) { courseRowPicked = nil }
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

    /// What a course's Lectures row lists: its lectures in order, then its next class.
    struct LectureRows {
        var lectures: [Lecture] = []
        var next: LectureSession?

        var isEmpty: Bool { lectures.isEmpty && next == nil }
    }

    private func courseRow(_ course: Course) -> some View {
        let isOpen = expansion.showsScreens(of: course.id)
        return NavigationLink(value: SidebarItem.course(course.id)) {
            HStack(spacing: 8) {
                chevron(isOpen: isOpen, label: isOpen ? Text("Collapse \(course.name)") : Text("Expand \(course.name)")) {
                    setScreens(of: course.id, shown: !isOpen)
                }
                .padding(.trailing, -4)
                CourseDot(hex: course.colorHex, size: 9)
                Text(course.name)
                    .font(.body)
                    .lineLimit(1)
            }
            .frame(minHeight: SidebarRowLabel<EmptyView>.minHeight)
        }
        .filingDropTarget(.course(course.id), center: center)
        .contextMenu {
            // The confirmation names what goes; Edit ▸ Undo brings it back.
            Button("Delete Course…", role: .destructive) { center.requestDelete(.course(course.id)) }
        }
    }

    /// One of a course's screens (mockup 08), one level in: Lectures with its own chevron (while it
    /// has rows) and its count; the others keep the chevron's room, so the glyphs line up. Each
    /// stands for the course: files dropped on one go into it (a timetable into its settings).
    private func screenRow(_ item: SidebarItem, course: Course.ID, rows: LectureRows, shown: SidebarItem?) -> some View {
        let isLectures = item == .courseLectures(course)
        let isOpen = expansion.showsLectures(of: course)
        return NavigationLink(value: item) {
            HStack(spacing: 4) {
                if isLectures, !rows.isEmpty {
                    chevron(isOpen: isOpen, label: isOpen ? Text("Hide Lectures") : Text("Show Lectures")) {
                        setLectures(of: course, shown: !isOpen)
                    }
                } else {
                    Color.clear
                        .frame(width: 10, height: 16)
                }
                CourseScreenSidebarRow(item: item, isSelected: shown == item)
            }
            .padding(.leading, screenIndent)
        }
        .badge(isLectures ? rows.lectures.count : 0)
        .filingDropTarget(.course(course), center: center, showsPrediction: false)
    }

    private func lectureRow(_ lecture: Lecture, job: Job?) -> some View {
        NavigationLink(value: SidebarItem.lecture(lecture.id)) {
            LectureSidebarRow(lecture: lecture, job: job)
        }
        .filingDropTarget(.lecture(lecture.id), center: center)
        .contextMenu {
            if job?.state == .failed {
                Button("Retry Processing") { model.retryProcessing(lectureID: lecture.id) }
                Divider()
            }
            // The confirmation names what goes; Edit ▸ Undo brings it back.
            Button("Delete…", role: .destructive) { center.requestDelete(.lecture(lecture.id)) }
        }
    }

    /// An 8 pt tertiary chevron that opens and closes a row's children: a course's screens and its
    /// lectures before the row (10 pt), Mail's lists at the Mail row's end (16 pt).
    private func chevron(isOpen: Bool, width: CGFloat = 10, label: Text, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: width, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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

    // MARK: - Selection

    /// The list's selection: the row that shows the selected screen (`shownRow`). Choosing a row
    /// opens its screen (a course's own row, its Lectures).
    private var listSelection: Binding<SidebarItem?> {
        Binding {
            shownRow(selection)
        } set: { row in
            if case .course(let id)? = row { courseRowPicked = id } else { courseRowPicked = nil }
            selection = row
        }
    }

    /// The row that shows `item` as selected: its own, or while it is folded away the nearest row
    /// that shows (a lecture's Lectures row, else its course), as an outline selects the parent of
    /// a row it folds. The course's own row while it was the one chosen for its Lectures.
    private func shownRow(_ item: SidebarItem?) -> SidebarItem? {
        if case .lecture(let id)? = item, let courseID = lectures.first(where: { $0.id == id })?.courseID {
            if !expansion.showsScreens(of: courseID) { return .course(courseID) }
            return expansion.showsLectures(of: courseID) ? item : .courseLectures(courseID)
        }
        guard let courseID = item?.courseScreenID else { return item }
        if !expansion.showsScreens(of: courseID) || (courseRowPicked == courseID && item == .courseLectures(courseID)) {
            return .course(courseID)
        }
        return item
    }

    /// ← and → on the selected row (`row`), as in an outline: → opens a closed course or Lectures
    /// row; ← closes an open one, else goes to the row's parent (a lecture to its Lectures, a
    /// screen to its course). Every other row and key is the list's.
    private func fold(opening: Bool, from row: SidebarItem?, rows: [Course.ID: LectureRows]) -> KeyPress.Result {
        switch row {
        case .course(let id)?:
            guard opening != expansion.showsScreens(of: id) else { return .ignored }
            setScreens(of: id, shown: opening)
        case .courseLectures(let id)?:
            let isOpen = expansion.showsLectures(of: id)
            if opening {
                guard !isOpen, rows[id]?.isEmpty == false else { return .ignored }
                setLectures(of: id, shown: true)
            } else if isOpen {
                setLectures(of: id, shown: false)
            } else {
                listSelection.wrappedValue = .course(id)
            }
        case .lecture(let lectureID)?:
            guard !opening, let courseID = lectures.first(where: { $0.id == lectureID })?.courseID else { return .ignored }
            listSelection.wrappedValue = .courseLectures(courseID)
        case let screen?:
            // Slides, Materials, Notes, Progress, Course Settings.
            guard !opening, let courseID = screen.courseScreenID else { return .ignored }
            listSelection.wrappedValue = .course(courseID)
        case nil:
            return .ignored
        }
        return .handled
    }

    // MARK: - Expansion

    /// The lecture whose screen shows, with its course (once its row is read).
    private struct OpenedLecture: Equatable {
        var lectureID: Lecture.ID
        var courseID: Course.ID
    }

    private var openedLecture: OpenedLecture? {
        guard case .lecture(let id)? = selection, let lecture = lectures.first(where: { $0.id == id }) else { return nil }
        return OpenedLecture(lectureID: id, courseID: lecture.courseID)
    }

    /// A course's chevron (or ← →): its screens show or hide, the same on every screen.
    private func setScreens(of course: Course.ID, shown: Bool) {
        withAnimation(.snappy(duration: 0.2)) { expansion.setScreens(of: course, shown: shown) }
    }

    /// Its Lectures row's chevron (or ← →): its lectures and next class show or hide.
    private func setLectures(of course: Course.ID, shown: Bool) {
        withAnimation(.snappy(duration: 0.2)) { expansion.setLectures(of: course, shown: shown) }
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

/// A course's screen rows sit one level under it: their chevron's room under the course's dot,
/// the glyph under its name.
private let screenIndent: CGFloat = 14

/// Lecture and session rows sit one level under Lectures: their titles 14 pt past its title.
private let lectureIndent: CGFloat = 66

/// Mail's lists and Notes' courses under their row (mockups 04, 05): the glyph under its title.
private let listChildIndent: CGFloat = 17.5

/// "L2 · Virtualization & IaaS" over "Tue 13 Oct"; while it is processed, a small determinate
/// ring; a failed run, a warning glyph.
struct LectureSidebarRow: View {
    let lecture: Lecture
    let job: Job?

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(lecture))
                    .font(.body)
                    .lineLimit(1)
                if let heldAt = lecture.heldAt {
                    Text(heldAt.formatted(DayText.style()))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 4)
            ProcessingMark(job: job)
        }
        .padding(.leading, lectureIndent)
        // Two-line rows breathe (the same while files are dragged: the sidebar never moves).
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
    /// Lit as the place files being dragged in go (mockup 10): the title then reads as primary.
    @Environment(\.isFilingTarget) private var isFilingTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Self.title(session))
                .font(.body)
                .lineLimit(1)
            Text(verbatim: "\(DayText.day(session.startsAt)), \(SessionText().time(session.startsAt))")
                .font(.subheadline)
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(isFilingTarget ? .primary : .secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, lectureIndent)
        // Two-line rows breathe (the same while files are dragged: the sidebar never moves).
        .padding(.vertical, 3)
    }

    static func title(_ session: LectureSession) -> String {
        if session.kind == .lecture {
            return session.number.map { "L\($0)" } ?? SessionKind.lecture.displayName
        }
        return [session.kind.displayName, session.number.map(String.init)].compactMap(\.self).joined(separator: " ")
    }
}

/// One of a course's screens under it (mockup 08): Lectures, Slides, Materials, Notes, Progress,
/// Course Settings. The glyph is secondary, accent on the selected row.
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
