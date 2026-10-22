import Notes
import NotesUI
import Review
import StudyCore
import StudyUI
import SwiftUI

/// The notes of one slide (or, `page` nil, of the lecture itself), each a rich `NoteEditor` in the
/// inspector style; a slide without notes has one empty editor that becomes a note on its first
/// keystroke. Leaving the slide saves.
struct SlideNoteEditorView: View {
    let model: ReviewModel
    /// Bumped to put the caret in the empty note.
    var focusRequest = 0
    @State private var editor: SlideNoteEditor
    @Environment(\.contentZoom) private var zoom

    init(model: ReviewModel, page: Int?, notes: [Note], focusRequest: Int = 0) {
        self.model = model
        self.focusRequest = focusRequest
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
        VStack(alignment: .leading, spacing: 10 * zoom) {
            ForEach(editor.sessions) { session in
                NoteSessionRow(model: model, session: session, focusRequest: focusRequest)
            }
        }
        .onDisappear {
            let editor = editor
            Task { await editor.flush() }
        }
    }
}

/// One note: your pin and the note (mockup 03's `.mynote`), its time chip after the last word
/// when it is anchored to the recording. Typing in it sets `isEditingText` (the review's plain
/// keys detach and the pane keeps its slide).
private struct NoteSessionRow: View {
    let model: ReviewModel
    let session: NoteSession
    /// Bumped by a click in the pane's empty room: an empty note takes the caret.
    var focusRequest = 0
    @Environment(\.contentZoom) private var zoom
    /// This note has the caret (an editor that goes away with it never says it lost it).
    @State private var hasFocus = false

    private var isBlank: Bool {
        session.note?.isBlank ?? true
    }

    var body: some View {
        let model = model
        HStack(alignment: .top, spacing: 7 * zoom) {
            // The pin marks your text: none beside an empty note, but its place is kept so typing
            // does not shift the line.
            ProvenancePin(.user)
                .zoomScaled(zoom)
                .padding(.top, 1 * zoom)
                .opacity(isBlank ? 0 : 1)
            NoteEditor(
                session: session,
                style: .inspector,
                startsWith: .body,
                professor: model.professorSurname.isEmpty ? nil : String(localized: "Prof. \(model.professorSurname)"),
                lectureID: model.lecture.id,
                trailingTime: model.player == nil ? nil : session.note?.audioTime,
                focusRequest: isBlank ? focusRequest : 0,
                onFocusChange: { focused in
                    hasFocus = focused
                    model.isEditingText = focused
                },
                onLink: { ReviewNoteLinks.open($0, model: model) }
            )
        }
        .onDisappear {
            // Gone with the caret (the other tab, the notes closed): the review's keys come back.
            if hasFocus {
                hasFocus = false
                model.isEditingText = false
            }
        }
    }
}
