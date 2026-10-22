import Review
import StudyUI
import SwiftUI

#if os(macOS)
/// Review's Notes pane (the Mac's side pane, `.pane(.notes, …)`): the notes for the tab on screen
/// under the pane host's header, whose accessory is the tab picker (`NotesTabPicker`). It reads the
/// review only through its model (it is drawn in another hosting view than the screen) and zooms
/// with View ▸ Zoom In / Out on its own.
struct ReviewNotesPane: View {
    let model: ReviewModel

    var body: some View {
        ReviewNotesContent(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                // Your notes draws the same background itself.
                if model.shownTab != .lecture { ReviewNotesBackground() }
            }
            .contentZoomable()
    }
}
#endif
