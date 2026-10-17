import CaptureUI
import StudyCore
import StudyUI
import SwiftUI

/// The live lecture for the session the app model owns, with its filing line under the slide.
struct LiveLectureScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let live = model.live {
            LiveLectureView(
                session: live.session,
                context: LiveLectureContext(title: Self.title(for: live), color: Color(hex: live.course.colorHex))
            )
            #if os(macOS)
            // The course is in the line under the slide; the title only names the window in the
            // Window menu (mockup 02: no toolbar title).
            .navigationTitle(live.course.name)
            .toolbar(removing: .title)
            #endif
        } else {
            ContentUnavailableView {
                Image(systemName: "record.circle")
            }
        }
    }

    /// "Computational Linguistics · Slides II: Syntax · Tue 13 Oct, 12:15"
    static func title(for live: AppModel.LiveCapture) -> String {
        let when = live.openedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        return [live.course.name, live.deck?.title ?? "", when]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
