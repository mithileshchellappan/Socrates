import StudyCore
import SwiftUI

/// What the main window shows: a top-level screen, a course's settings or a lecture (its review
/// screen).
enum SidebarItem: Hashable {
    case today
    case calendar
    case mail
    case search
    /// The course's row. Choosing it shows the course's screen, `courseSettings` (mockup 08: the
    /// course's own "Course Settings" row is the one selected).
    case course(Course.ID)
    case courseSettings(Course.ID)
    case lecture(Lecture.ID)

    static let destinations: [SidebarItem] = [.today, .calendar, .mail, .search]

    var title: String {
        switch self {
        case .today: String(localized: "Today")
        case .calendar: String(localized: "Calendar")
        case .mail: String(localized: "Mail")
        case .search: String(localized: "Search")
        case .course: String(localized: "Course")
        case .courseSettings: String(localized: "Course Settings")
        case .lecture: String(localized: "Lecture")
        }
    }

    /// What choosing this item shows: a course's row stands for its settings.
    var screen: SidebarItem {
        if case .course(let id) = self { return .courseSettings(id) }
        return self
    }

    /// The course whose screen this is.
    var settingsCourseID: Course.ID? {
        if case .courseSettings(let id) = self { return id }
        return nil
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .calendar: "calendar"
        case .mail: "envelope"
        case .search: "magnifyingglass"
        case .course: "books.vertical"
        case .courseSettings: "gearshape"
        case .lecture: "display"
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

/// Go: the four top-level screens (⌘1…⌘4) and Search Library (⌘F, focuses the toolbar field).
struct GoCommands: Commands {
    @FocusedValue(\.sidebarSelection) private var selection
    @FocusedValue(\.focusSearch) private var focusSearch
    @FocusedValue(\.screenHistory) private var history

    var body: some Commands {
        CommandMenu("Go") {
            // ⌘1 … ⌘4
            ForEach(Array(SidebarItem.destinations.enumerated()), id: \.element) { index, item in
                Button(item.title) { selection?.wrappedValue = item }
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
