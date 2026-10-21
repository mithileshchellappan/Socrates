import NotesUI
import Review
import StudyCore
import StudyUI
import SwiftUI

// The study pass's blocks in the inspector (docs/plan-m4.md §5, mockup 03): Summary, Further
// reading, Exam hints, Only said in class. A block appears when its rows land: no skeleton and no
// copy while the pass waits or is paused. AI text is secondary with one sparkle per block; the
// professor's words are primary, marked by the amber pin. nl: their text, chips and pins follow
// the content zoom (`\.contentZoom`); "Show N more" (a button) stays.

extension FetchAll<Annotation> {
    /// The lecture's study pass rows and pins that are not hidden, in time order.
    static func studyItems(of model: ReviewModel) -> FetchAll<Annotation> {
        let lectureID = model.lecture.id
        return FetchAll(
            Annotation
                .where { $0.lectureID.eq(lectureID) && $0.hiddenAt.is(nil) }
                .order { ($0.startTime, $0.createdAt) },
            database: model.services.database
        )
    }
}

/// A block's label (11 pt semibold secondary): one sparkle for AI blocks, the amber star for exam
/// hints, nothing for the student's own.
struct StudyBlockLabel: View {
    enum Mark {
        case none
        case ai
        case exam
    }

    let title: LocalizedStringKey
    var mark: Mark = .none
    @Environment(\.contentZoom) private var zoom

    var body: some View {
        HStack(spacing: 6 * zoom) {
            switch mark {
            case .none:
                EmptyView()
            case .ai:
                AIMark()
            case .exam:
                Image(systemName: "star")
                    .imageScale(.small)
                    .foregroundStyle(Color.professor)
                    .accessibilityHidden(true)
            }
            Text(title)
        }
        .font(.zoomed(.subheadline, zoom, weight: .semibold))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A paragraph of 12.5 pt text (× the content zoom) that ends with one time chip on its last line
/// (mockup `.ai-text` with `.chip-ts`), wrapping word by word.
struct ChipParagraph: View {
    let text: String
    let time: Double?
    let play: (Double) -> Void
    @Environment(\.contentZoom) private var zoom

    var body: some View {
        Group {
            if let time {
                NoteFlowLayout(lineSpacing: 3 * zoom, wordSpacing: 3.2 * zoom) {
                    ForEach(Array(text.split(whereSeparator: \.isWhitespace).enumerated()), id: \.offset) { _, word in
                        Text(verbatim: String(word))
                    }
                    TimeChip(time) { play(time) }
                        .zoomScaled(zoom)
                }
            } else {
                Text(verbatim: text)
                    .lineSpacing(3 * zoom)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12.5 * zoom))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// "Show 3 more": a plain accent button under a block's first rows.
struct ShowMoreButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Show \(count) more")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tint)
                .padding(.horizontal, 2)
                .frame(height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Summary: the slide's (or the lecture's) summary in grey with its time chip.
struct SummaryBlock: View {
    let model: ReviewModel
    let summary: Annotation
    @Environment(\.contentZoom) private var zoom

    var body: some View {
        VStack(alignment: .leading, spacing: 7 * zoom) {
            StudyBlockLabel(title: "Summary", mark: .ai)
            ChipParagraph(text: summary.body, time: model.player == nil ? nil : summary.startTime, play: play)
                .foregroundStyle(.secondary)
                .contextMenu { HideButton(model: model, id: summary.id) }
        }
    }

    private func play(_ time: Double) {
        Task { await model.session.play(from: time) }
    }
}

/// Further reading: verified sources, title over byline and site; a click opens the page.
/// `showsSlides` (Whole lecture) adds one slide chip per row.
struct FurtherReadingBlock: View {
    let model: ReviewModel
    let readings: [Annotation]
    var showsSlides = false
    @Environment(\.contentZoom) private var zoom

    var body: some View {
        VStack(alignment: .leading, spacing: 7 * zoom) {
            StudyBlockLabel(title: "Further reading", mark: .ai)
            // Mockup `.ref + .ref`: 3 pt more than the block's own 7.
            VStack(alignment: .leading, spacing: 10 * zoom) {
                ForEach(readings) { reading in
                    HStack(alignment: .firstTextBaseline, spacing: 8 * zoom) {
                        FurtherReadingRow(title: reading.body, byline: reading.detail, url: Self.url(of: reading))
                            .zoomScaled(zoom)
                        if showsSlides, let page = reading.pageNumber {
                            SlideChip(page: page) {
                                Task { await model.session.selectThumbnail(page: page) }
                            }
                            .zoomScaled(zoom)
                        }
                    }
                    .contextMenu { HideButton(model: model, id: reading.id) }
                }
            }
        }
    }

    static func url(of reading: Annotation) -> URL? {
        reading.citations.first { $0.kind == .web && $0.url != nil }?.url
    }
}

/// Exam hints: the professor's words with the 16 pt pin and a time chip, in time order; the
/// first `limit` rows, then "Show N more".
struct ExamHintsBlock: View {
    let model: ReviewModel
    let hints: [Annotation]
    var limit: Int?
    @State private var expanded = false
    @Environment(\.contentZoom) private var zoom

    var body: some View {
        let shown = expanded || limit == nil ? hints : Array(hints.prefix(limit ?? hints.count))
        VStack(alignment: .leading, spacing: 7 * zoom) {
            StudyBlockLabel(title: "Exam hints", mark: .exam)
            ForEach(shown) { hint in
                HStack(alignment: .top, spacing: 7 * zoom) {
                    ProvenancePin(.professor)
                        .zoomScaled(zoom)
                        .padding(.top, 1 * zoom)
                    ChipParagraph(
                        text: SourceTrailText.quote(hint.body, maxWords: 25),
                        time: model.player == nil ? nil : hint.startTime,
                        play: { time in Task { await model.session.play(from: time) } }
                    )
                    .foregroundStyle(.primary)
                }
                .contextMenu { HideButton(model: model, id: hint.id) }
            }
            if shown.count < hints.count {
                ShowMoreButton(count: hints.count - shown.count) { expanded = true }
            }
        }
    }
}

/// Only said in class: grey lines with their time chips, in time order (`limit` rows, then
/// "Show N more"), or under the category subheadlines (Whole lecture).
struct SaidInClassBlock: View {
    let model: ReviewModel
    let items: [Annotation]
    var limit: Int?
    var groups: [(category: SaidInClassCategory?, items: [Annotation])]?
    @State private var expanded = false
    @Environment(\.contentZoom) private var zoom

    var body: some View {
        VStack(alignment: .leading, spacing: 7 * zoom) {
            StudyBlockLabel(title: "Only said in class", mark: .ai)
            if let groups {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if let title = Self.title(group.category) {
                        Text(title)
                            .font(.zoomed(.subheadline, zoom))
                            .foregroundStyle(.secondary)
                            .padding(.top, index == 0 ? 0 : 3 * zoom)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(group.items) { row($0) }
                }
            } else {
                let shown = expanded || limit == nil ? items : Array(items.prefix(limit ?? items.count))
                ForEach(shown) { row($0) }
                if shown.count < items.count {
                    ShowMoreButton(count: items.count - shown.count) { expanded = true }
                }
            }
        }
    }

    private func row(_ item: Annotation) -> some View {
        ChipParagraph(
            text: item.body,
            time: model.player == nil ? nil : item.startTime,
            play: { time in Task { await model.session.play(from: time) } }
        )
        .foregroundStyle(.secondary)
        .contextMenu { HideButton(model: model, id: item.id) }
    }

    /// The subheadline of a category: Admin, Deadlines, Questions, Examples, Explanations.
    static func title(_ category: SaidInClassCategory?) -> LocalizedStringKey? {
        guard let category else { return nil }
        switch category {
        case .admin: return "Admin"
        case .deadline: return "Deadlines"
        case .question: return "Questions"
        case .example: return "Examples"
        case .explanation: return "Explanations"
        default: return nil
        }
    }
}

/// Hide (AI and professor items): gone from every surface.
struct HideButton: View {
    let model: ReviewModel
    let id: Annotation.ID

    var body: some View {
        Button("Hide") { model.hide(id) }
    }
}
