#if os(macOS)
import AppKit
import Notes
import StudyCore
import StudyUI
import SwiftUI

/// ln: a note drawn as Notes draws it, as read-only text another TextKit 2 document embeds (the
/// lecture notes show the student's notes in place, live): the same paragraphs, styles, chips,
/// images, sketches, slide clips and professor quotes as the editor, nothing editable. The host
/// asks `layoutFragment(for:in:)` from its layout manager's delegate so list items get their
/// markers.
@MainActor
public final class NoteTextRendering {
    private let context: NoteEditorContext
    private let builder: NoteDocumentBuilder

    /// - Parameters:
    ///   - onLink: a chip was clicked; return true when the host handled it (else it navigates).
    public init(
        style: NoteEditorStyle, services: StudyServices?, lectureID: Lecture.ID?, professor: String?,
        open: OpenDestinationAction, onLink: ((NoteLink) -> Bool)? = nil
    ) {
        let context = NoteEditorContext(metrics: NoteMetrics(style: style))
        context.services = services
        context.lectureID = lectureID
        context.professor = professor
        context.open = open
        context.handleLink = onLink
        context.isEditable = false
        self.context = context
        builder = NoteDocumentBuilder(typesetter: NoteTypesetter(metrics: context.metrics), context: context)
    }

    /// The note's paragraphs, separated by newlines (no newline after the last).
    public func text(_ blocks: [NoteBlock]) -> NSAttributedString {
        builder.document(blocks)
    }

    /// A list item's fragment with its marker (bullet, number, box) in `style`; nil for any other
    /// paragraph. Called from the host's layout manager delegate.
    public nonisolated static func layoutFragment(
        for textElement: NSTextElement, in manager: NSTextLayoutManager, style: NoteEditorStyle
    ) -> NSTextLayoutFragment? {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
              let format = paragraph.attributedString.attribute(.noteBlock, at: 0, effectiveRange: nil) as? BlockFormat,
              format.isList
        else { return nil }
        let metrics = NoteMetrics(style: style)
        let marker: NoteListFragment.Marker = switch format.kind {
        case .checklist: .checkbox(checked: format.checked)
        case .numbered: .number(NoteEditorCoordinator.number(of: paragraph, level: format.level, in: manager.textContentManager))
        default: .bullet(level: format.level)
        }
        return NoteListFragment(
            textElement: textElement, range: textElement.elementRange, marker: marker,
            indent: metrics.listIndent * CGFloat(format.level + 1), font: NSFont.systemFont(ofSize: metrics.bodySize)
        )
    }
}
#endif
