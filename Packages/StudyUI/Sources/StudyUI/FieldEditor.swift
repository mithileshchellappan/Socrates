#if os(macOS)
import AppKit
#endif

/// The text field the student is typing in, as AppKit sees it.
///
/// A field's text is never changed, and its keys are never taken, while its field editor holds
/// marked text (a dead key such as ´ or ^, ⌥u, an input method, the emoji picker): the input
/// method's marked range then points into text that is gone (an `NSRangeException` in the text
/// input system). Code that empties or rewrites a focused field does it after AppKit has finished
/// the key event (`Task { @MainActor in … }`), never inside it.
@MainActor
public enum FieldEditor {
    /// The key window's field editor or text view is composing: its marked range is live.
    public static var isComposing: Bool {
        #if os(macOS)
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return textView.hasMarkedText()
        #else
        return false
        #endif
    }

    #if os(macOS)
    /// The key window's field editor while it holds exactly `text` (the same UTF-16, so a range of
    /// one is a range of the other) and composes nothing.
    private static func editor(holding text: String) -> NSTextView? {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView, !textView.hasMarkedText(),
              textView.string.utf16.elementsEqual(text.utf16) else { return nil }
        return textView
    }

    /// The caret or selection of the field editor holding `text`, as a range of `text`.
    public static func selection(in text: String) -> Range<String.Index>? {
        guard let textView = editor(holding: text) else { return nil }
        return Range(textView.selectedRange(), in: text)
    }

    /// Puts the caret of the field editor holding `text` at `index`, once (a field that keeps a
    /// caret of its own in SwiftUI state would have it put back on a later update). False until a
    /// field editor holds `text`.
    @discardableResult
    public static func placeCaret(at index: String.Index, in text: String) -> Bool {
        guard let textView = editor(holding: text) else { return false }
        textView.setSelectedRange(NSRange(index..<index, in: text))
        return true
    }
    #endif
}
