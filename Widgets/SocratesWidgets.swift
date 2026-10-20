import ActivityKit
import RecorderActivity
import SwiftUI
import WidgetKit

// The widget extension (M7, docs/plan-m7.md §3, §5.1): the recording's Live Activity on the Lock
// Screen and in the Dynamic Island. Its views and the two button intents are in `Shared/`, which
// the app compiles too. Links RecorderActivity only.

@main
struct SocratesWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

/// The recording's Live Activity: course, session, slide, elapsed; [Next Slide] [Stop Recording].
/// The Lock Screen and the expanded Dynamic Island show the same content; compact: the red dot
/// and the elapsed time, "S17"; minimal: the red dot.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingLockScreenView(state: context.state, recordingID: context.attributes.recordingID)
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RecordingTitle(state: context.state)
                        .padding(.leading, 4)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingElapsed(state: context.state, size: 20)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RecordingButtons(recordingID: context.attributes.recordingID)
                        .padding(.top, 6)
                }
            } compactLeading: {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text(timerInterval: context.state.timerRange, pauseTime: context.state.stoppedAt, countsDown: false, showsHours: true)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .frame(maxWidth: 58, alignment: .leading)
                }
            } compactTrailing: {
                Text(context.state.shortSlide)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            } minimal: {
                Circle().fill(.red).frame(width: 9, height: 9)
            }
            .keylineTint(.red)
        }
    }
}
