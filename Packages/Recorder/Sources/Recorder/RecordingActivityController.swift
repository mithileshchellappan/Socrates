#if os(iOS)
import ActivityKit
import Foundation
import RecorderActivity

/// Starts, updates and ends the recording's Live Activity. `Activity` is not Sendable, so it is
/// never stored: each call finds the activity of its recording among the app's activities.
enum RecordingActivityController {
    /// Requests the activity when Live Activities are on. Returns whether it started.
    @MainActor
    static func start(recordingID: UUID, state: RecordingActivityState) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        do {
            _ = try Activity.request(
                attributes: RecordingActivityAttributes(recordingID: recordingID),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            return true
        } catch {
            RecorderLog.recorder.notice("Live Activity not started: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    static func update(recordingID: UUID, state: RecordingActivityState) async {
        for activity in Activity<RecordingActivityAttributes>.activities where activity.attributes.recordingID == recordingID {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// Ends the recording's activity with its final state, dismissed at once.
    static func end(recordingID: UUID, state: RecordingActivityState?) async {
        for activity in Activity<RecordingActivityAttributes>.activities where activity.attributes.recordingID == recordingID {
            await activity.end(state.map { ActivityContent(state: $0, staleDate: nil) }, dismissalPolicy: .immediate)
        }
    }

    /// Ends every recording activity except `keeping` (left behind when the app was killed while
    /// recording; their buttons would act on nothing).
    static func endAll(keeping: UUID? = nil) async {
        for activity in Activity<RecordingActivityAttributes>.activities where activity.attributes.recordingID != keeping {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif
