import SwiftUI

/// Live lecture mode gets its own window on the Mac (mockup 02-live: the sidebar collapsed to a
/// toolbar button that brings the library window forward; inspector). One at a time; closing it
/// keeps a running recording going.
struct LiveLectureScene: Scene {
    static let id = "live-lecture"
    let model: AppModel

    var body: some Scene {
        Window("Live Lecture", id: Self.id) {
            LiveLectureScreen()
                .environment(model)
                .onDisappear { model.closeLiveLecture() }
                #if DEBUG
                .background {
                    if ParityMode.options != nil { ParityWindowReader(role: .live) }
                }
                #endif
        }
        .defaultSize(width: 1280, height: 820)
        .restorationBehavior(.disabled)
    }
}
