import CoachUI
import StudyCore
import SwiftUI

/// `.practice(id)` (mc): a round (mockup 15) or a practice exam (18) by the session's kind; an
/// exam already handed in shows its results (19).
struct PracticeScreen: View {
    let sessionID: StudySession.ID
    let now: Date?
    @FetchOne private var session: StudySession?

    init(sessionID: StudySession.ID, now: Date?) {
        self.sessionID = sessionID
        self.now = now
        _session = FetchOne(StudySession.find(sessionID))
    }

    var body: some View {
        switch PracticeWindowState(session) {
        case .round?:
            PracticeView(sessionID: sessionID, now: now)
        case .exam?:
            PracticeExamView(sessionID: sessionID, now: now)
        case .examSubmitted?:
            PracticeExamResultsView(sessionID: sessionID)
        case nil:
            Color.clear
        }
    }
}

/// What a practice session asks of the window: a round hides the sidebar; an exam not yet handed
/// in also hides the agent panel, its launcher and the search field.
enum PracticeWindowState: Equatable {
    case round
    case exam
    case examSubmitted

    init?(_ session: StudySession?) {
        guard let session else { return nil }
        if session.kind == .exam {
            self = session.state == .submitted ? .examSubmitted : .exam
        } else {
            self = .round
        }
    }

    /// The exam is being written: nothing but the exam in the window.
    var isExam: Bool { self == .exam }
}

/// Follows the session `.practice(id)` shows (RootView's full-window state).
struct PracticeStateWatcher: View {
    @Binding var state: PracticeWindowState?
    @FetchOne private var session: StudySession?

    init(sessionID: StudySession.ID, state: Binding<PracticeWindowState?>) {
        _state = state
        _session = FetchOne(StudySession.find(sessionID))
    }

    var body: some View {
        Color.clear
            .onChange(of: PracticeWindowState(session), initial: true) { _, value in
                if state != value { state = value }
            }
    }
}
