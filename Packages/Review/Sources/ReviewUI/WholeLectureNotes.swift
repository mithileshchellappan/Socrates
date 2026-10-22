import Notes
import NotesUI
import Review
import StudyCore
import StudyPageUI
import StudyUI
import SwiftUI

/// Whole lecture: only the student's own notes. On the Mac the notes page's Your notes column
/// (the lecture's own note, then the notes and ink by slide), following the slide on screen; on iOS
/// the lecture's own note, then the slides' notes read-only (`LectureYourNotes`).
struct WholeLectureNotes: View {
    let model: ReviewModel
    #if os(iOS)
    /// The lecture's notes (the Notes pane's read; the Mac's column reads its own rows).
    let notes: [Note]
    #endif

    var body: some View {
        #if os(macOS)
        // The notes page's Your notes, following the slide on screen; a chip or a thumbnail moves
        // the review (it never opens it again), and a new note gets the recording and the playhead
        // then, as on This slide. It scrolls itself.
        let model = model
        YourNotesColumn(
            lectureID: model.lecture.id,
            follow: { .page(model.session.shownPage) },
            recordingID: model.recording?.id,
            playhead: { model.player?.time },
            onOpenSlide: { page in
                Task { await model.session.selectThumbnail(page: page) }
            },
            onLink: { ReviewNoteLinks.open($0, model: model) },
            onEditingChange: { editing in model.isEditingText = editing }
        )
        #else
        ScrollView {
            LectureYourNotes(model: model, notes: notes)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        #endif
    }
}

#if os(iOS)
/// Whole lecture on iOS: the lecture's own notes (editable), then the notes of its slides,
/// read-only, each after its `SlideChip`.
private struct LectureYourNotes: View {
    let model: ReviewModel
    let notes: [Note]
    @Environment(\.contentZoom) private var zoom

    /// The lecture's own notes (no slide), without the copies of its lecture notes that Edit as
    /// Note made (nl: Claude's words stay in Notes, never twice).
    private var ownNotes: [Note] {
        notes.filter { $0.pageNumber == nil && !$0.isLectureNotesCopy }
    }

    var body: some View {
        let model = model
        VStack(alignment: .leading, spacing: 10 * zoom) {
            SectionLabel("Your notes")
            SlideNoteEditorView(model: model, page: nil, notes: ownNotes)
            ForEach(notes.filter { $0.pageNumber != nil && !$0.isBlank }) { note in
                HStack(alignment: .top, spacing: 7 * zoom) {
                    if let page = note.pageNumber {
                        SlideChip(page: page) {
                            Task { await model.session.selectThumbnail(page: page) }
                        }
                        .zoomScaled(zoom)
                        .padding(.top, 1 * zoom)
                    }
                    NoteEditor(
                        note: note, style: .inspector,
                        professor: model.professorSurname.isEmpty ? nil : String(localized: "Prof. \(model.professorSurname)"),
                        onLink: { ReviewNoteLinks.open($0, model: model) }
                    )
                    // Drawn again when the note changes (it is edited on This slide).
                    .id("\(note.id)-\(note.updatedAt.timeIntervalSinceReferenceDate)")
                }
            }
        }
    }
}
#endif
