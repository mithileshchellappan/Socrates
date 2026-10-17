import Review
import StudyCore
import StudyUI
import SwiftUI

/// The inspector: "This slide | Whole lecture" and the hide button in one 52 pt header row level
/// with the window toolbar, a hairline, then the pane. This slide holds your notes for the slide
/// on screen (editable, autosaved); Whole lecture lists every note of the lecture by slide. AI
/// blocks (summary, further reading, exam hints, only said in class) arrive in M4.
///
/// In the window the header is a toolbar item: macOS 26 lays the toolbar out as one row whose
/// trailing items pack against the window's edge, with no section of its own over the inspector.
/// The item is as wide as the inspector (less the toolbar's trailing inset), so it sits exactly
/// over the column and keeps the slide stepper beside it, over the content.
struct ReviewInspector: View {
    static let width: CGFloat = 336
    static let headerHeight: CGFloat = 52
    /// The toolbar's inset from the window's trailing edge.
    static let toolbarTrailingInset: CGFloat = 11

    let model: ReviewModel

    @Environment(\.reviewChrome) private var chrome
    @State private var columnWidth = ReviewInspector.width
    private let notesQuery: FetchAll<Note>
    private var notes: [Note] { notesQuery.wrappedValue }

    init(model: ReviewModel) {
        self.model = model
        let lectureID = model.lecture.id
        notesQuery = FetchAll(
            Note.where { $0.lectureID.eq(lectureID) }.order { ($0.pageNumber, $0.createdAt) },
            database: model.services.database
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if chrome == .snapshot {
                InspectorHeader(model: model)
                    .padding(.trailing, Self.toolbarTrailingInset)
                    .frame(height: Self.headerHeight)
            }
            Divider()
            ScrollView {
                if model.deck == nil {
                    LectureOnlyNotesPane(model: model, notes: notes)
                } else {
                    switch model.inspectorTab {
                    case .slide:
                        SlideNotesPane(model: model, notes: notes)
                    case .lecture:
                        LectureNotesPane(model: model, notes: notes)
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { InspectorBackground() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
        .toolbar {
            if chrome == .window {
                ToolbarItem(placement: .automatic) {
                    InspectorHeader(model: model)
                        .frame(width: max(0, columnWidth - Self.toolbarTrailingInset))
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }
}

/// The inspector column's background: the system's as is in light mode; in dark mode lifted a
/// little above the content (which it otherwise matches) so it reads as a panel of its own.
/// Snapshots have no inspector column, so they draw the secondary background.
private struct InspectorBackground: View {
    @Environment(\.reviewChrome) private var chrome
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch chrome {
        case .window:
            if colorScheme == .dark {
                Rectangle().fill(.white.opacity(0.025)).ignoresSafeArea()
            }
        case .snapshot:
            Rectangle().fill(.background.secondary)
        }
    }
}

/// The header row: the tab picker on a glass track, then the hide button at the trailing edge.
private struct InspectorHeader: View {
    let model: ReviewModel

    var body: some View {
        HStack(spacing: 8) {
            if model.deck != nil {
                InspectorTabPicker(model: model)
                    .padding(2)
                    .reviewGlass(in: Capsule())
            }
            Spacer(minLength: 0)
            Button {
                model.showsInspector = false
            } label: {
                Label("Hide Inspector", systemImage: "sidebar.trailing")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(Text("Hide Inspector"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
    }
}

/// "This slide | Whole lecture": a small segmented control (on a toolbar glass track its
/// selection is neutral, not accent-filled).
private struct InspectorTabPicker: View {
    let model: ReviewModel

    var body: some View {
        @Bindable var model = model
        Picker("Notes", selection: $model.inspectorTab) {
            Text("This slide").tag(ReviewModel.InspectorTab.slide)
            Text("Whole lecture").tag(ReviewModel.InspectorTab.lecture)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .fixedSize()
    }
}

/// "Your notes" for the slide on screen. A new editor per slide; leaving the slide saves.
///
/// While a note is being typed the pane stays on the slide the typing started on: playback with
/// Follow moving to the next slide must not take the editor (and its focus) away mid-word. It
/// catches up with the slide on screen once the editor lets go of focus.
private struct SlideNotesPane: View {
    let model: ReviewModel
    let notes: [Note]
    /// The slide whose notes are being typed (nil: follow the slide on screen).
    @State private var typingOn: TypingPage?

    private struct TypingPage: Equatable {
        var page: Int?
    }

    var body: some View {
        let page = typingOn.map(\.page) ?? model.session.shownPage
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("Your notes")
            SlideNoteEditorView(model: model, page: page, notes: notes.filter { $0.pageNumber == page })
                .id(page)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: model.isEditingText) { _, editing in
            typingOn = editing ? TypingPage(page: typingOn.map(\.page) ?? model.session.shownPage) : nil
        }
    }
}

private struct SlideNoteEditorView: View {
    let model: ReviewModel
    @State private var editor: SlideNoteEditor

    init(model: ReviewModel, page: Int?, notes: [Note]) {
        self.model = model
        let player = model.player
        _editor = State(initialValue: SlideNoteEditor(
            anchor: NoteAnchor(
                courseID: model.lecture.courseID, lectureID: model.lecture.id, deckID: model.deckID,
                page: page, recordingID: model.recording?.id
            ),
            notes: notes,
            store: model.services.records,
            playhead: { player?.time }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(editor.drafts) { draft in
                NoteDraftRow(model: model, editor: editor, draft: draft)
            }
        }
        .onDisappear {
            let editor = editor
            Task { await editor.flush() }
        }
    }
}

/// One note: your pin, the text (editable), and a time chip when it is anchored to the recording.
private struct NoteDraftRow: View {
    let model: ReviewModel
    let editor: SlideNoteEditor
    let draft: NoteDraft

    @FocusState private var isFocused: Bool

    /// Lines the editor's text up with the pin (the text view's line fragment padding).
    #if os(macOS)
    private static let insetCorrection: CGFloat = -5
    #else
    private static let insetCorrection: CGFloat = -4
    #endif

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            // The pin marks your text: none beside an empty note, but its place is kept so typing
            // does not shift the line.
            ProvenancePin(.user)
                .padding(.top, 1)
                .opacity(draft.text.isEmpty ? 0 : 1)
            VStack(alignment: .leading, spacing: 5) {
                if draft.isEditable {
                    // The hidden text sizes the editor to its content (a text view does not).
                    Text(verbatim: draft.text.isEmpty ? " " : draft.text)
                        .font(.callout)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hidden()
                        .overlay {
                            TextEditor(text: Binding(
                                get: { draft.text },
                                set: { editor.setText($0, for: draft.id) }
                            ))
                            .font(.callout)
                            .lineSpacing(2)
                            .scrollContentBackground(.hidden)
                            .scrollDisabled(true)
                            .padding(.horizontal, Self.insetCorrection)
                            .focused($isFocused)
                            .accessibilityLabel(Text("Your notes"))
                        }
                } else {
                    NoteBody(blocks: draft.note?.blocks ?? [])
                }
                if let time = draft.audioTime, model.player != nil {
                    TimeChip(time) {
                        Task { await model.session.play(from: time) }
                    }
                }
            }
        }
        // The whole row takes a click into the note (an empty one is a single quiet line).
        .contentShape(Rectangle())
        .onTapGesture {
            if draft.isEditable { isFocused = true }
        }
        .onChange(of: isFocused) { _, focused in
            model.isEditingText = focused
        }
        .onDisappear {
            // Paging away while typing removes the editor without a focus change.
            if isFocused { model.isEditingText = false }
        }
    }
}

/// Without a deck: notes on the lecture itself (editable), then any slide notes it kept.
private struct LectureOnlyNotesPane: View {
    let model: ReviewModel
    let notes: [Note]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Your notes")
            SlideNoteEditorView(model: model, page: nil, notes: notes.filter { $0.pageNumber == nil })
            ForEach(notes.filter { $0.pageNumber != nil && !$0.isBlank }) { note in
                NoteBody(blocks: note.blocks)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Every note of the lecture, by slide.
private struct LectureNotesPane: View {
    let model: ReviewModel
    let notes: [Note]

    var body: some View {
        let visible = notes.filter { !$0.isBlank }
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Your notes")
            ForEach(visible) { note in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if let page = note.pageNumber {
                        SlideChip(page: page) {
                            Task { await model.session.selectThumbnail(page: page) }
                        }
                    }
                    NoteBody(blocks: note.blocks)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A note shown read-only: one line per block, checklist items with their box.
private struct NoteBody: View {
    let blocks: [NoteBlock]

    var body: some View {
        blocks.enumerated().reduce(Text(verbatim: "")) { text, item in
            let (index, block) = item
            let separator = index == 0 ? "" : "\n"
            guard block.type == .checklist else { return Text("\(text)\(separator)\(block.text)") }
            let box = Text(Image(systemName: block.checked == true ? "checkmark.square" : "square")).foregroundStyle(.secondary)
            return Text("\(text)\(separator)\(box) \(block.text)")
        }
        .font(.callout)
        .lineSpacing(2)
        .textSelection(.enabled)
    }
}
