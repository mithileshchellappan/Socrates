import StudyCore
import SwiftUI

enum SidebarItem: Hashable {
    case today
    case calendar
    case mail
    case search
    case course(Course.ID)

    static let destinations: [SidebarItem] = [.today, .calendar, .mail, .search]

    var title: String {
        switch self {
        case .today: "Today"
        case .calendar: "Calendar"
        case .mail: "Mail"
        case .search: "Search"
        case .course: "Course"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .calendar: "calendar"
        case .mail: "tray"
        case .search: "magnifyingglass"
        case .course: "books.vertical"
        }
    }
}

extension FocusedValues {
    @Entry var sidebarSelection: Binding<SidebarItem?>?
}

struct GoCommands: Commands {
    @FocusedValue(\.sidebarSelection) private var selection

    var body: some Commands {
        CommandMenu("Go") {
            // ⌘1 … ⌘4
            ForEach(Array(SidebarItem.destinations.enumerated()), id: \.element) { index, item in
                Button(item.title) { selection?.wrappedValue = item }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(selection == nil)
            }
        }
    }
}
