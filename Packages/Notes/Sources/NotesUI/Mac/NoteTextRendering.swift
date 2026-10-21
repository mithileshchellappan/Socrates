#if os(macOS)
import AppKit
import Notes
import StudyCore
import StudyUI
import SwiftUI

/// ln: a note drawn as Notes draws it, as read-only text another TextKit 2 document embeds: the
/// same paragraphs, styles, chips, images, sketches, slide clips and professor quotes as the
/// editor, nothing editable. The host asks `layoutFragment(for:in:)` from its layout manager's
/// delegate so list items get their markers.
@MainActor
public final class NoteTextRendering {
    private let context: NoteEditorContext
    private let builder: NoteDocumentBuilder

    /// - Parameters:
    ///   - zoom: the content zoom (nl §11) the note is set at.
    ///   - onLink: a chip was clicked; return true when the host handled it (else it navigates).
    public init(
        style: NoteEditorStyle, zoom: CGFloat = 1, services: StudyServices?, lectureID: Lecture.ID?, professor: String?,
        open: OpenDestinationAction, onLink: ((NoteLink) -> Bool)? = nil
    ) {
        let context = NoteEditorContext(metrics: NoteMetrics(style: style, zoom: zoom))
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

    /// A list item's fragment with its marker (bullet, number, box) in `style`, at the zoom its
    /// text was set at; nil for any other paragraph. Called from the host's layout manager delegate.
    public nonisolated static func layoutFragment(
        for textElement: NSTextElement, in manager: NSTextLayoutManager, style: NoteEditorStyle
    ) -> NSTextLayoutFragment? {
        NoteListFragment.make(for: textElement, in: manager, style: style)
    }
}
#endif
