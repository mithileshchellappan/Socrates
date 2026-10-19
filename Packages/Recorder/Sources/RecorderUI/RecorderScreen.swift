import Recorder
import SwiftUI

/// The iPhone recorder (mockup 09 left, DESIGN 8.5): the course menu and Stop, the timer, the
/// session line, the waveform with stamp lines, the slide, the 88 pt Next slide button, Previous
/// and Flag; before recording one Record button; after Stop the capture with Share and the outbox.
/// The app presents it full screen.
///
/// Skeleton landed with the plan; workstream A builds it.
public struct RecorderScreen: View {
    let recorder: PhoneRecorder

    public init(recorder: PhoneRecorder) {
        self.recorder = recorder
    }

    public var body: some View {
        Image(systemName: "record.circle")
            .font(.largeTitle)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
