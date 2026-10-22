import Notes
import Review
import StudyCore
import SwiftUI

/// The review's notes for the tab on screen (`ReviewModel.shownTab`): the Mac's Notes pane, the
/// iPad's inspector and the snapshot chrome draw it.
///
/// - This slide: the slide's summary, your notes for the slide on screen (editable, autosaved) and
///   its further reading, then, under a hairline, the lecture-wide exam hints and things only said
///   in class (3 rows each, then "Show N more").
/// - Whole lecture: only the student's own notes. On the Mac `YourNotesColumn` (the lecture's own
///   note, then the notes and ink by slide), following the slide on screen; a chip or thumbnail
///   moves the review. On iOS the lecture's own note and the slides' notes (`LectureYourNotes`).
/// - Summary: Claude's notes of the lecture (`SummaryPane`), or the study pass's blocks until
///   they are written.
struct ReviewNotesContent: View {
    let model: ReviewModel

    /// The notes list's visible height: an empty slide's pane fills it, so a click anywhere under
    /// "Your notes" starts the note.
    @State private var listHeight: CGFloat = 0
    private let notesQuery: FetchAll<Note>
    private var notes: [Note] { notesQuery.wrappedValue }
    private let annotationsQuery: FetchAll<Annotation>

    init(model: ReviewModel) {
        self.model = model
        let lectureID = model.lecture.id
        notesQuery = FetchAll(
            Note.where { $0.lectureID.eq(lectureID) }.order { ($0.pageNumber, $0.createdAt) },
            database: model.services.database
        )
        annotationsQuery = .studyItems(of: model)
    }

    var body: some View {
        let items = StudyItems(annotationsQuery.wrappedValue)
        switch model.shownTab {
        case .slide:
            ScrollView {
                SlideNotesPane(model: model, notes: notes, items: items, minHeight: listHeight)
            }
            .scrollIndicators(.automatic)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
        case .lecture:
            #if os(macOS)
            WholeLectureNotes(model: model)
            #else
            WholeLectureNotes(model: model, notes: notes)
            #endif
        case .summary:
            ScrollView {
                SummaryPane(model: model, items: items)
            }
            .scrollIndicators(.automatic)
        }
    }
}
