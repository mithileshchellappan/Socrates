import Review
import StudyCore
import StudyUI
import SwiftUI

/// The inspector: "This slide | Whole lecture". This slide holds your notes for the slide on
/// screen (editable, autosaved); Whole lecture lists every note of the lecture by slide. AI blocks
/// (summary, further reading, exam hints, only said in class) arrive in M4.
struct ReviewInspector: View {
    let model: ReviewModel

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
        if model.deck == nil {
            ScrollView {
                LectureOnlyNotesPane(model: model, notes: notes)
            }
            .scrollIndicators(.automatic)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 0) {
            Picker("Notes", selection: $model.inspectorTab) {
                Text("This slide").tag(ReviewModel.InspectorTab.slide)
                Text("Whole lecture").tag(ReviewModel.InspectorTab.lecture)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                switch model.inspectorTab {
                case .slide:
                    SlideNotesPane(model: model, notes: notes)
                case .lecture:
                    LectureNotesPane(model: model, notes: notes)
                }
            }
            .scrollIndicators(.automatic)
        }
    }
}

/// "Your notes" for the slide on screen. A new editor per slide; leaving the slide saves.
private struct SlideNotesPane: View {
    let model: ReviewModel
    let notes: [Note]

    var body: some View {
        let page = model.session.shownPage
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("Your notes")
            SlideNoteEditorView(model: model, page: page, notes: notes.filter { $0.pageNumber == page })
                .id(page)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            ProvenancePin(.user)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                if draft.isEditable {
                    // The hidden text sizes the editor to its content (a text view does not).
                    Text(verbatim: draft.text.isEmpty ? " \n \n " : draft.text)
                        .font(.system(size: 12.5))
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hidden()
                        .overlay {
                            TextEditor(text: Binding(
                                get: { draft.text },
                                set: { editor.setText($0, for: draft.id) }
                            ))
                            .font(.system(size: 12.5))
                            .lineSpacing(2)
                            .scrollContentBackground(.hidden)
                            .scrollDisabled(true)
                            .padding(.horizontal, Self.insetCorrection)
                            .focused($isFocused)
                            .accessibilityLabel(Text("Your notes"))
                        }
                        .background {
                            // An empty note still shows where to type.
                            if draft.text.isEmpty {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.quaternary.opacity(isFocused ? 0.35 : 0.6))
                                    .padding(-4)
                            }
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
        .font(.system(size: 12.5))
        .lineSpacing(2)
        .textSelection(.enabled)
    }
}
