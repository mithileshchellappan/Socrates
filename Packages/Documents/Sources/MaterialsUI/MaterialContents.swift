import StudyCore
import StudyUI
import SwiftUI

/// The reader's contents column (docs/plan-materials.md §2.3, mockup 37): the header (the cover
/// 36 high, the title 13 semibold in 2 lines, the authors 12 secondary), then the chapters, or the
/// search's hits while a query is typed.
struct MaterialContents: View {
    let data: MaterialReaderData
    /// The page in view (1-based).
    let page: Int
    let query: String
    let hits: [MaterialSearchHit]
    let selectedHit: Int?
    let go: (Int) -> Void
    let goHit: (Int) -> Void
    let openNotes: (Lecture.ID) -> Void
    let openReview: (Lecture.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        chapters
                    } else {
                        hitList
                    }
                }
                .scrollContentBackground(.hidden)
                .onChange(of: current?.id) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var current: MaterialSection? { data.chapter(holding: page) }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            MaterialCover(document: data.document, width: 25, radius: 2)
                .frame(height: 36, alignment: .top)
                .clipped()
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: data.material?.title ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let byline = data.material?.byline, !byline.isEmpty {
                    Text(verbatim: byline)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .padding(.bottom, 12)
    }

    // MARK: Chapters

    private var chapters: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(data.chapters) { chapter in
                let isCurrent = chapter.id == current?.id
                ChapterRow(chapter: chapter, lectures: data.lectures(covering: chapter), isCurrent: isCurrent) { go(chapter.firstPage) }
                    .id(chapter.id)
                    .contextMenu { menu(chapter) }
                if isCurrent {
                    currentDetails(chapter)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }

    /// Under the chapter in view: its summary (or the skeleton while it is written) and its
    /// sections, the one holding the page in primary.
    @ViewBuilder
    private func currentDetails(_ chapter: MaterialSection) -> some View {
        let sections = data.sections(of: chapter)
        let summary = chapter.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                AIMark()
                    .font(.system(size: 10))
                Text(verbatim: summary)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 34)
            .padding(.trailing, 8)
            .padding(.top, 5)
            .padding(.bottom, 4)
        } else if data.summarizing.contains(chapter.id) {
            VStack(alignment: .leading, spacing: 5) {
                SkeletonLine(width: 170)
                SkeletonLine(width: 120)
            }
            .padding(.leading, 34)
            .padding(.vertical, 6)
        }
        if !sections.isEmpty {
            let holding = sections.filter { $0.contains(page: page) }.max { $0.firstPage < $1.firstPage }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    Button {
                        go(section.firstPage)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: [section.number, section.title].filter { !$0.isEmpty }.joined(separator: " "))
                                .font(.system(size: 12, weight: section.id == holding?.id ? .medium : .regular))
                                .foregroundStyle(section.id == holding?.id ? .primary : .secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if let printed = section.printedFirst {
                                Text(verbatim: printed)
                                    .font(.mono(11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.leading, 48)
                        .padding(.trailing, 8)
                        .padding(.vertical, 2.5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func menu(_ chapter: MaterialSection) -> some View {
        ForEach(data.lectures(covering: chapter), id: \.id) { lecture in
            let name = lecture.number.map { String(localized: "Lecture \($0)") } ?? lecture.title
            Button(String(localized: "Open \(name)’s Notes")) { openNotes(lecture.id) }
            Button(String(localized: "Open \(name) in Review")) { openReview(lecture.id) }
        }
        if !data.lectures(covering: chapter).isEmpty { Divider() }
        Button("Copy Title") {
            MaterialPasteboard.copy([chapter.number, chapter.title].filter { !$0.isEmpty }.joined(separator: " "))
        }
    }

    // MARK: Hits

    private var hitList: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                Button {
                    goHit(index)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MaterialSearch.marked(hit.snippet, query: query))
                            .font(.system(size: 12.5))
                            .lineSpacing(1.5)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: label(hit))
                            .font(.mono(11))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 7)
                    .background {
                        if index == selectedHit {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(QuietFill())
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }

    /// "§6.2 · p. 218".
    private func label(_ hit: MaterialSearchHit) -> String {
        guard let material = data.material else { return "p. \(hit.page)" }
        return MaterialText.citeLabel(section: MaterialSection.holding(page: hit.page, in: data.sections), material: material, pdfPage: hit.page)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}

/// A chapter: number (SF Mono 12 tertiary, right-aligned in 24) · title (13, ≤ 2 lines) … the
/// printed first page (SF Mono 11.5 tertiary); a second line "L2 · L3" (12 secondary, help the
/// lectures' titles) when lectures cover it. The chapter in view sits on the fill (the pages have
/// the focus: the unemphasized selection).
private struct ChapterRow: View {
    let chapter: MaterialSection
    let lectures: [MaterialReaderData.LectureRef]
    let isCurrent: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: chapter.number)
                    .font(.mono(12))
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: chapter.title)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !lectures.isEmpty {
                        Text(verbatim: lectureLine)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .help(Text(verbatim: lectures.map(\.title).joined(separator: "\n")))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let printed = chapter.printedFirst {
                    Text(verbatim: printed)
                        .font(.mono(11.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 5)
            .padding(.leading, 2)
            .padding(.trailing, 8)
            .background {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255).opacity(colorScheme == .dark ? 0.28 : 0.16))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// "L2 · L3".
    private var lectureLine: String {
        lectures.map { $0.number.map { "L\($0)" } ?? $0.title }.joined(separator: " · ")
    }
}

// MARK: - Search

/// A hit of the reader's search: a page of the material's text with the query in it.
struct MaterialSearchHit: Identifiable, Hashable, Sendable {
    var id: String { "\(page)-\(offset)" }
    /// 1-based PDF page.
    var page: Int
    var offset: Int
    /// About a line and a half around the match, "…" where cut.
    var snippet: String
    /// The match as the page has it (marked on the page).
    var match: String
}

/// The reader's search over the material's text (the bank's `document_page` rows, on the Mac),
/// and its marks.
enum MaterialSearch {
    static let limit = 60

    static func hits(query: String, documentID: StudyDocument.ID, database: any DatabaseReader) async throws -> [MaterialSearchHit] {
        let pattern = "%\(query)%"
        let pages = try await database.read { db in
            try StudyDocumentPage
                .where { $0.documentID.eq(documentID) && $0.text.like(pattern) }
                .order { $0.pageNumber.asc() }
                .select { ($0.pageNumber, $0.text) }
                .limit(limit)
                .fetchAll(db)
        }
        var hits: [MaterialSearchHit] = []
        for (page, text) in pages {
            var range = text.startIndex..<text.endIndex
            var count = 0
            while let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range), count < 3 {
                hits.append(MaterialSearchHit(
                    page: page, offset: text.distance(from: text.startIndex, to: found.lowerBound),
                    snippet: snippet(text, around: found), match: String(text[found])
                ))
                range = found.upperBound..<text.endIndex
                count += 1
            }
            if hits.count >= limit { break }
        }
        return Array(hits.prefix(limit))
    }

    /// From the start of the sentence before the match (at most 30 characters back) to about 110
    /// characters after it, on word boundaries, line breaks as spaces.
    static func snippet(_ text: String, around match: Range<String.Index>) -> String {
        var start = text.index(match.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
        if let sentence = text[start..<match.lowerBound].lastIndex(where: { ".!?\n".contains($0) }) {
            start = text.index(after: sentence)
        } else if start > text.startIndex, let space = text[start..<match.lowerBound].firstIndex(of: " ") {
            start = text.index(after: space)
        }
        var end = text.index(match.upperBound, offsetBy: 110, limitedBy: text.endIndex) ?? text.endIndex
        if end < text.endIndex, let space = text[match.upperBound..<end].lastIndex(of: " ") { end = space }
        var snippet = text[start..<end].replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if start > text.startIndex, !".!?\n".contains(text[text.index(before: start)]) { snippet = "…" + snippet }
        if end < text.endIndex { snippet += "…" }
        return snippet
    }

    /// The snippet with every match of the query on the highlighter.
    @MainActor
    static func marked(_ snippet: String, query: String) -> AttributedString {
        var text = AttributedString(snippet)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return text }
        var from = snippet.startIndex
        while let found = snippet.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: from..<snippet.endIndex) {
            if let range = Range(found, in: text) {
                text[range].backgroundColor = Color(.sRGB, red: 1, green: 214 / 255, blue: 10 / 255, opacity: 0.45)
            }
            from = found.upperBound
        }
        return text
    }

    /// One page's text.
    static func pageText(documentID: StudyDocument.ID, page: Int, database: any DatabaseReader) async throws -> String? {
        try await database.read { db in
            try StudyDocumentPage.where { $0.documentID.eq(documentID) && $0.pageNumber.eq(page) }.select(\.text).fetchOne(db)
        }
    }

    /// The first words of a page's first sentence: its first paragraph of at least 8 words (a
    /// running head, a number or a heading line left out), up to its first full stop.
    @Sendable
    static func firstWords(_ text: String) -> String? {
        let paragraphs = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let paragraph = paragraphs.first(where: { $0.split(separator: " ").count >= 8 }) else { return nil }
        let sentence = paragraph.split(separator: ".", maxSplits: 1).first.map(String.init) ?? paragraph
        return sentence.split(separator: " ").prefix(8).joined(separator: " ")
    }
}
