import Courses
import StudyCore
import StudyUI
import SwiftUI

/// Lays its subviews out left to right, wrapping into new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y + (row.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
            }
        }
    }

    private struct Item {
        var index: Int
        var x: CGFloat
        var size: CGSize
    }

    private struct Row {
        var y: CGFloat
        var height: CGFloat = 0
        var width: CGFloat = 0
        var items: [Item] = []
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row(y: 0)
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let x = row.items.isEmpty ? 0 : row.width + spacing
            if !row.items.isEmpty, x + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + lineSpacing)
                row.items.append(Item(index: index, x: 0, size: size))
                row.width = size.width
                row.height = size.height
                continue
            }
            row.items.append(Item(index: index, x: x, size: size))
            row.width = x + size.width
            row.height = max(row.height, size.height)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// The glossary as a token field: terms as tokens inside a field box, typing continues after the
/// last token (Return or comma adds), Delete in the empty field removes the last one. Typing
/// completes from the slides: the rest of the word shows selected with its page ("virt|io S20");
/// Tab or Return takes it.
struct GlossaryField: View {
    @Binding var terms: [String]
    var completion: (String) -> GlossaryCompletion? = { _ in nil }
    @State private var text = ""
    /// Snapshots: draw the field as if typing `text` (focus cannot be set from outside).
    var showsTyping: String?
    @State private var selection: String?
    @FocusState private var isTyping: Bool

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(terms, id: \.self) { term in
                Text(term)
                    .tokenStyle(isSelected: selection == term)
                    .foregroundStyle(selection == term ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .onTapGesture { selection = term }
                    .contextMenu {
                        Button("Remove", role: .destructive) { remove(term) }
                    }
            }
            input
        }
        .padding(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fieldBackground, in: .rect(cornerRadius: 7))
        .focusRing(isTyping || showsTyping != nil, cornerRadius: 7)
        .contentShape(Rectangle())
        .onTapGesture { isTyping = true }
        .onAppear { if let showsTyping { text = showsTyping } }
        #if os(macOS)
        .onDeleteCommand {
            if let selection { remove(selection) }
        }
        #endif
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Glossary"))
    }

    private var suggestion: GlossaryCompletion? {
        guard isTyping || showsTyping != nil, !text.isEmpty, !text.contains(where: { $0 == "," || $0 == ";" }) else { return nil }
        return completion(text)
    }

    /// The field sized by its text, so typing continues on the tokens' line; the completion after it.
    private var input: some View {
        HStack(spacing: 0) {
            Text(verbatim: text.isEmpty ? (terms.isEmpty ? String(localized: "Add term") : " ") : text)
                .font(.callout)
                .lineLimit(1)
                .hidden()
                .padding(.leading, 2)
                .padding(.trailing, 1)
                .frame(minWidth: terms.isEmpty ? 72 : 12, alignment: .leading)
                .overlay(alignment: .leading) { field }
            if let suggestion, suggestion.term.count > text.count {
                Text(verbatim: String(suggestion.term.dropFirst(text.count)))
                    .font(.callout)
                    .background(.tint.opacity(0.3), in: .rect(cornerRadius: 2))
                Text(verbatim: "S\(suggestion.page)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 6)
                    .accessibilityLabel(Text("Slide \(suggestion.page)"))
            }
        }
        .frame(height: 20)
        .padding(.leading, 3)
    }

    private var field: some View {
        // A prompt only while the glossary is empty; otherwise the field is a caret after the tokens.
        TextField("Glossary term", text: $text, prompt: terms.isEmpty ? Text("Add term") : Text(verbatim: ""))
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.callout)
            .focused($isTyping)
            .onSubmit {
                if acceptSuggestion() { isTyping = true } else { commit() }
            }
            .onChange(of: text) {
                selection = nil
                if text.contains(",") || text.contains(";") || text.contains("\n") { commit() }
            }
            .onKeyPress(.tab) {
                acceptSuggestion() ? .handled : .ignored
            }
            .onKeyPress(.delete) {
                guard text.isEmpty, let last = terms.last else { return .ignored }
                if selection == last {
                    remove(last)
                } else {
                    selection = last
                }
                return .handled
            }
            .onChange(of: isTyping) {
                if !isTyping { commit() }
            }
    }

    /// Adds the completed word; false when there is none.
    private func acceptSuggestion() -> Bool {
        guard let suggestion else { return false }
        text = ""
        if !terms.contains(where: { $0.caseInsensitiveCompare(suggestion.term) == .orderedSame }) {
            terms.append(suggestion.term)
        }
        return true
    }

    private func commit() {
        let new = text
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !terms.contains($0) }
        text = ""
        if !new.isEmpty { terms.append(contentsOf: new) }
    }

    private func remove(_ term: String) {
        terms.removeAll { $0 == term }
        if selection == term { selection = nil }
    }
}

/// "✦ Suggested": the heading of the glossary's suggestions.
struct SuggestedHeader: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .imageScale(.small)
                .foregroundStyle(Color.ai)
                .accessibilityHidden(true)
            Text("Suggested")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.top, 7)
        .padding(.bottom, 4)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One suggested term in the AI style: what the transcriber wrote instead (struck through), where
/// it came from (one chip), and Add.
struct GlossarySuggestionRow: View {
    let suggestion: GlossarySuggestion
    let add: () -> Void
    let dismiss: () -> Void
    let open: (Lecture.ID, ReviewTarget) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(suggestion.term)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Group {
                if case .correction(_, _, _, let replaced) = suggestion.source, !replaced.isEmpty {
                    Text(replaced)
                        .strikethrough(color: .secondary)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityLabel(Text("Instead of \(replaced)"))
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            chip
            Button("Add", action: add)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(minHeight: 22)
        .padding(.vertical, 3)
        .padding(.horizontal, 12)
        .contextMenu {
            Button("Add to Glossary", action: add)
            Button("Dismiss", action: dismiss)
        }
    }

    @ViewBuilder
    private var chip: some View {
        switch suggestion.source {
        case .correction(let lectureID, let number, let time, _):
            TimeChip(time, prefix: number.map { "L\($0)" }) {
                open(lectureID, ReviewTarget(time: time))
            }
        case .slide(let lectureID, _, let page):
            SlideChip(page: page) {
                if let lectureID { open(lectureID, ReviewTarget(page: page)) }
            }
        }
    }
}

/// The course's glossary vocabulary (`GlossarySuggestions`), recomputed when its transcripts,
/// slides or slide spans change. Glossary edits are applied by the view.
struct GlossaryVocabularyRequest: FetchKeyRequest {
    let courseID: Course.ID

    func fetch(_ db: Database) throws -> GlossaryVocabulary {
        let lectures = try Lecture.where { $0.courseID.eq(courseID) }.fetchAll(db)
        var segments: [GlossarySuggestions.Segment] = []
        var spans: [GlossarySuggestions.Span] = []
        for lecture in lectures {
            segments += try TranscriptSegment.where { $0.lectureID.eq(lecture.id) }.fetchAll(db).map { segment in
                GlossarySuggestions.Segment(
                    lectureID: lecture.id, startTime: segment.startTime, text: segment.text,
                    originalText: segment.originalText, revision: segment.revision
                )
            }
            spans += try LectureDeckSpan.where { $0.lectureID.eq(lecture.id) }.fetchAll(db).compactMap { span in
                guard let first = span.firstPage else { return nil }
                let seconds = span.startTime.flatMap { start in span.endTime.map { max(0, $0 - start) } } ?? 0
                return GlossarySuggestions.Span(
                    lectureID: lecture.id, deckID: span.deckID, firstPage: first, lastPage: span.lastPage ?? first, seconds: seconds
                )
            }
        }
        var pages: [GlossarySuggestions.Page] = []
        for deck in try Deck.where({ $0.courseID.eq(courseID) }).order(by: \.importedAt).fetchAll(db) {
            pages += try DeckPage.where { $0.deckID.eq(deck.id) }.order(by: \.pageNumber).fetchAll(db).map { page in
                GlossarySuggestions.Page(deckID: deck.id, pageNumber: page.pageNumber, text: page.text)
            }
        }
        let newestFirst = lectures.sorted { ($0.heldAt ?? $0.createdAt) > ($1.heldAt ?? $1.createdAt) }
        return GlossarySuggestions.vocabulary(GlossarySuggestions.Input(
            lectureNumbers: Dictionary(lectures.compactMap { lecture in lecture.number.map { (lecture.id, $0) } }, uniquingKeysWith: { first, _ in first }),
            lectureOrder: newestFirst.map(\.id),
            segments: segments,
            pages: pages,
            spans: spans
        ))
    }
}
