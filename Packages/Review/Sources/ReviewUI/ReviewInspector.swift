import Review
import SwiftUI

/// The iPad's inspector and the notes beside the review in off-screen snapshots (both platforms).
/// The header (the tab picker, and on the iPad Hide) is inline in a snapshot; on the iPad it is a
/// toolbar item level with the window toolbar, as wide as the column less the toolbar's trailing
/// inset, there only while the inspector is shown (then the toolbar's Show Inspector takes its
/// place). ma: while the agent panel is expanded it takes the inspector's place (`isShown` false).
/// The Mac's window shows the notes as the Notes pane instead (`ReviewNotesPane`).
struct ReviewInspector: View {
    static let width: CGFloat = 336
    static let headerHeight: CGFloat = 52
    /// The toolbar's inset from the window's trailing edge.
    static let toolbarTrailingInset: CGFloat = 11

    let model: ReviewModel
    #if os(iOS)
    /// The inspector is on screen (shown, and the agent panel not expanded in its place).
    var isShown = true
    #endif

    @Environment(\.reviewChrome) private var chrome
    #if os(iOS)
    @State private var columnWidth = ReviewInspector.width
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if chrome == .snapshot {
                InspectorHeader(model: model)
                    .padding(.trailing, Self.toolbarTrailingInset)
                    .frame(height: Self.headerHeight)
            }
            Divider()
            ReviewNotesContent(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { ReviewNotesBackground() }
        #if os(iOS)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
        .toolbar {
            // Only while the inspector is shown: SwiftUI keeps a hidden inspector's content (and
            // with it this item) alive, so the header stayed in the toolbar beside Show Inspector.
            if chrome == .window, model.showsInspector, isShown {
                ToolbarItem(placement: .automatic) {
                    InspectorHeader(model: model)
                        .frame(width: max(0, columnWidth - Self.toolbarTrailingInset))
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        #endif
    }
}

/// The header row of the iPad's inspector and the snapshot chrome: the tab picker, then (iPad) the
/// hide button at the trailing edge.
private struct InspectorHeader: View {
    let model: ReviewModel

    var body: some View {
        HStack(spacing: 8) {
            NotesTabPicker(model: model)
            Spacer(minLength: 0)
            #if os(iOS)
            Button {
                model.showsInspector = false
            } label: {
                Label("Hide Inspector", systemImage: "sidebar.trailing")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(Text("Hide Inspector"))
            #endif
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
    }
}
