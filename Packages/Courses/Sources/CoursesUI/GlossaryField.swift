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

/// The glossary as a token field: terms as tokens, typing adds one (Return or comma), Delete in
/// the empty field removes the last one.
struct GlossaryField: View {
    @Binding var terms: [String]
    @State private var text = ""
    @State private var selection: String?
    @FocusState private var isTyping: Bool

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(terms, id: \.self) { term in
                Token(term: term, isSelected: selection == term)
                    .onTapGesture { selection = term }
                    .contextMenu {
                        Button("Remove", role: .destructive) { remove(term) }
                    }
            }
            // Sized by its text, so typing continues on the tokens' line.
            Text(verbatim: text + "  ")
                .font(.callout)
                .lineLimit(1)
                .hidden()
                .frame(minWidth: 48, alignment: .leading)
                .overlay(alignment: .leading) { input }
        }
        .padding(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { isTyping = true }
        #if os(macOS)
        .onDeleteCommand {
            if let selection { remove(selection) }
        }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Glossary"))
    }

    private var input: some View {
        TextField("Glossary term", text: $text)
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isTyping)
                .onSubmit(commit)
                .onChange(of: text) {
                    if text.contains(",") || text.contains(";") || text.contains("\n") { commit() }
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

private struct Token: View {
    let term: String
    let isSelected: Bool

    var body: some View {
        Text(term)
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(
                isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.14)),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
    }
}
