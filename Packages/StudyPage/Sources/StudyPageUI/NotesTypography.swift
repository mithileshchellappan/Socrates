import StudyCore
import StudyPageFormat
import StudyUI
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Where a lecture's notes are read: the pushed page (Lectures) or Review's Summary tab.
public enum LectureNotesStyle: Hashable, Sendable {
    /// The page: Notes' 14 pt body on 21.7 pt lines (docs/plan-lecture-notes.md §2.2).
    case page
    /// Review's inspector (336 pt): the inspector notes' 13 pt on 18.85 pt lines.
    case inspector
}

/// The notes' sizes (mockups 30–35: `.pg`, `.nt h4`, `.nt h5`, `.call`, `.kept`, `.code`, `.tbl`),
/// times the content zoom (nl, docs/plan-notes-layout.md §11: View ▸ Zoom In / Out scales every
/// size of the notes, as Word does).
struct NotesMetrics: Hashable, Sendable {
    let style: LectureNotesStyle
    /// `\.contentZoom` (1 = 100 %).
    let zoom: CGFloat

    init(style: LectureNotesStyle, zoom: CGFloat = 1) {
        self.style = style
        self.zoom = zoom
    }

    /// `points` at the zoom.
    func scaled(_ points: CGFloat) -> CGFloat { points * zoom }

    var body: CGFloat { scaled(style == .page ? 14 : 13) }
    var lineHeight: CGFloat { scaled(style == .page ? 21.7 : 18.85) }
    /// Space after a paragraph (the mockup's 12 pt margin less the line's leading).
    var paragraphSpacing: CGFloat { scaled(style == .page ? 12 : 9) }
    /// A section heading (`h4`): 15 semibold, 30 pt above, 8 below.
    var sectionHeading: CGFloat { scaled(style == .page ? 15 : 13.5) }
    var sectionSpacingBefore: CGFloat { scaled(style == .page ? 30 : 20) }
    /// A sub-heading inside a section (`h5`: "Worked example", "Check yourself"): 13 semibold.
    var subheading: CGFloat { scaled(style == .page ? 13 : 12.5) }
    /// Callouts, kept answers, tables, professor quotes: 13 pt.
    var small: CGFloat { scaled(style == .page ? 13 : 12.5) }
    var code: CGFloat { scaled(style == .page ? 12 : 11.5) }
    var chip: CGFloat { scaled(10.5) }
    /// A display formula.
    var displayMath: CGFloat { scaled(style == .page ? 17 : 15) }
    /// Figures: chart 180, diagram up to 260.
    var chartHeight: CGFloat { scaled(style == .page ? 180 : 150) }
    /// The widest a slide is drawn: on the page it breaks out to at most 640 (nl, §1), centred; in
    /// Review's pane 296.
    var slideWidth: CGFloat { scaled(style == .page ? 640 : 296) }
}

/// The notes page's widths (nl, docs/plan-notes-layout.md §1, §11), from the page's width C (the
/// detail column, less Your notes while it is open) and the content zoom z: side margins 52 (22
/// when C < 640), the text at most 780 z wide (`measure`), code, tables, diagrams and charts at
/// most 1120 z (`wide`), both centred, so prose sits `inset` in from the figures' edges.
public struct NotesPageLayout: Hashable, Sendable {
    /// The text's width.
    public let measure: CGFloat
    /// The breakouts' width (and the text view's).
    public let wide: CGFloat
    /// The page's side margin.
    public let margin: CGFloat

    /// The prose's indent on each side of `wide`.
    public var inset: CGFloat { max(0, (wide - measure) / 2) }

    public init(pageWidth: CGFloat, zoom: CGFloat = 1) {
        margin = pageWidth < 640 ? 22 : 52
        let available = max(120, floor(pageWidth - 2 * margin))
        measure = min(available, floor(780 * zoom))
        wide = min(available, floor(1120 * zoom))
    }
}

/// The notes' inks (DESIGN 3.1): Claude's sentences secondary, emphasis primary, the student's
/// notes primary, the professor amber only as a pin or bar.
enum NotesInk {
    /// Code tokens (DESIGN 3.1 "Code tokens"): keywords pink semibold, types and calls teal,
    /// strings indigo, numbers brown, comments tertiary, the rest primary (mixed toward the label
    /// as the mockup's `--tk-*`).
    static func token(_ kind: CodeTokenKind?) -> Color {
        switch kind {
        case .keyword?: Color.pink.mix(with: .primary, by: 0.22)
        case .type?: Color.teal.mix(with: .primary, by: 0.34)
        case .string?: Color.indigo.mix(with: .primary, by: 0.26)
        case .number?: Color.brown.mix(with: .primary, by: 0.14)
        case .comment?: Color(white: 0.5).opacity(0.85)
        case nil: Color.primary
        }
    }
}

#if os(macOS)
@MainActor
enum NotesNSInk {
    /// Solid inks (DESIGN 3.1's values, as the agent panel's `AnswerInk`): the document is drawn
    /// again when the appearance changes.
    static func label(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255, alpha: 1) : NSColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1)
    }

    /// Claude's sentences: #6e6e73 / #a1a1a6.
    static func secondary(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0xA1 / 255, green: 0xA1 / 255, blue: 0xA6 / 255, alpha: 1) : NSColor(srgbRed: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255, alpha: 1)
    }

    /// Bullets and quiet marks: #a1a1a6 / #6e6e73.
    static func tertiary(_ dark: Bool) -> NSColor {
        secondary(!dark)
    }

    static func ai(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0xBF / 255, green: 0x8C / 255, blue: 0xFF / 255, alpha: 1) : NSColor(srgbRed: 0x8A / 255, green: 0x56 / 255, blue: 0xD1 / 255, alpha: 1)
    }

    static func professor(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 1, green: 0x9F / 255, blue: 0x0A / 255, alpha: 1) : NSColor(srgbRed: 0xF0 / 255, green: 0x8A / 255, blue: 0, alpha: 1)
    }

    static func quietFill(_ dark: Bool) -> NSColor {
        NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: dark ? 0.20 : 0.10)
    }

    static func highlighter(_ dark: Bool) -> NSColor {
        NSColor(srgbRed: 1, green: 214 / 255, blue: 10 / 255, alpha: dark ? 0.40 : 0.45)
    }
    /// QuietFill (rgb 120,120,128 at 10 % / 20 %).
    static let quietFill = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: dark ? 0.20 : 0.10)
    }
    /// Fill 2 (the same grey at 17 % / 30 %): a hovered kept answer.
    static let fill2 = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: dark ? 0.30 : 0.17)
    }
    /// The student's highlighter (`Color.highlighter`).
    static let highlighter = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(srgbRed: 1, green: 214 / 255, blue: 10 / 255, alpha: dark ? 0.40 : 0.45)
    }
    /// Accent soft: the passage an Ask is about, or a hovered kept answer's.
    static let accentSoft = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.controlAccentColor.withAlphaComponent(dark ? 0.24 : 0.12)
    }

    static func token(_ kind: CodeTokenKind?) -> NSColor {
        NSColor(NotesInk.token(kind))
    }
}
#endif
