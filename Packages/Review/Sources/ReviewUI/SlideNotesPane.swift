import Notes
import Review
import StudyCore
import StudyUI
import SwiftUI

/// "Your notes" for the slide on screen. A new editor per slide; leaving the slide saves.
///
/// While a note is being typed the pane stays on the slide the typing started on: playback with
/// Follow moving to the next slide must not take the editor (and its focus) away mid-word. It
/// catches up with the slide on screen once the editor lets go of focus.
struct SlideNotesPane: View {
    let model: ReviewModel
    let notes: [Note]
    /// The study pass's rows (M4): the slide's summary and further reading, then the lecture-wide
    /// exam hints and things only said in class.
    let items: StudyItems
    /// The list's visible height, which the pane fills.
    var minHeight: CGFloat = 0
    /// The slide whose notes are being typed (nil: follow the slide on screen).
    @State private var typingOn: TypingPage?
    /// A click in the pane's empty room: the empty note takes the caret (no placeholder copy).
    @State private var focusRequest = 0
    @Environment(\.contentZoom) private var zoom

    private struct TypingPage: Equatable {
        var page: Int?
    }

    var body: some View {
        let page = typingOn.map(\.page) ?? model.session.shownPage
        VStack(alignment: .leading, spacing: 14 * zoom) {
            if let page, let summary = items.slideSummaries[page] {
                SummaryBlock(model: model, summary: summary)
            }
            VStack(alignment: .leading, spacing: 7 * zoom) {
                SectionLabel("Your notes")
                SlideNoteEditorView(model: model, page: page, notes: notes.filter { $0.pageNumber == page }, focusRequest: focusRequest)
                    .id(page)
            }
            if let page {
                let readings = items.furtherReading(page: page)
                if !readings.isEmpty {
                    FurtherReadingBlock(model: model, readings: Array(readings.prefix(2)))
                }
            }
            // Lecture-wide (mockup 03): the admission rules at 0:37 never hide behind slide 16.
            if items.hasLectureWideItems {
                Hairline()
                if !items.examHints.isEmpty {
                    ExamHintsBlock(model: model, hints: items.examHints, limit: 3)
                }
                if !items.saidInClass.isEmpty {
                    SaidInClassBlock(model: model, items: items.saidInClass, limit: 3)
                }
            }
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { focusRequest += 1 }
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .onChange(of: model.isEditingText) { _, editing in
            typingOn = editing ? TypingPage(page: typingOn.map(\.page) ?? model.session.shownPage) : nil
        }
    }
}
