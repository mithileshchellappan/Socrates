import Notes
import StudyCore
import StudyUI
import SwiftUI

/// How a note is set (DESIGN 3.2, 3.3, 8.4).
public enum NoteEditorStyle: Hashable, Sendable {
    /// The Notes screen: the centred stamp, title 22 bold, body 14 on 21.7 pt lines, text at most
    /// 680 wide with 52 pt sides.
    case document
    /// Review's "Your notes" (336 pt column): body 13, no stamp.
    case inspector
}

/// A paragraph format the Format menu, the toolbar's Aa menu and the keys apply.
public enum NoteParagraphKind: String, CaseIterable, Hashable, Sendable {
    case title, heading, subheading, body, checklist, bulleted, numbered

    public var label: LocalizedStringKey {
        switch self {
        case .title: "Title"
        case .heading: "Heading"
        case .subheading: "Subheading"
        case .body: "Body"
        case .checklist: "Checklist"
        case .bulleted: "Bulleted List"
        case .numbered: "Numbered List"
        }
    }

    /// The Format menu's keys (Apple Notes'; none is taken elsewhere in the app, docs/DESIGN.md 6.8).
    public var shortcut: KeyboardShortcut {
        switch self {
        case .title: KeyboardShortcut("t", modifiers: [.command, .shift])
        case .heading: KeyboardShortcut("h", modifiers: [.command, .shift])
        case .subheading: KeyboardShortcut("j", modifiers: [.command, .shift])
        case .body: KeyboardShortcut("b", modifiers: [.command, .shift])
        case .checklist: KeyboardShortcut("l", modifiers: [.command, .shift])
        case .bulleted: KeyboardShortcut("7", modifiers: [.command, .shift])
        case .numbered: KeyboardShortcut("9", modifiers: [.command, .shift])
        }
    }

    /// The block this format writes.
    var block: (kind: NoteBlock.Kind, level: Int) {
        switch self {
        case .title: (.heading, 1)
        case .heading: (.heading, 2)
        case .subheading: (.heading, 3)
        case .body: (.paragraph, 0)
        case .checklist: (.checklist, 0)
        case .bulleted: (.bullet, 0)
        case .numbered: (.numbered, 0)
        }
    }
}

/// Character styles of the Format menu.
public enum NoteMark: String, CaseIterable, Hashable, Sendable {
    case bold, italic, underline, strikethrough, highlight

    public var label: LocalizedStringKey {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .underline: "Underline"
        case .strikethrough: "Strikethrough"
        case .highlight: "Highlight"
        }
    }

    public var shortcut: KeyboardShortcut {
        switch self {
        case .bold: KeyboardShortcut("b", modifiers: .command)
        case .italic: KeyboardShortcut("i", modifiers: .command)
        case .underline: KeyboardShortcut("u", modifiers: .command)
        case .strikethrough: KeyboardShortcut("x", modifiers: [.command, .shift])
        case .highlight: KeyboardShortcut("e", modifiers: [.command, .shift])
        }
    }

    var mark: NoteInline.Mark {
        switch self {
        case .bold: .bold
        case .italic: .italic
        case .underline: .underline
        case .strikethrough: .strikethrough
        case .highlight: .highlight
        }
    }
}

/// Where a chip in a note points; the host may handle it itself (Review plays its own recording).
public enum NoteLink: Hashable, Sendable {
    /// "S13": the deck page (and the lecture it was taken from).
    case slide(SourceRef)
    /// "37:59": a moment on a lecture's recording.
    case time(SourceRef)
}

/// Note sizes (DESIGN 3.2, 3.3, mockups 03 and 04).
struct NoteMetrics: Hashable, Sendable {
    let style: NoteEditorStyle

    var bodySize: CGFloat { style == .document ? 14 : 13 }
    /// 14 × 1.55 (document), 13 × 1.45 (inspector, mockup 03's `.mynote`).
    var lineHeight: CGFloat { style == .document ? 21.7 : 18.85 }
    var paragraphSpacing: CGFloat { style == .document ? 9 : 5 }
    /// A list level's indent: the 15 pt box and 8 pt to the text, plus a pt.
    var listIndent: CGFloat { 24 }
    var checkboxSize: CGFloat { 15 }
    /// The document's text column (DESIGN 3.3).
    static let documentSide: CGFloat = 52
    static let documentWidth: CGFloat = 680

    func headingSize(_ level: Int) -> CGFloat {
        switch (style, level) {
        case (.document, 1): 22
        case (.document, 2): 17
        case (.document, _): 15
        case (.inspector, 1): 16
        case (.inspector, 2): 14
        case (.inspector, _): 13
        }
    }

    func headingWeight(_ level: Int) -> Font.Weight {
        level == 1 ? .bold : .semibold
    }
}
