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
                .foregroundStyle(hit.kind == .note ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.professor))
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
        default: .system(size: 14, weight: .medium)
        }
    }

    static func symbol(_ kind: SearchChunkKind) -> String {
        switch kind {
        case .transcript: "waveform"
        case .slide: "display"
        default: "pencil"
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
            } else {
                CourseDot(course: group.course, size: 9)
                Text(verbatim: group.course?.name ?? group.deck?.title ?? "")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
            }
            if let subtitle = isCollapsed && group.kind == .notes ? collapsedLabel : subtitle, !subtitle.isEmpty {
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
    /// another group matches fully, and the student has not opened it (`expanded`).
    func collapses(_ group: SearchGroup, expanded: Set<SearchGroup.ID> = []) -> Bool {
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
        default:
            var parts: [String] = []
            var place = course.map { $0.shortName.isEmpty ? $0.name : $0.shortName } ?? ""
            if let number = hit.lectureID.flatMap({ lectures[$0] })?.number {
                place += place.isEmpty ? "L\(number)" : " L\(number)"
            }
            if !place.isEmpty { parts.append(place) }
            if let title = hit.title {
                parts.append(title)
            } else if let page = hit.page {
                parts.append("Slide \(page)")
            }
            return parts.joined(separator: " · ")
        }
    }
}
