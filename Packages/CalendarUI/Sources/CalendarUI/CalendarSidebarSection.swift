import CalendarSync
import StudyUI
import SwiftUI

/// The sidebar's calendar checkboxes while Calendar is selected (docs/DESIGN.md §6.2, mockup 06),
/// placed by the app after Courses, inside its sidebar `List`: one section per account, as
/// Calendar.app, the app's own calendar's account first ("iCloud") with "Study Portal" (the
/// library's sessions and deadlines; on by default) and that account's other calendars (off by
/// default, read-only). Choices are kept per device (`\.calendarVisibility`).
public struct CalendarSidebarSection: View {
    @Environment(\.foreignCalendars) private var source
    @Environment(\.calendarVisibility) private var visibility
    @State private var list = ForeignCalendarList.empty

    public init() {}

    public var body: some View {
        ForEach(CalendarSidebarGroup.groups(list)) { group in
            Section {
                if group.holdsStudyPortal {
                    Toggle(isOn: Binding(
                        get: { visibility?.showsStudyPortal ?? true },
                        set: { visibility?.showsStudyPortal = $0 }
                    )) {
                        Text(verbatim: "Study Portal")
                    }
                    .modifier(CalendarCheckbox())
                }
                ForEach(group.calendars) { calendar in
                    Toggle(isOn: Binding(
                        get: { visibility?.isChecked(calendar.id) ?? false },
                        set: { visibility?.setChecked(calendar.id, $0) }
                    )) {
                        Text(verbatim: calendar.title)
                    }
                    .modifier(CalendarCheckbox())
                    .tint(Color(hex: calendar.colorHex) ?? .accentColor)
                }
            } header: {
                Text(verbatim: group.title)
                    .padding(.leading, 2)
            }
        }
        .task(id: source == nil) {
            list = await source?.foreignCalendars() ?? .empty
        }
    }
}

/// A checkbox row on the sidebar's pitch.
private struct CalendarCheckbox: ViewModifier {
    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif
            .lineLimit(1)
            .frame(minHeight: SidebarRowLabel<EmptyView>.minHeight)
    }
}

/// One account's section in the sidebar.
struct CalendarSidebarGroup: Identifiable, Hashable {
    var title: String
    var holdsStudyPortal: Bool
    var calendars: [ForeignCalendar]

    var id: String { title }

    /// The own account first (with "Study Portal" and its other calendars), then the others in
    /// the store's order. Without access: one section with "Study Portal" alone.
    static func groups(_ list: ForeignCalendarList) -> [CalendarSidebarGroup] {
        let ownTitle = list.ownSourceTitle ?? String(localized: "Calendars")
        var groups = [CalendarSidebarGroup(title: ownTitle, holdsStudyPortal: true, calendars: [])]
        for calendar in list.calendars {
            let title = calendar.sourceTitle.isEmpty ? ownTitle : calendar.sourceTitle
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].calendars.append(calendar)
            } else {
                groups.append(CalendarSidebarGroup(title: title, holdsStudyPortal: false, calendars: [calendar]))
            }
        }
        return groups
    }
}
