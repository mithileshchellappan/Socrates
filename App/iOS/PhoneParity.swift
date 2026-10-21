#if DEBUG
import ChatUI
import PhoneUI
import Recorder
import RecorderActivity
import StudyCore
import SwiftUI

/// Debug builds only: opens the iPhone app on one screen of a library copy, for simulator shots
/// compared with mockups 09, 16 and the agent panel's §7 (docs/plan-m7.md §7.3):
///
///     SIMCTL_CHILD_SOCRATES_DATA_ROOT=<library copy> \
///         xcrun simctl launch <simulator> <your bundle id> -phoneParity <route>
///
/// Routes: `recorder` (DC Lecture 2 at slide 17 of 88, 38:41 in), `recorder-after-stop` (the
/// finished capture with Share and the outbox), `activity` (the Live Activity's Lock Screen view
/// on a dark wallpaper; the real Live Activity starts too, for the Lock Screen and the Dynamic
/// Island once the app is in the background), `today` (Fri 23 Oct 2026, 12:47), `sheet` /
/// `sheet-small` and `sheet-large` (the agent sheet on "F1 on the board"), `round` (the plan
/// card's round started, its first question), `round-answered` (the same, its first question
/// answered right through the phone's coach, as after a tap). Nothing records (no microphone), nothing is sent,
/// nothing runs in the background; `SOCRATES_DATA_ROOT` is required.
enum PhoneParity {
    enum Route: String {
        case recorder
        case recorderAfterStop = "recorder-after-stop"
        case activity
        case today
        case sheet
        case sheetSmall = "sheet-small"
        case sheetLarge = "sheet-large"
        case round
        case roundAnswered = "round-answered"
    }

    struct Failure: Error, LocalizedError {
        var errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// `-phoneParity <route>` (the launch argument lands in the argument domain of the defaults).
    static let route: Route? = UserDefaults.standard.string(forKey: "phoneParity").flatMap(Route.init(rawValue:))

    /// The renders' "now": Friday 23 October 2026, 12:47 (mockups 16 and §7).
    static let now: Date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12, minute: 47)) ?? Date()

    /// The library copy named by `SOCRATES_DATA_ROOT`; no Keychain.
    static func services() throws -> StudyServices {
        guard let root = AppPaths.rootOverride() else {
            throw Failure("Phone parity needs SOCRATES_DATA_ROOT=<library copy>")
        }
        let paths = AppPaths(root: root)
        try paths.createDirectories()
        return StudyServices(
            paths: paths,
            database: try StudyDatabase.open(at: paths.database),
            blobs: BlobStore(root: paths.blobs),
            secrets: InMemorySecretStore()
        )
    }
}

/// The routed screen of `PhoneParity`.
struct PhoneParityView: View {
    let model: AppModel
    @State private var launch: PhoneLaunch?
    @State private var card: RecordingActivityState?
    @State private var failure: String?

    var body: some View {
        Group {
            if let card {
                ActivityParityView(state: card)
            } else if let launch {
                PhoneRootView(launch: launch)
            } else if let failure {
                ContentUnavailableView("Parity", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                Color.clear
            }
        }
        .environment(model)
        .task { await prepare() }
    }

    private func prepare() async {
        guard let route = PhoneParity.route else { return }
        guard let services = model.services else {
            failure = model.launchError ?? "Library unavailable"
            return
        }
        model.fixedNow = PhoneParity.now
        do {
            switch route {
            case .recorder:
                launch = PhoneLaunch(cover: .recorder, recorder: try await PhoneRecorder.preview(services: services))
            case .recorderAfterStop:
                launch = PhoneLaunch(cover: .recorder, recorder: try await PhoneRecorder.preview(services: services, stopped: true))
            case .activity:
                let recorder = try await PhoneRecorder.preview(services: services, startsActivity: true)
                guard let state = recorder.liveActivityState else { throw PhoneParity.Failure("No Live Activity state") }
                card = state
            case .today:
                launch = PhoneLaunch()
            case .sheet, .sheetSmall:
                // Mockup §7 small: the photo question and its answer over Today.
                launch = PhoneLaunch(
                    agentLaunch: AgentSheetLaunch(detent: .small, conversationID: try conversation(services), exchanges: 0..<1, now: PhoneParity.now),
                    showsAgent: true
                )
            case .sheetLarge:
                launch = PhoneLaunch(
                    agentLaunch: AgentSheetLaunch(detent: .large, conversationID: try conversation(services), now: PhoneParity.now.addingTimeInterval(120)),
                    showsAgent: true
                )
            case .round:
                launch = PhoneLaunch(cover: .round(try await round(services)))
            case .roundAnswered:
                let id = try await round(services)
                try await answerRight(id, services)
                launch = PhoneLaunch(cover: .round(id))
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The agent panel mockup §7's conversation (`tools/parity/seed --m7-sample`).
    private func conversation(_ services: StudyServices) throws -> AgentConversation.ID {
        let found = try services.database.read { db in
            try AgentConversation.where { $0.title.eq("F1 on the board") }.fetchOne(db)
        }
        guard let found else { throw PhoneParity.Failure("No conversation “F1 on the board”") }
        return found.id
    }

    /// The plan card's round on the render's day, started as Start starts it.
    private func round(_ services: StudyServices) async throws -> StudySession.ID {
        guard let coach = model.coach else { throw PhoneParity.Failure("No coach") }
        let today = CalendarDay(PhoneParity.now, in: .current)
        let blocks = try await services.database.read { db in try StudyBlock.order(by: \.sortOrder).fetchAll(db) }
        guard let block = blocks.first(where: { $0.day == today && $0.kind == .round && $0.state.isOpen }) else {
            throw PhoneParity.Failure("No round planned on \(today)")
        }
        guard case .session(let id) = try await coach.start(block: block.id) else {
            throw PhoneParity.Failure("The round did not start")
        }
        return id
    }
}

extension PhoneParityView {
    /// Answers the round's current question with its right choice (graded in code, as a tap).
    fileprivate func answerRight(_ id: StudySession.ID, _ services: StudyServices) async throws {
        guard let coach = model.coach,
              let questionID = try await services.records.fetch(StudySession.self, id: id)?.currentQuestionID,
              let right = try await services.records.fetch(StudyQuestion.self, id: questionID)?.correctChoice else {
            throw PhoneParity.Failure("The round's first question has no right choice")
        }
        try await coach.answer(.choice(right), to: questionID, in: id, seconds: 9)
    }
}

/// The Live Activity's Lock Screen view (Widgets/Shared) on a dark wallpaper, where the Lock
/// Screen draws it.
private struct ActivityParityView: View {
    let state: RecordingActivityState

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.12, blue: 0.22), Color(red: 0.03, green: 0.03, blue: 0.06)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            VStack(spacing: 0) {
                Text(PhoneParity.now, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 70)
                Text(PhoneParity.now, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())
                    .font(.system(size: 92, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                RecordingLockScreenParityCard(state: state, recordingID: UUID())
                    .environment(\.colorScheme, .dark)
                    .padding(.bottom, 120)
            }
        }
    }
}
#endif
