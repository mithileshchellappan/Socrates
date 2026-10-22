import Deadlines
import Foundation

/// Checks a model's quote against the mail it came from: it must be an exact substring of the
/// subject or the body after whitespace and typographic normalization, 8–300 characters long.
/// The stored quote is the original span, byte for byte (not the model's copy).
enum QuoteVerifier {
    static let lengths = 8...300

    /// The original span the quote stands for, or nil when the mail does not contain it.
    static func verify(_ quote: String, subject: String, body: String) -> String? {
        let candidate = cleaned(quote)
        guard candidate.count >= lengths.lowerBound else { return nil }
        for source in [body, subject] {
            if let span = NormalizedText(source).originalSpan(of: candidate) {
                let text = String(span)
                return lengths.contains(text.count) ? text : nil
            }
        }
        return nil
    }

    /// The model's quote without envelope entities, surrounding quotation marks or ellipses.
    static func cleaned(_ quote: String) -> String {
        var text = MailEnvelope.unescape(quote).trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers: Set<Character> = ["\"", "'", "„", "“", "”", "‚", "‘", "’", "«", "»"]
        while let first = text.first, let last = text.last, text.count >= 2, wrappers.contains(first), wrappers.contains(last) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for ellipsis in ["...", "…"] {
            while text.hasPrefix(ellipsis) { text = String(text.dropFirst(ellipsis.count)).trimmingCharacters(in: .whitespaces) }
            while text.hasSuffix(ellipsis) { text = String(text.dropLast(ellipsis.count)).trimmingCharacters(in: .whitespaces) }
        }
        return text
    }
}

/// Defense in depth against instructions hidden in mail (the system prompt already says mail is
/// data): the paragraphs of a mail that talk to the model ("ignore previous instructions", "you
/// are now …", a forged `<mail>` element). An item quoting such a paragraph is dropped, and
/// nothing from a mail that has one goes into the calendar on its own. AppAgent's slides source
/// reads a deck's pages with the same markers (`talksToModel`).
public enum InjectionGuard {
    static let markers = [
        "ignore previous", "ignore all previous", "ignore the above", "ignore any previous", "disregard previous",
        "disregard all previous", "previous instructions", "prior instructions", "new instructions", "you are now",
        "system prompt", "ignoriere alle", "ignoriere die", "ignoriere vorherige", "vorherigen anweisungen",
        "bisherigen anweisungen", "<mail", "</mail", "<system", "</system",
    ]

    /// Folded paragraphs of the subject and body that contain a marker.
    static func hostileParagraphs(subject: String, body: String) -> [String] {
        ([subject] + body.components(separatedBy: "\n\n"))
            .map { Folding.fold($0) }
            .filter { paragraph in markers.contains { paragraph.contains($0) } }
    }

    /// The quote lies in one of `paragraphs`.
    static func isHostile(_ quote: String, paragraphs: [String]) -> Bool {
        let folded = Folding.fold(quote)
        return paragraphs.contains { $0.contains(folded) }
    }

    /// Whether `text` (a slide's page) has words that talk to a model.
    public static func talksToModel(_ text: String) -> Bool {
        let folded = Folding.fold(text)
        return markers.contains { folded.contains($0) }
    }
}
