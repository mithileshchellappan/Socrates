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
}
