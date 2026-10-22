import Review
import StudyCore
import StudyPageUI
import StudyUI
import SwiftUI

/// Summary (ln, decision 2): with the lecture's notes written (their text has started), the same
/// notes as the Lectures page in the pane's narrow column (`LectureNotesView`), then Further
/// reading; the Summary, Exam hints and Only said in class are not shown beside them (each is
/// inside the notes: no fact twice). With Follow on, the notes scroll to the section whose slides
/// hold the slide on screen; chips move the review; Continue in Chat's passage goes with the
/// review's context; Ask… and Highlight go to the screen through `ReviewModel.notesCommands`.
/// Until the notes are written (or while a version is paused or failed): the study pass's blocks,
/// and on the Mac the first show queues the notes (`queueIfNeeded`). A version that failed puts
/// its failure line over the blocks (triangle, reason, Write Again…: `LectureNotesFailureBar`).
/// Write Again… for a finished version and Previous Version are the notes page's (its ⋯), as
/// before panes. The student's own notes are Whole lecture's.
struct SummaryPane: View {
    let model: ReviewModel
    let items: StudyItems
    private let versionsQuery: FetchAll<LectureNotes>
    @Environment(\.lectureNotesQueuesOnOpen) private var queuesOnOpen

    init(model: ReviewModel, items: StudyItems) {
        self.model = model
        self.items = items
        let lectureID = model.lecture.id
        versionsQuery = FetchAll(LectureNotes.where { $0.lectureID.eq(lectureID) }, database: model.services.database)
    }

    /// The notes replace the blocks once they are written (done), or while they stream in; a
    /// version that failed or is paused at a usage limit keeps the blocks (its text is partial).
    private var hasNotes: Bool {
        guard let current = LectureNotes.current(of: versionsQuery.wrappedValue), current.hasText else { return false }
        return current.state == .done || current.state == .generating
    }

    var body: some View {
        #if os(macOS)
        if hasNotes {
            SummaryNotes(model: model, items: items)
        } else {
            blocks
        }
        #else
        blocks
        #endif
    }

    /// Only the Mac queues notes: the iPhone shows no notes yet, and a version it queued would
    /// sync to the Mac beside the Mac's own (two calls for one lecture).
    @ViewBuilder
    private var blocks: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            if LectureNotes.current(of: versionsQuery.wrappedValue)?.state == .failed {
                LectureNotesFailureBar(lectureID: model.lecture.id)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            }
            SummaryStudyBlocks(model: model, items: items)
        }
        .task(id: model.lecture.id) {
            guard queuesOnOpen else { return }
            do {
                try await LectureNotesRepository(store: model.services.records).queueIfNeeded(lectureID: model.lecture.id)
            } catch {
                ReviewLog.logger.error("Queueing the lecture's notes failed: \(String(describing: error), privacy: .public)")
            }
        }
        #else
        SummaryStudyBlocks(model: model, items: items)
        #endif
    }
}

#if os(macOS)
/// Summary once the notes are written: Claude's notes, then Further reading.
private struct SummaryNotes: View {
    let model: ReviewModel
    let items: StudyItems
    @Environment(\.contentZoom) private var zoom

    var body: some View {
        let model = model
        VStack(alignment: .leading, spacing: 14 * zoom) {
            // The notes text zooms itself (StudyPageUI).
            LectureNotesView(
                lectureID: model.lecture.id, style: .inspector,
                followPage: model.session.isFollowing ? model.session.shownPage : nil,
                onChip: { ReviewNoteLinks.open($0, model: model) },
                onChatPassage: { passage in
                    if model.notesPassage != passage { model.notesPassage = passage }
                },
                commands: model.notesCommands
            )
            if !items.furtherReading.isEmpty {
                Hairline()
                FurtherReadingBlock(model: model, readings: items.furtherReading, showsSlides: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif

/// Summary before the notes are written: the study pass's summary, exam hints, things said in
/// class and further reading.
private struct SummaryStudyBlocks: View {
    let model: ReviewModel
    /// The study pass's rows (M4): the lecture's summary, every exam hint, everything only said in
    /// class by category, every further reading.
    let items: StudyItems
    @Environment(\.contentZoom) private var zoom

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * zoom) {
            if let summary = items.lectureSummary {
                SummaryBlock(model: model, summary: summary)
            }
            if !items.examHints.isEmpty {
                ExamHintsBlock(model: model, hints: items.examHints)
            }
            if !items.saidInClass.isEmpty {
                SaidInClassBlock(model: model, items: items.saidInClass, groups: items.saidInClassByCategory)
            }
            if !items.furtherReading.isEmpty {
                FurtherReadingBlock(model: model, readings: items.furtherReading, showsSlides: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
