import SwiftUI

/// File menu: start a live lecture or import one (⇧⌘N, ⇧⌘I).
struct LectureCommands: Commands {
    let model: AppModel
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Lecture Capture…") {
                if model.live != nil {
                    #if os(macOS)
                    openWindow(id: LiveLectureScene.id)
                    #endif
                } else {
                    model.sheet = .newCapture
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(model.services == nil)

            Button("Import Lecture…") { model.sheet = .importLecture(courseID: nil) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(model.services == nil)
        }
    }
}
