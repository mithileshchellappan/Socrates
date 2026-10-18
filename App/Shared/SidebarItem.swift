import StudyCore
import StudyUI
import SwiftUI

/// What the main window shows: a top-level screen, one of a course's screens (mockup 08: its
/// lectures, slides, notes and settings) or a lecture (its review screen).
enum SidebarItem: Hashable {
    case today
    case calendar
    /// The Mail row. Choosing it shows the Inbox, `mailScope(.inbox)`, selected as the Mail row's
    /// "Inbox" child (mockup 05).
    case mail
    /// One of Mail's lists (mockup 05: Inbox, a course, University, Newsletters, Drafts, Sent),
    /// listed under the Mail row while one shows.
    case mailScope(MailScope)
    /// The Notes row (M6). Choosing it shows All Notes, `notes(.all)`, selected as the Notes row's
    /// "All Notes" child (as the Mail row stands for the Inbox).
    case notesRow
    /// The Notes screen (mockup 04): All Notes or one course's notes, listed under the Notes row
    /// while one shows.
    case notes(NotesScope)
    /// mc: Study (mockup 13), after Notes and before Search: the plan's current block, the courses'
    /// readiness and this week, the weakest topics.
    case study
    case search
    /// The course's row. Choosing it shows the course's screen, `courseSettings` (mockup 08: the
    /// course's own "Course Settings" row is the one selected).
    case course(Course.ID)
    case courseLectures(Course.ID)
    case courseSlides(Course.ID)
    case courseNotes(Course.ID)
    /// mc: a course's Progress (mockup 14), between its Notes and Course Settings.
    case courseProgress(Course.ID)
    case courseSettings(Course.ID)
    case lecture(Lecture.ID)
    /// mc: a practice round or a practice exam, full window (mockups 15, 18): the sidebar hides; an
    /// exam not yet submitted also hides the agent panel, its launcher and the search field.
    case practice(StudySession.ID)
    /// mc: a submitted practice exam's results (mockup 19), pushed on its course's Progress: the
    /// sidebar shows that course's Progress row selected, the toolbar Back.
    case practiceResults(StudySession.ID, course: Course.ID)

    /// The top-level rows, in sidebar order: Go ⌘1…⌘6.
    static let destinations: [SidebarItem] = [.today, .calendar, .mail, .notesRow, .study, .search]

    /// A course's own screens, in sidebar order (mockups 08, 14).
    static func courseScreens(_ id: Course.ID) -> [SidebarItem] {
        [.courseLectures(id), .courseSlides(id), .courseNotes(id), .courseProgress(id), .courseSettings(id)]
    }

    var title: String {
        switch self {
        case .today: String(localized: "Today")
        case .calendar: String(localized: "Calendar")
        case .mail, .mailScope: String(localized: "Mail")
        case .notesRow, .notes: String(localized: "Notes")
        case .study: String(localized: "Study")
        case .search: String(localized: "Search")
        case .course: String(localized: "Course")
        case .courseLectures: String(localized: "Lectures")
        case .courseSlides: String(localized: "Slides")
        case .courseNotes: String(localized: "Notes")
        case .courseProgress: String(localized: "Progress")
        case .courseSettings: String(localized: "Course Settings")
        case .lecture: String(localized: "Lecture")
        case .practice: String(localized: "Practice")
        case .practiceResults: String(localized: "Practice exam")
        }
    }

    /// The sidebar row that shows as selected: a practice exam's results are pushed on its course's
    /// Progress (mockup 19).
    var sidebarRow: SidebarItem {
        if case .practiceResults(_, let course) = self { return .courseProgress(course) }
        return self
    }

    /// A practice round or exam: the window shows nothing but it (the sidebar hides).
    var isPractice: Bool {
        if case .practice = self { return true }
        return false
    }

    /// What choosing this item shows: a course's row stands for its settings, the Mail row for
    /// the Inbox, the Notes row for All Notes.
    var screen: SidebarItem {
        if case .course(let id) = self { return .courseSettings(id) }
        if self == .mail { return .mailScope(.inbox) }
        if self == .notesRow { return .notes(.all) }
        return self
    }

    /// Mail's lists (the Mail row stands for the Inbox).
    var isMail: Bool {
        switch self {
        case .mail, .mailScope: true
        default: false
        }
    }

    /// The Notes screen under the Notes row (All Notes or a course; M6).
    var isNotes: Bool {
        switch self {
        case .notesRow, .notes: true
        default: false
        }
    }

    /// Whose question the toolbar search field holds: Mail and Notes filter their own list in
    /// place ("Search mail", "Search notes"); everywhere else it searches the library.
    var searchOwner: SearchOwner {
        if isMail { return .mail }
        if isNotes { return .notes }
        return .library
    }

    enum SearchOwner {
        case library
        case mail
        case notes
    }

    /// The course whose screen this is (its lectures, slides, notes or settings).
    var courseScreenID: Course.ID? {
        switch self {
        case .course(let id), .courseLectures(let id), .courseSlides(let id), .courseNotes(let id),
             .courseProgress(let id), .courseSettings(let id), .practiceResults(_, let id): id
        case .today, .calendar, .mail, .mailScope, .notesRow, .notes, .study, .search, .lecture, .practice: nil
        }
    }

    /// Today, Calendar, Mail, Notes, Study and Search: one shared detail stack, and the toolbar
    /// search field on all but Calendar and Study (mockups 06, 13).
    var isTopLevel: Bool {
        switch self {
        case .today, .calendar, .mail, .mailScope, .notesRow, .notes, .study, .search: true
        case .course, .courseLectures, .courseSlides, .courseNotes, .courseProgress, .courseSettings, .lecture,
             .practice, .practiceResults: false
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .calendar: "calendar"
        case .mail, .mailScope: "envelope"
        case .notesRow: "note.text"
        // All Notes (mockup 04's `i-doc`); a course's child draws its dot instead.
        case .notes: "doc.text"
        case .study: "brain"
        case .search: "magnifyingglass"
        case .course: "books.vertical"
        case .courseLectures: "waveform"
        case .courseSlides: "display"
        case .courseNotes: "doc.text"
        case .courseProgress: "chart.bar"
        case .courseSettings: "gearshape"
        case .lecture: "display"
        case .practice: "brain"
        case .practiceResults: "chart.bar"
        }
    }
}

extension FocusedValues {
    @Entry var sidebarSelection: Binding<SidebarItem?>?
    /// Focuses the toolbar search field of the key window.
    @Entry var focusSearch: (() -> Void)?
    /// The key window's Back and Forward through the screens it showed.
    @Entry var screenHistory: ScreenHistoryActions?
}

/// Back and Forward through the screens a window showed (Go menu, mockup 08's toolbar chevrons).
struct ScreenHistoryActions {
    var canGoBack: Bool
    var canGoForward: Bool
    var back: () -> Void
    var forward: () -> Void
}

/// The screens a window showed before and after the current one.
struct ScreenHistory: Equatable {
    private(set) var back: [SidebarItem] = []
    private(set) var forward: [SidebarItem] = []
    /// The move `step` is making, so the selection change it causes is not recorded as a visit.
    private var moving: SidebarItem?

    static let limit = 50

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// The window went from `old` to `new`, by any route but Back or Forward.
    mutating func visit(from old: SidebarItem?, to new: SidebarItem?) {
        if let moving, moving == new {
            self.moving = nil
            return
        }
        moving = nil
        guard let old, let new, old != new else { return }
        // A round or an exam is not gone back to (it ended, or its results stand for it).
        if old.isPractice {
            forward.removeAll()
            return
        }
        back.append(old)
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward.removeAll()
    }

    /// The screen Back (or Forward) shows instead of `current`.
    mutating func step(back goesBack: Bool, from current: SidebarItem?) -> SidebarItem? {
        guard let target = goesBack ? back.popLast() : forward.popLast() else { return nil }
        if let current {
            if goesBack { forward.append(current) } else { back.append(current) }
        }
        moving = target
        return target
    }
}

/// Go: the six top-level screens (⌘1…⌘6: Today, Calendar, Mail, Notes, Study, Search) and Search
/// Library (⌘F, focuses the toolbar field).
struct GoCommands: Commands {
    @FocusedValue(\.sidebarSelection) private var selection
    @FocusedValue(\.focusSearch) private var focusSearch
    @FocusedValue(\.screenHistory) private var history

    var body: some Commands {
        CommandMenu("Go") {
            // ⌘1 … ⌘6
            ForEach(Array(SidebarItem.destinations.enumerated()), id: \.element) { index, item in
                Button(item.title) { selection?.wrappedValue = item.screen }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(selection == nil)
            }
            Divider()
            Button("Back") { history?.back() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(history?.canGoBack != true)
            Button("Forward") { history?.forward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(history?.canGoForward != true)
            Divider()
            Button("Search Library") { focusSearch?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(focusSearch == nil)
        }
    }
}
