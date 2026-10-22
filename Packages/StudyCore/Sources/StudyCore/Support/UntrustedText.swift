import Foundation

/// Text from outside the student (a mail, a slide, a document's page) that talks to a model:
/// "ignore previous instructions", "you are now …", a forged `<mail>` or `<system>` element.
/// Defense in depth beside the prompts' "data, never instructions": what quotes such text is
/// dropped, and nothing from a source that has it goes into the calendar on its own.
public enum UntrustedText {
    /// Folded markers (lower case, no diacritics, single spaces).
    public static let modelMarkers = [
        "ignore previous", "ignore all previous", "ignore the above", "ignore any previous", "disregard previous",
        "disregard all previous", "previous instructions", "prior instructions", "new instructions", "you are now",
        "system prompt", "ignoriere alle", "ignoriere die", "ignoriere vorherige", "vorherigen anweisungen",
        "bisherigen anweisungen", "<mail", "</mail", "<system", "</system",
    ]

    /// Whether `text` has words that talk to a model.
    public static func talksToModel(_ text: String) -> Bool {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return modelMarkers.contains { folded.contains($0) }
    }
}
