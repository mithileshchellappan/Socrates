import Review
import StudyCore
import StudyUI
import SwiftUI

// M6 (PRD #17, docs/plan-m6.md §5.2, mockup 03): the student's ink on the slide on screen, the
// toolbar group [Pen, Highlighter, (Eraser), Flag] and what keeps the slide put while drawing.

/// The ink of the slide on screen: StudyUI's `InkCanvas` over the bitmap, in its frame, holding
/// the page's `SlideInkEditor`. Give it an `.id` per deck page: the editor, the canvas and the
/// canvas's undo steps are the page's and go when the page changes (the editor writes then).
struct SlideInkLayer: View {
    struct Key: Hashable {
        var deckID: Deck.ID
        var page: Int
    }

    let model: ReviewModel
    let page: Int
    @State private var editor: SlideInkEditor

    init(model: ReviewModel, deckID: Deck.ID, page: Int, aspectRatio: Double) {
        self.model = model
        self.page = page
        _editor = State(initialValue: SlideInkEditor(
            deckID: deckID, page: page, aspectRatio: aspectRatio, store: model.services.records
        ))
    }

    var body: some View {
        let model = model
        let page = page
        // Until the page's ink is read, nothing can be drawn over it.
        InkCanvas(drawing: Bindable(editor).drawing, tool: editor.isLoaded ? model.inkTool : nil, surface: .slide)
            .task { await editor.load() }
            .onChange(of: editor.drawing.isEmpty) { _, isEmpty in
                model.setPage(page, hasInk: !isEmpty)
            }
            .onDisappear { [editor] in editor.flush() }
    }
}

#if os(macOS)
/// The toolbar group after the slide stepper (mockup 03): Pen and Highlighter toggles (one at a
/// time; the one on turns drawing off), the Eraser while drawing, and Flag with a recording.
/// Toggled buttons are drawn by the system toolbar (accent soft, accent glyph).
struct InkToolButtons: View {
    let model: ReviewModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let model = model
        Toggle("Pen", systemImage: "pencil.tip", isOn: Self.binding(model, .pen))
            .help(Text("Pen"))
        Toggle("Highlighter", systemImage: "highlighter", isOn: Self.binding(model, .highlighter))
            .help(Text("Highlighter"))
        if model.inkTool != nil {
            Toggle("Eraser", systemImage: "eraser", isOn: Self.binding(model, .eraser))
                .help(Text("Eraser"))
        }
        if model.canFlag {
            Button("Flag", systemImage: "flag") {
                model.flag(undoManager: undoManager)
            }
            .help(Text("Flag"))
        }
    }

    static func binding(_ model: ReviewModel, _ tool: InkTool) -> Binding<Bool> {
        Binding(
            get: { model.inkTool == tool },
            set: { _ in model.toggleInkTool(tool) }
        )
    }
}

/// The same group in off-screen snapshots (no window toolbar there): plain glyphs on one glass
/// capsule, a tool that is on in the accent on accent soft.
struct SnapshotInkTools: View {
    let model: ReviewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            glyph("pencil.tip", label: "Pen", isOn: model.inkTool == .pen)
            glyph("highlighter", label: "Highlighter", isOn: model.inkTool == .highlighter)
            if model.inkTool != nil {
                glyph("eraser", label: "Eraser", isOn: model.inkTool == .eraser)
            }
            if model.canFlag {
                glyph("flag", label: "Flag", isOn: false)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .reviewGlass(in: Capsule())
    }

    private func glyph(_ systemImage: String, label: LocalizedStringKey, isOn: Bool) -> some View {
        Image(systemName: systemImage)
            .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .frame(width: 30, height: 26)
            .background(isOn ? Color.accentSoft(colorScheme) : .clear, in: Capsule())
            .accessibilityLabel(Text(label))
    }
}
#endif

/// While the student draws the slide stays put: a tool turns Follow off, and Follow coming back
/// on (the Follow button, ⇧⌘F, a transcript line, a time chip) ends drawing. Its own view, so
/// following never re-renders the screen.
struct DrawingFollowGuard: View {
    let model: ReviewModel

    var body: some View {
        let model = model
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: model.session.isFollowing) { _, following in
                if following, model.inkTool != nil { model.stopDrawing() }
            }
    }
}
