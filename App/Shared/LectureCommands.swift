import SwiftUI

/// File ▸ New Lecture Capture… (⇧⌘N). Import… (⇧⌘I) comes from smart import's `ImportCommands`.
struct LectureCommands: Commands {
    let model: AppModel
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Lecture Capture…") {
                if model.hasOpenCapture {
                    #if os(macOS)
                    openWindow(id: LiveLectureScene.id)
                    #else
                    model.isLivePresented = true
                    #endif
                } else {
                    model.sheet = .newCapture
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(model.services == nil)
        }
    }
}
