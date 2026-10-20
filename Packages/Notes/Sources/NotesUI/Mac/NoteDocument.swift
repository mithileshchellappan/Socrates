#if os(macOS)
import AppKit
import Notes
import StudyCore
import StudyUI
import SwiftUI

// The blocks ⇄ text mapping of the Mac editor (docs/plan-m6.md §4): one editor paragraph is one
// `NoteBlock`. A paragraph's format (Title, Heading, Body, a list item and its indent and box) is
// the `noteBlock` attribute on its characters and newline; character styles are explicit
// attributes (the font is derived from them and the paragraph); chips, inline media, professor
// quotes and anything the editor does not know are attachments (`NoteAttachments.swift`) that
// keep their `NoteInline` or `NoteBlock` as they were.

extension NSAttributedString.Key {
    /// `BlockFormat`: the paragraph's block.
    static let noteBlock = NSAttributedString.Key("StudyPortal.noteBlock")
    static let noteBold = NSAttributedString.Key("StudyPortal.noteBold")
    static let noteItalic = NSAttributedString.Key("StudyPortal.noteItalic")
    static let noteUnderline = NSAttributedString.Key("StudyPortal.noteUnderline")
    static let noteStrikethrough = NSAttributedString.Key("StudyPortal.noteStrikethrough")
    static let noteHighlight = NSAttributedString.Key("StudyPortal.noteHighlight")
    /// ln: Claude's words copied from lecture notes (`NoteInline.Mark.ai`): grey until the student
    /// edits them.
    static let noteAI = NSAttributedString.Key("StudyPortal.noteAI")
    /// ln: code (`NoteInline.Mark.code`), in SF Mono.
    static let noteCode = NSAttributedString.Key("StudyPortal.noteCode")
    /// Marks the editor shows nothing for (newer ones), kept as they were.
    static let noteOtherMarks = NSAttributedString.Key("StudyPortal.noteOtherMarks")
}

/// A paragraph's block: its kind, heading level or list indent, its box, and the block it was
/// loaded from (kept as it was when the paragraph did not change).
final class BlockFormat: NSObject, Sendable {
    let kind: NoteBlock.Kind
    /// Heading level 1…3; a list item's indent.
    let level: Int
    let checked: Bool
    let origin: NoteBlock?

    init(kind: NoteBlock.Kind, level: Int = 0, checked: Bool = false, origin: NoteBlock? = nil) {
        self.kind = kind
        self.level = level
        self.checked = checked
        self.origin = origin
    }

    static let body = BlockFormat(kind: .paragraph)
    static let title = BlockFormat(kind: .heading, level: 1)

    /// The format a block is shown with (blocks the editor shows as attachments: body).
    convenience init(block: NoteBlock) {
        switch block.type {
        case .heading:
            self.init(kind: .heading, level: min(max(block.level ?? 1, 1), 3), origin: block)
        case .bullet, .numbered, .checklist:
            self.init(kind: block.type, level: min(max(block.level ?? 0, 0), 6), checked: block.checked == true, origin: block)
        case .paragraph:
            self.init(kind: .paragraph, level: 0, origin: block)
        default:
            self.init(kind: .paragraph)
        }
    }

    var isList: Bool { kind == .bullet || kind == .numbered || kind == .checklist }

    var paragraphKind: NoteParagraphKind {
        switch kind {
        case .heading: level == 1 ? .title : level == 2 ? .heading : .subheading
        case .checklist: .checklist
        case .bullet: .bulleted
        case .numbered: .numbered
        default: .body
        }
    }

    func with(kind: NoteBlock.Kind? = nil, level: Int? = nil, checked: Bool? = nil) -> BlockFormat {
        BlockFormat(kind: kind ?? self.kind, level: level ?? self.level, checked: checked ?? self.checked, origin: origin)
    }

    static func make(_ paragraph: NoteParagraphKind, from current: BlockFormat) -> BlockFormat {
        let (kind, level) = paragraph.block
        let keepsIndent = current.isList && (kind == .bullet || kind == .numbered || kind == .checklist)
        return BlockFormat(kind: kind, level: keepsIndent ? current.level : level, checked: false, origin: current.origin)
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? BlockFormat else { return false }
        return kind == other.kind && level == other.level && checked == other.checked && origin == other.origin
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(kind)
        hasher.combine(level)
        hasher.combine(checked)
        hasher.combine(origin)
        return hasher.finalize()
    }
}

/// Fonts, paragraph styles and run attributes for a style (DESIGN 3.2).
@MainActor
struct NoteTypesetter {
    let metrics: NoteMetrics

    func font(_ format: BlockFormat, bold: Bool = false, italic: Bool = false) -> NSFont {
        var size = metrics.bodySize
        var weight = NSFont.Weight.regular
        if format.kind == .heading {
            size = metrics.headingSize(format.level)
            weight = format.level == 1 ? .bold : .semibold
        }
        if bold { weight = format.kind == .heading ? .heavy : .bold }
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    func paragraphStyle(_ format: BlockFormat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let font = font(format)
        let natural = font.ascender - font.descender + font.leading
        if format.kind == .heading {
            style.lineSpacing = 2
            style.paragraphSpacingBefore = format.level == 1 ? 0 : 4
        } else {
            style.lineSpacing = max(0, metrics.lineHeight - natural)
        }
        style.paragraphSpacing = metrics.paragraphSpacing
        if format.isList {
            let indent = metrics.listIndent * CGFloat(format.level + 1)
            style.firstLineHeadIndent = indent
            style.headIndent = indent
        }
        return style
    }

    /// The paragraph's own attributes (an empty paragraph's newline, typing in it).
    func paragraphAttributes(_ format: BlockFormat) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .noteBlock: format,
            .paragraphStyle: paragraphStyle(format),
            .font: font(format),
            .foregroundColor: NSColor.labelColor
        ]
        if format.kind == .heading, format.level == 1 { attributes[.kern] = -0.22 }
        return attributes
    }

    /// A text run's attributes.
    func attributes(_ format: BlockFormat, marks: [NoteInline.Mark]) -> [NSAttributedString.Key: Any] {
        var attributes = paragraphAttributes(format)
        let set = Set(marks)
        let bold = set.contains(.bold)
        let italic = set.contains(.italic)
        attributes[.font] = font(format, bold: bold, italic: italic)
        if bold { attributes[.noteBold] = true }
        if italic { attributes[.noteItalic] = true }
        if set.contains(.underline) {
            attributes[.noteUnderline] = true
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if set.contains(.strikethrough) {
            attributes[.noteStrikethrough] = true
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if set.contains(.highlight) {
            attributes[.noteHighlight] = true
            attributes[.backgroundColor] = Self.highlightColor
        }
        if set.contains(.code) {
            attributes[.noteCode] = true
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: max(10, metrics.bodySize - 1.5), weight: bold ? .semibold : .regular)
        }
        if set.contains(.ai) {
            // Claude's words (Edit as Note): grey, the paragraph's one sparkle hung before its
            // first line (`NoteAIFragment`); an edit takes the words it touches.
            attributes[.noteAI] = true
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
        }
        let known: Set<NoteInline.Mark> = [.bold, .italic, .underline, .strikethrough, .highlight, .code, .ai]
        let other = marks.filter { !known.contains($0) }.map(\.rawValue)
        if !other.isEmpty { attributes[.noteOtherMarks] = other }
        return attributes
    }

    /// The highlighter (`--ink-hl`, StudyUI's `Color.highlighter`): yellow at 45 % (40 % dark).
    static let highlightColor = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(Color.highlighter(dark ? .dark : .light))
    }

    /// Marks of a run from its attributes.
    static func marks(_ attributes: [NSAttributedString.Key: Any]) -> [NoteInline.Mark] {
        var marks: [NoteInline.Mark] = []
        if attributes[.noteBold] as? Bool == true { marks.append(.bold) }
        if attributes[.noteItalic] as? Bool == true { marks.append(.italic) }
        if attributes[.noteUnderline] as? Bool == true { marks.append(.underline) }
        if attributes[.noteStrikethrough] as? Bool == true { marks.append(.strikethrough) }
        if attributes[.noteHighlight] as? Bool == true { marks.append(.highlight) }
        if attributes[.noteCode] as? Bool == true { marks.append(.code) }
        if attributes[.noteAI] as? Bool == true { marks.append(.ai) }
        if let other = attributes[.noteOtherMarks] as? [String] { marks += other.map(NoteInline.Mark.init(rawValue:)) }
        return marks
    }
}

/// Blocks → the editor's text.
@MainActor
struct NoteDocumentBuilder {
    let typesetter: NoteTypesetter
    let context: NoteEditorContext?

    func document(_ blocks: [NoteBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let (format, content) = paragraph(block)
            result.append(content)
            if index < blocks.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: typesetter.paragraphAttributes(format)))
            }
        }
        return result
    }

    /// One block's paragraph (without its newline) and the format it carries.
    func paragraph(_ block: NoteBlock) -> (BlockFormat, NSAttributedString) {
        switch block.type {
        case .paragraph, .heading, .bullet, .numbered, .checklist:
            let format = BlockFormat(block: block)
            return (format, runs(block.inlines ?? [NoteInline(text: block.text)], format: format))
        case .quote:
            return (.body, attachment(QuoteAttachment(block: block, context: context), format: .body))
        case .image, .drawing, .slide:
            return (.body, attachment(MediaAttachment(block: block, context: context), format: .body))
        default:
            return (.body, attachment(KeptAttachment(block: block, context: context), format: .body))
        }
    }

    /// Runs in `format`: text with its styles, links, chips and inline media.
    func runs(_ inlines: [NoteInline], format: BlockFormat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var sparkled = false
        for inline in inlines {
            // ln: one sparkle before the paragraph's first words Claude wrote.
            if !sparkled, inline.type == .text, (inline.marks ?? []).contains(.ai), !inline.text.allSatisfy(\.isWhitespace) {
                result.append(attachment(AISparkleAttachment(context: context), format: format))
                sparkled = true
            }
            switch inline.type {
            case .text:
                result.append(text(inline.text, format: format, marks: inline.marks ?? []))
            case .link:
                let run = NSMutableAttributedString(attributedString: text(inline.text, format: format, marks: inline.marks ?? []))
                if let url = inline.url { run.addAttribute(.link, value: url, range: NSRange(location: 0, length: run.length)) }
                result.append(run)
            case .slideRef, .timeRef:
                result.append(attachment(ChipAttachment(inline: inline, context: context), format: format))
            case .attachment:
                if let kind = inline.attachment?.kind, kind == .image || kind == .drawing || kind == .slide {
                    result.append(attachment(MediaAttachment(inline: inline, context: context), format: format))
                } else {
                    result.append(attachment(KeptAttachment(inline: inline, context: context), format: format))
                }
            default:
                result.append(attachment(KeptAttachment(inline: inline, context: context), format: format))
            }
        }
        return result
    }

    func text(_ string: String, format: BlockFormat, marks: [NoteInline.Mark]) -> NSAttributedString {
        // A line break inside a block (⇧↩) is U+2028 in the editor, "\n" in the block's text.
        NSAttributedString(string: string.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: typesetter.attributes(format, marks: marks))
    }

    func attachment(_ content: any NoteAttachmentContent, format: BlockFormat) -> NSAttributedString {
        var attributes = typesetter.paragraphAttributes(format)
        attributes[.attachment] = NoteTextAttachment(content)
        return NSAttributedString(string: "\u{FFFC}", attributes: attributes)
    }
}

/// The editor's text → blocks.
@MainActor
enum NoteDocumentReader {
    static func blocks(from text: NSAttributedString) -> [NoteBlock] {
        let string = text.string as NSString
        var blocks: [NoteBlock] = []
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            var content = paragraph
            while content.length > 0, let scalar = UnicodeScalar(string.character(at: NSMaxRange(content) - 1)),
                  CharacterSet.newlines.contains(scalar), scalar != "\u{2028}" {
                content.length -= 1
            }
            let format = text.attribute(.noteBlock, at: paragraph.location, effectiveRange: nil) as? BlockFormat ?? .body
            blocks += Self.blocks(of: text, content: content, format: format)
        }
        while let last = blocks.last, last.type == .paragraph, last.text.isEmpty, last.inlines == nil, last.attachment == nil {
            blocks.removeLast()
        }
        return blocks
    }

    /// The block (or, around a quote or an older media block, the blocks) of one paragraph.
    static func blocks(of text: NSAttributedString, content: NSRange, format: BlockFormat) -> [NoteBlock] {
        var result: [NoteBlock] = []
        var runs: [NoteInline] = []
        var hasStandalone = false

        func flush(always: Bool) {
            guard always || !runs.isEmpty else { return }
            result.append(block(format: format, runs: runs))
            runs = []
        }

        text.enumerateAttributes(in: content) { attributes, range, _ in
            if let attachment = attributes[.attachment] {
                switch (attachment as? NoteTextAttachment)?.content {
                case let chip as ChipAttachment:
                    runs.append(chip.inline)
                case let media as MediaAttachment:
                    if let inline = media.currentInline {
                        runs.append(inline)
                    } else if let block = media.currentBlock {
                        flush(always: false)
                        result.append(block)
                        hasStandalone = true
                    }
                case let quote as QuoteAttachment:
                    flush(always: false)
                    result.append(quote.block)
                    hasStandalone = true
                case let kept as KeptAttachment:
                    if let inline = kept.inline {
                        runs.append(inline)
                    } else if let block = kept.block {
                        flush(always: false)
                        result.append(block)
                        hasStandalone = true
                    }
                default:
                    break
                }
                return
            }
            var string = (text.string as NSString).substring(with: range)
            string = string.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !string.isEmpty else { return }
            let marks = NoteTypesetter.marks(attributes)
            if let link = attributes[.link] {
                let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
                runs.append(NoteInline(type: .link, text: string, marks: marks.isEmpty ? nil : marks, url: url))
            } else {
                runs.append(NoteInline(text: string, marks: marks.isEmpty ? nil : marks))
            }
        }
        flush(always: !hasStandalone)
        return result
    }

    static func block(format: BlockFormat, runs: [NoteInline]) -> NoteBlock {
        let level: Int? = switch format.kind {
        case .heading: format.level
        case .bullet, .numbered, .checklist: format.level > 0 ? format.level : nil
        default: nil
        }
        let built = NoteBlocks.block(
            kind: format.kind, level: level, checked: format.kind == .checklist ? format.checked : nil, runs: runs
        )
        if let origin = format.origin, NoteBlocks.form(origin) == NoteBlocks.form(built) { return origin }
        return built
    }
}
#endif
