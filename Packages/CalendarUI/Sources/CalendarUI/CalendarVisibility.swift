import Foundation
import Observation
import SwiftUI

/// Which calendars the week grid draws, per device (as Calendar.app): "Socrates" (the
/// library's sessions and deadlines, on by default) and the student's other calendars (off
/// until checked). The sidebar's checkboxes (`CalendarSidebarSection`) change it; the app keeps
/// one and installs it as `\.calendarVisibility`.
@MainActor
@Observable
public final class CalendarVisibility {
    /// The app's own sessions and deadlines in the grid.
    public var showsOwnCalendar: Bool {
        didSet { defaults.set(showsOwnCalendar, forKey: Self.ownCalendarKey) }
    }

    /// The other calendars whose events the grid draws (read-only).
    public private(set) var checkedCalendarIDs: Set<String>

    @ObservationIgnored private let defaults: UserDefaults

    static let ownCalendarKey = "StudyPortal.calendar.showsStudyPortal"
    static let checkedKey = "StudyPortal.calendar.checkedCalendars"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsOwnCalendar = defaults.object(forKey: Self.ownCalendarKey) as? Bool ?? true
        checkedCalendarIDs = Set(defaults.stringArray(forKey: Self.checkedKey) ?? [])
    }

    public func isChecked(_ calendarID: String) -> Bool {
        checkedCalendarIDs.contains(calendarID)
    }

    public func setChecked(_ calendarID: String, _ isChecked: Bool) {
        if isChecked {
            checkedCalendarIDs.insert(calendarID)
        } else {
            checkedCalendarIDs.remove(calendarID)
        }
        defaults.set(checkedCalendarIDs.sorted(), forKey: Self.checkedKey)
    }
}

extension EnvironmentValues {
    /// The device's calendar choices; nil draws "Socrates" and no other calendar.
    @Entry public var calendarVisibility: CalendarVisibility?
}
