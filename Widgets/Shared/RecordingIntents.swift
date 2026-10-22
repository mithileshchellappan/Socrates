#if os(iOS)
import AppIntents
import Foundation
import RecorderActivity

// The Live Activity's two buttons (M7, docs/plan-m7.md §4; PRD "iPhone recording": exactly Next
// Slide and Stop Recording). `LiveActivityIntent`s run in the app's process, so this file is
// compiled into both the app (iOS) and the widget extension (Apple's requirement for Live
// Activity buttons); in the app they reach the recorder through `RecorderControl`.

/// Stamps the slide after the one the activity showed, for the recording it was drawn for. The
/// shown slide makes a repeated run of one tap harmless (`RecorderCommand.nextSlide(from:)`).
struct NextSlideIntent: LiveActivityIntent {
    nonisolated static let title: LocalizedStringResource = "Next Slide"
    nonisolated static let isDiscoverable = false

    @Parameter(title: "Recording")
    var recordingID: String

    @Parameter(title: "Slide")
    var slide: Int

    init() {}

    init(recordingID: UUID, slide: Int) {
        self.recordingID = recordingID.uuidString
        self.slide = slide
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: recordingID) {
            await RecorderControl.perform(.nextSlide(from: slide), recordingID: id)
        }
        return .result()
    }
}

/// Stops the recording the activity was drawn for, at once.
struct StopRecordingIntent: LiveActivityIntent {
    nonisolated static let title: LocalizedStringResource = "Stop Recording"
    nonisolated static let isDiscoverable = false

    @Parameter(title: "Recording")
    var recordingID: String

    init() {}

    init(recordingID: UUID) {
        self.recordingID = recordingID.uuidString
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: recordingID) {
            await RecorderControl.perform(.stop, recordingID: id)
        }
        return .result()
    }
}
#endif
