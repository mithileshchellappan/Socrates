import CalendarSync
import Foundation
import StudyCore
import StudyUI
import SwiftUI

/// The Calendar & deadlines screen (mockup 06, docs/DESIGN.md §8.3): `CalendarScreen`,
/// `CalendarCommands`, `CalendarSidebarSection`, `CalendarVisibility` and `\.foreignCalendars`.
/// See Packages/CalendarUI/README.md.
public enum CalendarUIModule {
    public static let moduleName = "CalendarUI"
}

enum CalendarUILog {
    static let ui = Log.logger(category: "calendar-ui")
}

extension EnvironmentValues {
    /// The student's other calendars, read-only (the app installs the calendar mirror on the
    /// Mac). Nil: no other calendars, and the sidebar shows only "Study Portal".
    @Entry public var foreignCalendars: (any ForeignCalendarSource)?

    /// Where the screen puts its toolbar items and inspector: `.window` (the app: the window
    /// toolbar and the inspector column) or `.snapshot` (laid out inline, because off-screen
    /// rendering draws neither). Layout only; Calendar has no glass of its own.
    @Entry var calendarChrome: CalendarChrome = .window
}

enum CalendarChrome: Hashable, Sendable {
    case window
    case snapshot
}

/// Runs an effect from the screen (a `DeadlineActions` closure); failures are logged, the rows
/// show what landed.
@MainActor
func perform(_ label: String, _ work: @escaping @Sendable () async throws -> Void) {
    Task {
        do {
            try await work()
        } catch {
            CalendarUILog.ui.error("\(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
