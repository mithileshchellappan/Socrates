import StudyCore
import StudyPageFormat
import StudyUI
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Where a lecture's notes are read: the pushed page (Lectures) or Review's Whole lecture pane.
public enum LectureNotesStyle: Hashable, Sendable {
    /// The page: Notes' 14 pt body on 21.7 pt lines (docs/plan-lecture-notes.md §2.2).
    case page
    /// Review's inspector (336 pt): the inspector notes' 13 pt on 18.85 pt lines.
    case inspector
}

/// The notes' sizes (mockups 30–33: `.pg`, `.nt h4`, `.nt h5`, `.call`, `.kept`, `.code`, `.tbl`).
struct NotesMetrics: Hashable, Sendable {
    let style: LectureNotesStyle

    var body: CGFloat { style == .page ? 14 : 13 }
    var lineHeight: CGFloat { style == .page ? 21.7 : 18.85 }
    /// Space after a paragraph (the mockup's 12 pt margin less the line's leading).
    var paragraphSpacing: CGFloat { style == .page ? 12 : 9 }
    /// A section heading (`h4`): 15 semibold, 30 pt above, 8 below.
    var sectionHeading: CGFloat { style == .page ? 15 : 13.5 }
    var sectionSpacingBefore: CGFloat { style == .page ? 30 : 20 }
    /// A sub-heading inside a section (`h5`: "Worked example", "Check yourself"): 13 semibold.
    var subheading: CGFloat { style == .page ? 13 : 12.5 }
    /// Callouts, kept answers, tables, professor quotes: 13 pt.
    var small: CGFloat { style == .page ? 13 : 12.5 }
    var code: CGFloat { style == .page ? 12 : 11.5 }
    var chip: CGFloat { 10.5 }
    /// Figures: chart 180, diagram up to 260.
    var chartHeight: CGFloat { style == .page ? 180 : 150 }
    /// The widest a slide is drawn (`.slide`: 352 × 198).
    var slideWidth: CGFloat { style == .page ? 352 : 296 }
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
