import Foundation
import Observation
import RecorderActivity
import StudyCore

/// The iPhone's recorder (M7, docs/plan-m7.md §4, §5.1): one recording at a time over Capture's
/// `LiveLectureSession`, with slide stamps, the Live Activity and the outbox of phone captures
/// (`AppPaths.phoneCaptures`), which the student shares to the Mac as capture bundles. The app
/// owns one for its lifetime (recording outlives the screen) and calls `activate()` at launch.
///
/// Skeleton landed with the plan; workstream A builds it.
@MainActor
@Observable
public final class PhoneRecorder {
    public let services: StudyServices

    /// A recording is running (starting, recording or stopping): the shell's Record button shows
    /// it, and Record opens this recording instead of a new one.
    public private(set) var isRecording = false

    public init(services: StudyServices) {
        self.services = services
    }

    /// Registers the Live Activity buttons' handler (`RecorderControl.handler`). Call once at
    /// launch, before the first scene.
    public func activate() {
        RecorderControl.handler = { [weak self] command, recordingID in
            await self?.handle(command, recordingID: recordingID)
        }
    }

    private func handle(_ command: RecorderCommand, recordingID: UUID) async {
        _ = (command, recordingID)
    }
}
