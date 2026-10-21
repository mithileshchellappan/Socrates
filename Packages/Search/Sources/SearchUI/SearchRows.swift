import Capture
import CaptureUI
import Search
import StudyCore
import StudyUI
import SwiftUI

/// One hit: a glyph for whose words they are, a quiet top line (who or which slide, and the one
/// jump-to-time chip), the highlighted snippet (two lines), and for a slide its thumbnail on the
/// right. Padded as in mockup 07, so a selected hit's block lines up with the header above.
struct SearchHitRow: View {
    let hit: SearchHit
    let label: String
    let deck: SlideDeck?
    let play: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(hit.kind))
                .symbolRenderingMode(.monochrome)
                // The mockup's slide glyph is a small outline screen (about 12 × 11 pt); SF's
                // "display" draws larger and heavier at the waveform's 13 pt. Its pencil (a note)
                // is an outline about 11 pt across: SF's reads as a thin slash below 14 pt medium.
                .font(Self.glyphFont(hit.kind))
                .foregroundStyle(Self.glyphStyle(hit.kind))
                .frame(width: 16, height: 16)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if hit.kind != .note, let time = hit.time, hit.playDestination != nil {
                        TimeChip(time, action: play)
                    }
                }
                // The mockup's line heights: 16 pt for the top line, 18 pt per snippet line.
                .frame(minHeight: 16)
                Self.snippet(hit)
                    .lineSpacing(2)
                    .padding(.vertical, 1)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hit.kind == .slide, let page = hit.page {
                thumbnail(page)
            }
        }
        .padding(SearchMetrics.hitPadding)
    }

    /// The slide as a small card (64 pt, 6 pt corners, a soft shadow); a blank card of the same
    /// size until its deck is open, so the row never jumps.
    private func thumbnail(_ page: Int) -> some View {
        Group {
            if let deck {
                SlideImageView(deck: deck, page: page, pixelWidth: SlideWidth.thumbnail)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.black.opacity(0.1), lineWidth: 0.5)
                    }
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
        .frame(width: 64)
        .padding(.top, 2)
    }

    /// Spoken words (waveform), a slide (a screen on a stand, as for "Slides" elsewhere), the
    /// student's note (pencil).
    static func glyphFont(_ kind: SearchChunkKind) -> Font {
        switch kind {
        case .transcript: .system(size: 13)
        case .slide: .system(size: 11)
        case .mail, .document, .material: .system(size: 12)
        default: .system(size: 14, weight: .medium)
        }
    }

    static func symbol(_ kind: SearchChunkKind) -> String {
        switch kind {
        case .transcript: "waveform"
        case .slide: "display"
        case .mail: "envelope"
        // md: a kept document (the Documents row's glyph; never notes' doc.text).
        case .document: "doc.on.doc"
        // mt: a course material's page.
        case .material: "book"
        default: "pencil"
        }
    }

    /// The professor's words in amber, the student's notes in the accent, mail in secondary.
    static func glyphStyle(_ kind: SearchChunkKind) -> AnyShapeStyle {
        switch kind {
        case .note: AnyShapeStyle(.tint)
        case .mail, .document, .material: AnyShapeStyle(.secondary)
        default: AnyShapeStyle(Color.professor)
        }
    }

    /// The snippet as shown: a note's title (already on the top line) left out, spoken words in
    /// quotes. Matched words keep `SearchMatchAttribute`.
    nonisolated static func styled(_ hit: SearchHit) -> AttributedString {
        var snippet = hit.snippet
        let lead = hit.title.map { $0 + " · " } ?? ""
        if hit.kind == .note, !lead.isEmpty, String(snippet.characters).hasPrefix(lead) {
            snippet.removeSubrange(snippet.startIndex..<snippet.index(snippet.startIndex, offsetByCharacters: lead.count))
        }
        guard hit.kind == .transcript else { return snippet }
        return AttributedString("“") + snippet + AttributedString("”")
    }

    /// The styled snippet as text whose matches the highlighter marks (`MatchHighlightRenderer`).
    static func snippet(_ hit: SearchHit) -> some View {
        let styled = styled(hit)
        var text = Text(verbatim: "")
        for run in styled.runs {
            let piece = Text(verbatim: String(styled[run.range].characters))
            text = run[SearchMatchAttribute.self] == true
                ? Text("\(text)\(piece.customAttribute(MatchHighlight()))")
                : Text("\(text)\(piece)")
        }
        return text.textRenderer(MatchHighlightRenderer(ink: MatchInk()))
    }
}

/// M5, a Web group row (mockup 07 `.hit.web`): a quiet glyph (a paper, else a book), the title
/// (13 pt, primary: a name) over "byline · domain" (11.5 pt, secondary). The row opens the page.
struct WebHitRow: View {
    let hit: SearchHit

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(hit))
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: hit.title ?? hit.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let line = Self.sourceLine(hit) {
                    Text(verbatim: line)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(SearchMetrics.webHitPadding)
    }

    /// "Barham et al. · SOSP 2003 · dl.acm.org"; the domain alone without a byline.
    static func sourceLine(_ hit: SearchHit) -> String? {
        let parts = [hit.byline, hit.url.flatMap(FurtherReadingRow.domain)].compactMap { part -> String? in
            guard let part = part?.trimmingCharacters(in: .whitespacesAndNewlines), !part.isEmpty else { return nil }
            return part
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A paper (a DOI or arXiv link, or "et al." in the byline) gets a document; anything else
    /// (a manual, documentation, a book) a book.
    static func symbol(_ hit: SearchHit) -> String {
        let link = hit.url?.absoluteString.lowercased() ?? ""
        let byline = hit.byline?.lowercased() ?? ""
        let paper = link.contains("doi.org/") || link.contains("/doi/") || link.contains("arxiv.org") || byline.contains("et al")
        return paper ? "doc.text" : "book"
    }
}

/// M5, "Also searched" (mockup 07 `.expand`): one sparkle, "Also searched" in tertiary, then the
/// planner's alternatives in grey joined by " · ". Hovering a term shows an × that removes it
/// (and searches again). Shown only while a plan was searched.
struct AlsoSearchedLine: View {
    let terms: [String]
    let remove: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            AIMark()
                .font(.system(size: 12))
            HStack(spacing: 0) {
                Text("Also searched")
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 6)
                ForEach(Array(terms.enumerated()), id: \.element) { index, term in
                    if index > 0 {
                        Text(verbatim: " · ")
                            .foregroundStyle(.secondary)
                    }
                    AlsoSearchedTerm(term: term) { remove(term) }
                }
            }
            .lineLimit(1)
        }
        .font(.callout)
        .frame(minHeight: 17)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// One alternative; its × appears on hover.
private struct AlsoSearchedTerm: View {
    let term: String
    let remove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 3) {
            Text(verbatim: term)
                .foregroundStyle(.secondary)
            if isHovered {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(Text("Remove"))
                .accessibilityLabel(Text("Remove \(term)"))
            }
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("Remove")) { remove() }
    }
}

/// Marks a matched run of a snippet for `MatchHighlightRenderer`.
struct MatchHighlight: TextAttribute {}

/// Draws a highlighter stroke behind matched runs (mockup `.hl`: 2 pt corners, 1 pt past each
/// side), then the text.
struct MatchHighlightRenderer: TextRenderer {
    let ink: MatchInk

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line where run[MatchHighlight.self] != nil {
                let bounds = run.typographicBounds.rect.insetBy(dx: -1, dy: 0)
                context.fill(Path(roundedRect: bounds, cornerRadius: 2, style: .continuous), with: .style(ink))
            }
        }
        for line in layout {
            context.draw(line)
        }
    }
}

/// A group's header (mockup `.ghead`): course dot and name, then the lecture ("L2 · Virtualization
/// & IaaS · Tue 13 Oct") or deck in secondary text; "Your notes" under a document glyph. A hairline
/// under it. Collapsed (weak matches only), it is the whole group: the first hit's place in
/// secondary text, a chevron to open it, no line.
struct SearchGroupHeader: View {
    let group: SearchGroup
    var collapsedLabel: String?
    @Environment(\.locale) private var locale

    private var isCollapsed: Bool { collapsedLabel != nil }

    var body: some View {
        HStack(spacing: 7) {
            if group.kind == .notes {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text("Your notes")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
            } else if group.kind == .mail {
                Image(systemName: "envelope")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text("Mail")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
            } else if group.kind == .documents {
                // md: the student's kept documents, after "Your notes".
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text("Documents")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
            } else if group.kind == .materials {
                // mt: the course materials' pages, after "Your notes", before Documents.
                Image(systemName: "book.closed")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text("Materials")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
            } else if group.kind == .web {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text("Web")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
            } else {
                CourseDot(course: group.course, size: 9)
                Text(verbatim: group.course?.name ?? group.deck?.title ?? "")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
            }
            if let subtitle = isCollapsed && [.notes, .mail, .documents, .materials].contains(group.kind) ? collapsedLabel : subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .foregroundStyle(.secondary)
            }
            if isCollapsed {
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .frame(minHeight: 17)
        .padding(EdgeInsets(top: 2, leading: 8, bottom: 6, trailing: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if !isCollapsed {
                Rectangle()
                    .fill(.separator)
                    .frame(height: 0.5)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var subtitle: String? {
        if let lecture = group.lecture {
            var parts: [String] = []
            if let number = lecture.number { parts.append("L\(number)") }
            if !lecture.title.isEmpty { parts.append(lecture.title) }
            if let held = lecture.heldAt { parts.append(DayText.day(held, locale: locale)) }
            return parts.joined(separator: " · ")
        }
        guard let deck = group.deck else { return nil }
        return deck.title.isEmpty ? deck.fileName : deck.title
    }
}

extension SearchResults {
    /// Whether `group` shows as one collapsed row: it has only weak matches (not every word),
    /// another group matches fully, and the student has not opened it (`expanded`). The Web
    /// group never collapses (its rows are the reading for the hits' slides, mockup 07).
    func collapses(_ group: SearchGroup, expanded: Set<SearchGroup.ID> = []) -> Bool {
        guard group.kind != .web else { return false }
        guard !expanded.contains(group.id), group.hits.allSatisfy({ !$0.matchesAllTerms }) else { return false }
        return groups.contains { other in other.hits.contains(where: \.matchesAllTerms) }
    }

    /// The hits shown (not in a collapsed group), in order.
    func visibleHits(expanded: Set<SearchGroup.ID> = []) -> [SearchHit] {
        groups.filter { !collapses($0, expanded: expanded) }.flatMap(\.hits)
    }

    /// The quiet top line of a hit: the lecturer's surname for a transcript line ("Example"),
    /// "Slide 16", or where a note sits and its title ("DC L2 · Virtualization generations"; an
    /// untitled note on a slide: "DC L2 · Slide 16").
    func label(for hit: SearchHit) -> String {
        let course = hit.courseID.flatMap { courses[$0] }
        switch hit.kind {
        case .transcript:
            return course?.lecturerSurname ?? course?.shortName ?? ""
        case .slide:
            return hit.page.map { "Slide \($0)" } ?? ""
        case .mail:
            // Collapsed: the subject (mockup 07); a row: who wrote it and the subject.
            return [hit.sender, hit.title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        case .furtherReading:
            return hit.title ?? ""
        case .document:
            // md: "Modulhandbuch M.Sc. Informatik · p. 3".
            return [hit.title, hit.page.map { "p.\u{00A0}\($0)" }].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        case .material:
            // mt: "Data Centers: Principles in Practice · §6.3 · p. 223" (the printed page).
            return [hit.title, hit.materialSection, hit.printedPage?.replacingOccurrences(of: " ", with: "\u{00A0}")]
                .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        default:
            var parts: [String] = []
            var place = course.map { $0.shortName.isEmpty ? $0.name : $0.shortName } ?? ""
            if let number = hit.lectureID.flatMap({ lectures[$0] })?.number {
                place += place.isEmpty ? "L\(number)" : " L\(number)"
            }
            // M6: a title that already says where the note sits ("DC L2 · …") is shown alone.
            if !place.isEmpty, !(hit.title?.hasPrefix(place) ?? false) { parts.append(place) }
            if let title = hit.title {
                parts.append(title)
            } else if let page = hit.page {
                parts.append("Slide \(page)")
            }
            return parts.joined(separator: " · ")
        }
    }
}
