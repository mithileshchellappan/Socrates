import ActivityKit
import RecorderActivity
import SwiftUI
import WidgetKit

// The widget extension (M7, docs/plan-m7.md §3, §5.1): the recording's Live Activity on the Lock
// Screen and in the Dynamic Island. Its views and the two button intents are in `Shared/`, which
// the app compiles too. Links RecorderActivity only.

@main
struct StudyPortalWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

/// The recording's Live Activity: course, session, slide, elapsed; [Next Slide] [Stop Recording].
///
/// Skeleton landed with the plan; workstream A builds the Lock Screen and Dynamic Island views.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            Text(context.state.courseName)
                .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.courseName)
                }
            } compactLeading: {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
            } compactTrailing: {
                Text("S\(context.state.slide)")
            } minimal: {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
            }
        }
    }
}
