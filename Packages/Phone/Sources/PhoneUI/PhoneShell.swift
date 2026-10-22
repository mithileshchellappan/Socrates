import ChatUI
import RecorderContract
import StudyCore
import StudyUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The iPhone's tabs (mockups 09 and 16: "Four tabs, as approved").
public enum PhoneTab: String, Hashable, Sendable, CaseIterable {
    case today
    case courses
    case calendar
    case mail

    /// The tab's title, also its screen's large title.
    public var title: String {
        switch self {
        case .today: String(localized: "Today")
        case .courses: String(localized: "Courses")
        case .calendar: String(localized: "Calendar")
        case .mail: String(localized: "Mail")
        }
    }

    /// The tab bar's glyph (DESIGN 3.5).
    public var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .courses: "books.vertical"
        case .calendar: "calendar"
        case .mail: "tray"
        }
    }

    /// What the agent sheet knows of the tab when its screen publishes nothing (`.agentContext`).
    var agentContext: AgentContext {
        switch self {
        case .today: .today
        case .courses: AgentContext(screen: .other)
        case .calendar: AgentContext(screen: .calendar)
        case .mail: AgentContext(screen: .mail)
        }
    }
}

/// The iPhone app's root (M7, docs/plan-m7.md §5.2, DESIGN 6.7, 8.5; mockups 09 and 16, agent
/// panel mockup §7): the floating system tab bar (Today, Courses, Calendar, Mail) and the
/// separate round Record button beside it (glass, a red glyph; a waveform while a recording runs,
/// a secondary `pause.fill` while it is paused; it opens the recorder either way), each tab in its own navigation stack with a large title,
/// and in each tab's header search and the agent bubble (`bubble.left`, only while
/// `\.agentPanelActions.isAvailable`: with iCloud sync), which presents the agent sheet. The app
/// passes the screens in and presents the recorder on `record`.
///
/// The Record button is the tab bar's separate circular slot (iOS 26 draws a `.search`-role tab
/// there, beside the bar): choosing it never selects it, it calls `record`.
public struct PhoneShell<Today: View, Courses: View, Calendar: View, Mail: View>: View {
    @Binding private var selection: PhoneTab
    private let recordingPhase: RecorderSnapshot.Phase?
    private let record: () -> Void
    private let search: (() -> Void)?
    private let agentLaunch: AgentSheetLaunch?
    private let today: Today
    private let courses: Courses
    private let calendar: Calendar
    private let mail: Mail

    @Environment(\.agentPanelActions) private var agentActions
    @State private var showsAgent: Bool
    /// What each tab's screen publishes for the agent (`.agentContext`), and Record's taps.
    @State private var shell = ShellModel()

    /// - Parameters:
    ///   - recordingPhase: the recorder's phase (`PhoneRecorder.snapshot`), nil when nothing
    ///     records: the Record slot shows it.
    ///   - record: opens the recorder (a new recording, or the one running).
    ///   - search: the header's search button (nil: none).
    ///   - agentLaunch: renders: the agent sheet open from the start at this detent and
    ///     conversation (only while the agent is available).
    public init(
        selection: Binding<PhoneTab>,
        recordingPhase: RecorderSnapshot.Phase?,
        record: @escaping () -> Void,
        search: (() -> Void)? = nil,
        agentLaunch: AgentSheetLaunch? = nil,
        @ViewBuilder today: () -> Today,
        @ViewBuilder courses: () -> Courses,
        @ViewBuilder calendar: () -> Calendar,
        @ViewBuilder mail: () -> Mail
    ) {
        _selection = selection
        self.recordingPhase = recordingPhase
        self.record = record
        self.search = search
        self.agentLaunch = agentLaunch
        self.today = today()
        self.courses = courses()
        self.calendar = calendar()
        self.mail = mail()
        _showsAgent = State(initialValue: agentLaunch != nil)
    }

    public var body: some View {
        let shows = $showsAgent
        let available = agentActions.isAvailable
        tabs
            .sheet(isPresented: Binding(get: { shows.wrappedValue && available }, set: { shows.wrappedValue = $0 })) {
                AgentSheet(context: shell.byTab[selection] ?? selection.agentContext, launch: agentLaunch ?? AgentSheetLaunch())
            }
            .onChange(of: shell.recordTaps) { record() }
    }

    // MARK: Tabs

    @ViewBuilder
    private var tabs: some View {
        #if os(iOS)
        let selection = $selection
        let shell = shell
        TabView(selection: Binding<ShellTab>(
            get: { .tab(selection.wrappedValue) },
            set: { picked in
                switch picked {
                case .tab(let tab): selection.wrappedValue = tab
                // The separate slot is an action: the selection stays.
                case .record: shell.recordTaps += 1
                }
            }
        )) {
            Tab(PhoneTab.today.title, systemImage: PhoneTab.today.systemImage, value: ShellTab.tab(.today)) { stack(.today) { today } }
            Tab(PhoneTab.courses.title, systemImage: PhoneTab.courses.systemImage, value: ShellTab.tab(.courses)) { stack(.courses) { courses } }
            Tab(PhoneTab.calendar.title, systemImage: PhoneTab.calendar.systemImage, value: ShellTab.tab(.calendar)) { stack(.calendar) { calendar } }
            Tab(PhoneTab.mail.title, systemImage: PhoneTab.mail.systemImage, value: ShellTab.tab(.mail)) { stack(.mail) { mail } }
            Tab(value: ShellTab.record, role: .search) {
                Color.clear
            } label: {
                Label {
                    Text(recordSlot.title)
                } icon: {
                    Self.recordImage(recordSlot)
                }
            }
        }
        #else
        // macOS compiles it (the look is iOS): a plain tab view with Record over it.
        TabView(selection: $selection) {
            Tab(PhoneTab.today.title, systemImage: PhoneTab.today.systemImage, value: PhoneTab.today) { stack(.today) { today } }
            Tab(PhoneTab.courses.title, systemImage: PhoneTab.courses.systemImage, value: PhoneTab.courses) { stack(.courses) { courses } }
            Tab(PhoneTab.calendar.title, systemImage: PhoneTab.calendar.systemImage, value: PhoneTab.calendar) { stack(.calendar) { calendar } }
            Tab(PhoneTab.mail.title, systemImage: PhoneTab.mail.systemImage, value: PhoneTab.mail) { stack(.mail) { mail } }
        }
        .overlay(alignment: .bottomTrailing) {
            Button(action: record) {
                Label(recordSlot.title, systemImage: recordSlot.systemImage)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(recordSlot == .paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .frame(width: 60, height: 60)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .padding(16)
        }
        #endif
    }

    /// A tab's own navigation stack: its large title, search and the agent bubble in the header,
    /// and what its screen publishes for the agent.
    private func stack(_ tab: PhoneTab, @ViewBuilder content: () -> some View) -> some View {
        let shell = shell
        return NavigationStack {
            content()
                .onPreferenceChange(AgentContextPreferenceKey.self) { source in
                    Task { @MainActor in shell.byTab[tab] = source.map { tab.agentContext.merging($0.context) } }
                }
                .navigationTitle(tab.title)
                #if os(iOS)
                .toolbarTitleDisplayMode(.large)
                #endif
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if let search {
                            Button(action: search) {
                                Label("Search", systemImage: "magnifyingglass")
                            }
                        }
                        if agentActions.isAvailable {
                            Button {
                                showsAgent = true
                            } label: {
                                Label(showsAgent ? "Hide Chat" : "Show Chat", systemImage: "bubble.left")
                            }
                            // Tinted while the sheet is open (mockup §7 `.gcirc.on`).
                            .tint(showsAgent ? Color.accentColor : nil)
                        }
                    }
                }
        }
    }

    private var recordSlot: RecordSlot { RecordSlot(recordingPhase) }

    /// The Record slot's glyph (a tab bar draws its glyphs as templates otherwise): the red
    /// record dot (`circle.fill`), a red waveform while a recording runs, `pause.fill` in the
    /// secondary colour while it is paused.
    private static func recordImage(_ slot: RecordSlot) -> Image {
        #if os(iOS)
        let color: UIColor = slot == .paused ? .secondaryLabel : .systemRed
        if let image = UIImage(systemName: slot.systemImage)?.withTintColor(color, renderingMode: .alwaysOriginal) {
            return Image(uiImage: image)
        }
        #endif
        return Image(systemName: slot.systemImage)
    }
}

/// What the Record slot shows for the recorder's phase.
private enum RecordSlot: Equatable {
    case record, recording, paused

    init(_ phase: RecorderSnapshot.Phase?) {
        switch phase {
        case .recording?, .stopping?: self = .recording
        case .paused?: self = .paused
        case .stopped?, nil: self = .record
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .record: "Record"
        case .recording: "Recording"
        case .paused: "Paused"
        }
    }

    var systemImage: String {
        switch self {
        case .record: "circle.fill"
        case .recording: "waveform"
        case .paused: "pause.fill"
        }
    }
}

/// What each tab's screen publishes for the agent sheet (`.agentContext`), and the Record slot's
/// taps (the shell calls `record` for each).
@MainActor
@Observable
final class ShellModel {
    var byTab: [PhoneTab: AgentContext] = [:]
    var recordTaps = 0
}

/// The tab view's selection: the four tabs, and the separate Record slot (an action).
private enum ShellTab: Hashable {
    case tab(PhoneTab)
    case record
}
