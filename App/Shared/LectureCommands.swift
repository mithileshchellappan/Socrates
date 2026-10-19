import StudyCore
import StudyUI
import SwiftUI

/// File ▸ New Lecture Capture… (⇧⌘N). Import… (⇧⌘I) comes from smart import's `ImportCommands`.
/// Edit ▸ Delete Lecture… / Delete Slides… / Delete Recording… for the lecture open in review
/// (the window confirms what goes; Edit ▸ Undo brings it back).
struct LectureCommands: Commands {
    let model: AppModel
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @FocusedValue(\.openLibraryItems) private var openItems

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
        CommandGroup(after: .pasteboard) {
            if let openItems, let lecture = openItems.lecture {
                Divider()
                Button("Delete Lecture…") { openItems.delete(.lecture(lecture)) }
                if let deck = openItems.deck {
                    Button("Delete Slides…") { openItems.delete(.deck(deck)) }
                }
                if let recording = openItems.recording {
                    Button("Delete Recording…") { openItems.delete(.recording(recording)) }
                }
            }
        }
    }
}
