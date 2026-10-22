import Foundation
import RecorderActivity
import RecorderContract
#if os(iOS)
import ActivityKit
#endif

/// The recording's Live Activity, kept in step with the recorder's snapshot: requested when
/// recording starts, updated only when what it shows changes, ended with the final state.
/// Requests run one after another (`settled()` waits for them), so a quick run of changes never
/// leaves an older one on screen. `Activity` is not Sendable, so it is never stored: each request
/// finds the activity of its recording among the app's activities. Does nothing on macOS.
@MainActor
final class RecordingActivityController {
    /// The recording the activity was started for (nil: none is showing).
    private(set) var recordingID: RecordingID?
    private var shown: RecordingActivityState?
    private var tail: Task<Void, Never>?

    isolated deinit {
        tail?.cancel()
    }

    /// Requests the activity when Live Activities are on. Returns whether it started.
    @discardableResult
    func start(recordingID: RecordingID, state: RecordingActivityState) -> Bool {
        #if os(iOS)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        do {
            _ = try Activity.request(
                attributes: RecordingActivityAttributes(recordingID: recordingID),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            self.recordingID = recordingID
            shown = state
            return true
        } catch {
            RecorderLog.recorder.notice("Live Activity not started: \(String(describing: error), privacy: .public)")
            return false
        }
        #else
        return false
        #endif
    }

    /// The recordings whose activities are on screen, with the snapshot sequence each was last
    /// drawn from: after a relaunch, what an earlier run left.
    func showing() -> [RecordingID: Int] {
        #if os(iOS)
        var showing: [RecordingID: Int] = [:]
        for activity in Activity<RecordingActivityAttributes>.activities
        where activity.activityState == .active || activity.activityState == .stale {
            showing[activity.attributes.recordingID] = activity.content.state.sequence
        }
        return showing
        #else
        return [:]
        #endif
    }

    /// Follows the activity an earlier run started for `recordingID` (a recording taken up after
    /// a relaunch): the next `show` updates it.
    func adopt(_ recordingID: RecordingID) {
        self.recordingID = recordingID
        shown = nil
    }

    /// Shows `state` when it differs from what the activity shows; `force` sends it anyway (a
    /// button acted on a rendering the activity should no longer show).
    func show(_ state: RecordingActivityState, force: Bool = false) {
        guard let recordingID, force || !state.showsSame(as: shown) else { return }
        shown = state
        enqueue { await Self.update(recordingID: recordingID, state: state) }
    }

    /// Ends the activity with its final state, dismissed at once.
    func end(with state: RecordingActivityState?) {
        guard let recordingID else { return }
        self.recordingID = nil
        shown = nil
        enqueue { await Self.end(recordingID: recordingID, state: state) }
    }

    /// Ends every recording activity but the current one: those left behind when the app was
    /// killed while recording, whose buttons would act on nothing.
    func endStale() {
        let keeping = recordingID
        enqueue { await Self.endAll(keeping: keeping) }
    }

    /// Waits until every request so far has reached ActivityKit.
    func settled() async {
        await tail?.value
    }

    private func enqueue(_ request: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await request()
        }
    }

    // MARK: - ActivityKit

    private nonisolated static func update(recordingID: RecordingID, state: RecordingActivityState) async {
        #if os(iOS)
        for activity in Activity<RecordingActivityAttributes>.activities where activity.attributes.recordingID == recordingID {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        #endif
    }

    private nonisolated static func end(recordingID: RecordingID, state: RecordingActivityState?) async {
        #if os(iOS)
        for activity in Activity<RecordingActivityAttributes>.activities where activity.attributes.recordingID == recordingID {
            await activity.end(state.map { ActivityContent(state: $0, staleDate: nil) }, dismissalPolicy: .immediate)
        }
        #endif
    }

    private nonisolated static func endAll(keeping: RecordingID?) async {
        #if os(iOS)
        for activity in Activity<RecordingActivityAttributes>.activities where activity.attributes.recordingID != keeping {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        #endif
    }
}
