import Capture
import CaptureUI
import Search
import StudyCore
import StudyUI
import SwiftUI

/// One hit: a glyph for whose words they are, a quiet top line (who or which slide, and the one
/// jump-to-time chip), the highlighted snippet, and for a slide its thumbnail on the right.
struct SearchHitRow: View {
    let hit: SearchHit
    let label: String
    let deck: SlideDeck?
    let play: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(hit.kind == .note ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.professor))
                .frame(width: 16)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if hit.kind != .note, let time = hit.time, hit.playDestination != nil {
                        TimeChip(time, action: play)
                    }
                }
                Text(SearchHitRow.styled(hit))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hit.kind == .slide, let deck, let page = hit.page {
                SlideImageView(deck: deck, page: page, pixelWidth: SlideWidth.thumbnail, cornerRadius: 3)
                    .frame(width: 64)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch hit.kind {
        case .transcript: "waveform"
        case .slide: "rectangle.on.rectangle"
        default: "pencil"
        }
    }

    /// The snippet with its matches marked (a highlighter stroke); spoken words in quotes.
    nonisolated static func styled(_ hit: SearchHit) -> AttributedString {
        var snippet = hit.snippet
        for run in snippet.runs where run[SearchMatchAttribute.self] == true {
            snippet[run.range].backgroundColor = highlight
        }
        guard hit.kind == .transcript else { return snippet }
        return AttributedString("“") + snippet + AttributedString("”")
    }

    /// The highlighter yellow of the mockups (`--ink-hl`).
    nonisolated static let highlight = Color(red: 1, green: 214 / 255, blue: 10 / 255).opacity(0.42)
}

/// A group's header: course dot and name, then the lecture ("L2 · Virtualization & IaaS · Tue
/// 13 Oct") or deck; "Your notes" for the notes.
struct SearchGroupHeader: View {
    let group: SearchGroup
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            title
            Divider()
        }
    }

    private var title: some View {
        HStack(spacing: 7) {
            if group.kind == .notes {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text("Your notes")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            } else {
                CourseDot(course: group.course)
                Text(group.course?.name ?? group.deck?.title ?? "")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .textCase(nil)
    }

    private var subtitle: String {
        if let lecture = group.lecture {
            var parts: [String] = []
            if let number = lecture.number { parts.append("L\(number)") }
            if !lecture.title.isEmpty { parts.append(lecture.title) }
            if let held = lecture.heldAt {
                parts.append(held.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale)))
            }
            return parts.joined(separator: " · ")
        }
        guard let deck = group.deck else { return "" }
        return deck.title.isEmpty ? deck.fileName : deck.title
    }
}

extension SearchResults {
    /// The quiet top line of a hit: the lecturer's surname for a transcript line ("Example"),
    /// "Slide 16", or where a note sits ("DC L2 · Slide 16").
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
            if let page = hit.page { parts.append("Slide \(page)") }
            return parts.joined(separator: " · ")
        }
    }
}
