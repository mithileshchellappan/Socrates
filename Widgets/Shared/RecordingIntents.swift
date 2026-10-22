#if os(iOS)
import AppIntents
import Foundation
import RecorderActivity
import RecorderContract

// The Live Activity's buttons (M7, docs/plan-m7.md §4; PRD "iPhone recording"): Pause/Resume,
// Next Slide and Stop Recording. `LiveActivityIntent`s run in the app's process, so this file is
// compiled into both the app (iOS) and the widget extension (Apple's requirement for Live
// Activity buttons); in the app they send a `RecorderCommand` through `RecorderControl`.
//
// Each carries the recording and the snapshot sequence its button was drawn for. The command's
// id is derived from them (`RecorderCommand.rendered`), so the system running one tap twice, or
// two taps on one rendering, acts once. `sequence` defaults to 0, so a tap on a rendering from
// before it existed still decodes.

/// Pauses the recording the activity was drawn for: the microphone goes off until Resume.
struct PauseRecordingIntent: LiveActivityIntent {
    nonisolated static let title: LocalizedStringResource = "Pause Recording"
    nonisolated static let isDiscoverable = false

    @Parameter(title: "Recording")
    var recordingID: String

    @Parameter(title: "Sequence", default: 0)
    var sequence: Int

    init() {}

    init(recordingID: RecordingID, sequence: Int) {
        self.recordingID = recordingID.uuidString
        self.sequence = sequence
    }

    func perform() async throws -> some IntentResult {
        if let id = RecordingID(uuidString: recordingID) {
            await RecorderControl.perform(.rendered(.pause, recordingID: id, sequence: sequence))
        }
        return .result()
    }
}

/// Resumes the recording the activity was drawn for. Also an `AudioRecordingIntent`: that is
/// what lets a suspended app start its audio session again from the Lock Screen.
struct ResumeRecordingIntent: LiveActivityIntent, AudioRecordingIntent {
    nonisolated static let title: LocalizedStringResource = "Resume Recording"
    nonisolated static let isDiscoverable = false

    @Parameter(title: "Recording")
    var recordingID: String

    @Parameter(title: "Sequence", default: 0)
    var sequence: Int

    init() {}

    init(recordingID: RecordingID, sequence: Int) {
        self.recordingID = recordingID.uuidString
        self.sequence = sequence
    }

    func perform() async throws -> some IntentResult {
        if let id = RecordingID(uuidString: recordingID) {
            await RecorderControl.perform(.rendered(.resume, recordingID: id, sequence: sequence))
        }
        return .result()
    }
}

/// Stamps the slide after the one the activity showed. The shown slide also guards a stale
/// rendering (`RecorderCommand.Action.nextSlide(from:)`).
struct NextSlideIntent: LiveActivityIntent {
    nonisolated static let title: LocalizedStringResource = "Next Slide"
    nonisolated static let isDiscoverable = false

    @Parameter(title: "Recording")
    var recordingID: String

    @Parameter(title: "Slide")
    var slide: Int

    @Parameter(title: "Sequence", default: 0)
    var sequence: Int

    init() {}

    init(recordingID: RecordingID, slide: Int, sequence: Int) {
        self.recordingID = recordingID.uuidString
        self.slide = slide
        self.sequence = sequence
    }

    func perform() async throws -> some IntentResult {
        if let id = RecordingID(uuidString: recordingID) {
            await RecorderControl.perform(.rendered(.nextSlide(from: slide), recordingID: id, sequence: sequence))
        }
        return .result()
    }
}

/// Stops the recording the activity was drawn for, at once (also while paused).
struct StopRecordingIntent: LiveActivityIntent {
    nonisolated static let title: LocalizedStringResource = "Stop Recording"
    nonisolated static let isDiscoverable = false

    @Parameter(title: "Recording")
    var recordingID: String

    @Parameter(title: "Sequence", default: 0)
    var sequence: Int

    init() {}

    init(recordingID: RecordingID, sequence: Int) {
        self.recordingID = recordingID.uuidString
        self.sequence = sequence
    }

    func perform() async throws -> some IntentResult {
        if let id = RecordingID(uuidString: recordingID) {
            await RecorderControl.perform(.rendered(.stop, recordingID: id, sequence: sequence))
        }
        return .result()
    }
}
#endif
