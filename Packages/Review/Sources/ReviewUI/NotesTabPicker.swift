import Review
import SwiftUI

/// "This slide | Whole lecture | Summary" ("Whole lecture | Summary" without a deck): a small
/// segmented control (on a toolbar glass track its selection is neutral, not accent-filled). The
/// Mac's Notes pane shows it in its header, in place of a title.
struct NotesTabPicker: View {
    let model: ReviewModel

    var body: some View {
        Picker("Notes", selection: Binding(get: { model.shownTab }, set: { model.inspectorTab = $0 })) {
            ForEach(model.notesTabs, id: \.self) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .fixedSize()
    }
}
