#if os(macOS)
import StudyPageUI
#endif
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

#if os(macOS)
/// ln (docs/plan-lecture-notes.md, decision 8): the Lecture menu's Ask… (⌘K) and Highlight /
/// Remove Highlight (⇧⌘E) on the selected passage of a lecture's notes, at the menu's top. Present
/// only while the notes have focus (their focused values are nil otherwise), so the keys are
/// detached while the student types (the Ask field, a note) and free on every other screen
/// (Format's Add Link ⌘K and Highlight ⇧⌘E are a note editor's).
struct LectureNotesMenuItems: View {
    @FocusedValue(\.lectureNotesAsk) private var ask
    @FocusedValue(\.lectureNotesHighlight) private var highlight

    var body: some View {
        if ask != nil || highlight != nil {
            if let ask {
                Button(ask.title) { ask() }
                    .keyboardShortcut(LectureNotesCommand.askShortcut)
                    .disabled(!ask.isEnabled)
            }
            if let highlight {
                Button(highlight.title) { highlight() }
                    .keyboardShortcut(LectureNotesCommand.highlightShortcut)
                    .disabled(!highlight.isEnabled)
            }
            Divider()
        }
    }
}
#endif
