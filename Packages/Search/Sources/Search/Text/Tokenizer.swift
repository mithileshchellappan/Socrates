import Foundation

/// One word of a text, cut the way the FTS5 `unicode61` tokenizer cuts it: a run of letters and
/// digits; everything else separates.
struct Token: Sendable {
    /// Where the word sits in the text it was cut from.
    var range: Range<String.Index>
    /// Lower-cased, diacritics removed (`unicode61 remove_diacritics 2`): what the index compares.
    var folded: String
}

enum Tokenizer {
    /// The words of `text`, in order.
    static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index?
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if isWordScalar(scalar) {
                if start == nil { start = index }
            } else if let begin = start {
                tokens.append(Token(range: begin..<index, folded: fold(text[begin..<index])))
                start = nil
            }
            index = scalars.index(after: index)
        }
        if let begin = start {
            tokens.append(Token(range: begin..<text.endIndex, folded: fold(text[begin..<text.endIndex])))
        }
        return tokens
    }

    /// The folded words of `text`.
    static func words(in text: String) -> [String] {
        tokens(in: text).map(\.folded)
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.first.map(isWordScalar) ?? false
    }

    /// Letters, digits and combining marks (so a decomposed "ü" stays one word).
    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x80 {
            return (value >= 0x61 && value <= 0x7A) || (value >= 0x41 && value <= 0x5A) || (value >= 0x30 && value <= 0x39)
        }
        let properties = scalar.properties
        if properties.isAlphabetic || properties.numericType != nil { return true }
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .privateUse: return true
        default: return false
        }
    }

    /// Lower-cased with diacritics removed ("Prüfung" → "prufung"), as the index compares words.
    static func fold(_ text: some StringProtocol) -> String {
        let lower = text.lowercased()
        // Most text is ASCII: skip Foundation's folding for it.
        if lower.utf8.allSatisfy({ $0 < 0x80 }) { return lower }
        return lower.folding(options: .diacriticInsensitive, locale: nil)
    }
}
