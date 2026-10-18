import Foundation
import Notes
import Observation
import StudyCore
import SwiftUI

/// Drives one editor from outside its text: the Notes screen's toolbar (Aa, checklist, image,
/// sketch, Slide, Quote) and the Format menu (`NoteFormatCommands`, through `NoteEditorFocus`).
/// Insertions go at the caret; the selection is kept while a toolbar button or popover is used.
@MainActor
@Observable
public final class NoteEditorController {
    /// The editor's text has keyboard focus.
    public private(set) var isFocused = false
    /// The format of the paragraph at the caret (the Aa menu's check mark).
    public private(set) var paragraphKind: NoteParagraphKind = .body
    /// An editor is attached (a note is open).
    public private(set) var isAttached = false

    #if os(macOS)
    @ObservationIgnored private weak var textView: NoteTextView?
    #endif

    public init() {}

    public func apply(_ kind: NoteParagraphKind) {
        #if os(macOS)
        textView?.apply(kind)
        focus()
        #endif
    }

    public func toggle(_ mark: NoteMark) {
        #if os(macOS)
        textView?.toggle(mark)
        #endif
    }

    /// ⌘K: the system's link panel for the selection.
    public func addLink() {
        #if os(macOS)
        textView?.orderFrontLinkPanel(nil)
        #endif
    }

    /// Image files (picked or dropped on the toolbar button) inline at the caret.
    public func insertImages(at urls: [URL]) {
        #if os(macOS)
        textView?.noteCoordinator?.importImages(urls)
        focus()
        #endif
    }

    /// A new sketch at the caret, ready to draw on.
    public func insertSketch() {
        #if os(macOS)
        textView?.noteCoordinator?.insertSketch()
        focus()
        #endif
    }

    /// A slide clip (`NoteMedia.slideClip`) inline at the caret.
    public func insertSlideClip(_ inline: NoteInline) {
        #if os(macOS)
        guard let textView, let coordinator = textView.noteCoordinator else { return }
        textView.insertInline(MediaAttachment(inline: inline, context: coordinator.context))
        focus()
        #endif
    }

    /// A professor quote (`NoteMedia.quote`) as its own paragraph at the caret.
    public func insertQuote(_ block: NoteBlock) {
        #if os(macOS)
        guard let textView, let coordinator = textView.noteCoordinator else { return }
        textView.insertStandalone(QuoteAttachment(block: block, context: coordinator.context))
        focus()
        #endif
    }

    /// Puts the caret in the editor.
    public func focus() {
        #if os(macOS)
        guard let textView, let window = textView.window else { return }
        if window.firstResponder !== textView { window.makeFirstResponder(textView) }
        #endif
    }

    func selectionChanged(format: NoteParagraphKind) {
        if paragraphKind != format { paragraphKind = format }
    }

    #if os(macOS)
    func attach(_ textView: NoteTextView) {
        self.textView = textView
        isAttached = true
    }

    func detach(_ textView: NoteTextView) {
        guard self.textView === textView else { return }
        self.textView = nil
        isAttached = false
        if isFocused { focusChanged(false, textView: textView) }
    }

    func focusChanged(_ focused: Bool, textView: NoteTextView?) {
        guard textView == nil || self.textView === textView else { return }
        isFocused = focused
        if focused {
            NoteEditorFocus.shared.editor = self
        } else if NoteEditorFocus.shared.editor === self {
            NoteEditorFocus.shared.editor = nil
        }
    }
    #endif
}

/// The note editor that has keyboard focus, for the Format menu.
@MainActor
@Observable
public final class NoteEditorFocus {
    public static let shared = NoteEditorFocus()
    public internal(set) var editor: NoteEditorController?

    private init() {}
}
