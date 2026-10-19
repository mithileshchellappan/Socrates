import SwiftUI

/// The iPhone's tabs (mockups 09 and 16: "Four tabs, as approved").
public enum PhoneTab: String, Hashable, Sendable, CaseIterable {
    case today
    case courses
    case calendar
    case mail
}

/// The iPhone app's root (M7, docs/plan-m7.md §5.2, DESIGN 6.7, 8.5): the floating system tab bar
/// (Today, Courses, Calendar, Mail), the separate round red Record button beside it, each tab in
/// its own navigation stack with a large title, and the agent bubble beside search in each tab's
/// header while the agent sheet is available (`\.agentPanelActions.isAvailable`: only with iCloud
/// sync). The app passes the screens in and presents the recorder on `record`.
///
/// Skeleton landed with the plan; workstream B builds it.
public struct PhoneShell<Today: View, Courses: View, Calendar: View, Mail: View>: View {
    @Binding private var selection: PhoneTab
    private let isRecording: Bool
    private let record: () -> Void
    private let today: Today
    private let courses: Courses
    private let calendar: Calendar
    private let mail: Mail

    /// - Parameters:
    ///   - isRecording: a recording runs (the Record button shows it).
    ///   - record: opens the recorder (a new recording, or the one running).
    public init(
        selection: Binding<PhoneTab>,
        isRecording: Bool,
        record: @escaping () -> Void,
        @ViewBuilder today: () -> Today,
        @ViewBuilder courses: () -> Courses,
        @ViewBuilder calendar: () -> Calendar,
        @ViewBuilder mail: () -> Mail
    ) {
        _selection = selection
        self.isRecording = isRecording
        self.record = record
        self.today = today()
        self.courses = courses()
        self.calendar = calendar()
        self.mail = mail()
    }

    public var body: some View {
        TabView(selection: $selection) {
            Tab("Today", systemImage: "sun.max", value: PhoneTab.today) { today }
            Tab("Courses", systemImage: "books.vertical", value: PhoneTab.courses) { courses }
            Tab("Calendar", systemImage: "calendar", value: PhoneTab.calendar) { calendar }
            Tab("Mail", systemImage: "tray", value: PhoneTab.mail) { mail }
        }
        .overlay(alignment: .bottomTrailing) {
            Button("Record", systemImage: isRecording ? "record.circle.fill" : "record.circle", action: record)
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
                .padding()
        }
    }
}
