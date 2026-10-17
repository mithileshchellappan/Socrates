import StudyCore
import SwiftUI

/// What the main window shows: a top-level screen, a course (its settings) or a lecture (its
/// review screen).
enum SidebarItem: Hashable {
    case today
    case calendar
    case mail
    case search
    case course(Course.ID)
    case lecture(Lecture.ID)

    static let destinations: [SidebarItem] = [.today, .calendar, .mail, .search]

    var title: String {
        switch self {
        case .today: String(localized: "Today")
        case .calendar: String(localized: "Calendar")
        case .mail: String(localized: "Mail")
        case .search: String(localized: "Search")
        case .course: String(localized: "Course")
        case .lecture: String(localized: "Lecture")
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .calendar: "calendar"
        case .mail: "envelope"
        case .search: "magnifyingglass"
        case .course: "books.vertical"
        case .lecture: "rectangle.on.rectangle"
        }
    }
}

extension FocusedValues {
    @Entry var sidebarSelection: Binding<SidebarItem?>?
    /// Focuses the toolbar search field of the key window.
    @Entry var focusSearch: (() -> Void)?
}

/// Go: the four top-level screens (⌘1…⌘4) and Search Library (⌘F, focuses the toolbar field).
struct GoCommands: Commands {
    @FocusedValue(\.sidebarSelection) private var selection
    @FocusedValue(\.focusSearch) private var focusSearch

    var body: some Commands {
        CommandMenu("Go") {
            // ⌘1 … ⌘4
            ForEach(Array(SidebarItem.destinations.enumerated()), id: \.element) { index, item in
                Button(item.title) { selection?.wrappedValue = item }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(selection == nil)
            }
            Divider()
            Button("Search Library") { focusSearch?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(focusSearch == nil)
        }
    }
}
