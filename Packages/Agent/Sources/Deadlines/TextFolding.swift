import Foundation

/// Text comparisons the extractors, the router and the deadline memory make: case-insensitive
/// with diacritics folded, typographic punctuation made plain and whitespace runs collapsed.
/// (Moved from MailIntelligence in M3, which keeps `Folding` as a typealias.)
public enum TextFolding {
    /// Lower-cased, diacritics removed ("Prüfung" → "prufung"), "ß" → "ss", typographic quotes,
    /// dashes and spaces made plain, whitespace runs collapsed to one space, trimmed.
    public static func fold(_ text: some StringProtocol) -> String {
        let plain = NormalizedText.plainCharacters(String(text))
        let folded = plain
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .replacing("ß", with: "ss")
        var output = ""
        output.reserveCapacity(folded.utf8.count)
        var pendingSpace = false
        for character in folded {
            if character.isWhitespace {
                pendingSpace = !output.isEmpty
            } else {
                if pendingSpace { output.append(" ") }
                pendingSpace = false
                output.append(character)
            }
        }
        return output
    }

    /// Words as FTS5 `unicode61` cuts them (runs of letters and digits), folded.
    public static func words(_ text: some StringProtocol) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in String(text).unicodeScalars {
            if isWordScalar(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(fold(current))
                current = ""
            }
        }
        if !current.isEmpty { words.append(fold(current)) }
        return words.filter { !$0.isEmpty }
    }

    /// Letters, digits and combining marks.
    public static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x80 {
            return (value >= 0x61 && value <= 0x7A) || (value >= 0x41 && value <= 0x5A) || (value >= 0x30 && value <= 0x39)
        }
        let properties = scalar.properties
        if properties.isAlphabetic || properties.numericType != nil { return true }
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// Content words of a title, for duplicate detection (short function words dropped).
    public static func titleWords(_ text: String) -> Set<String> {
        Set(words(text).filter { $0.count >= 2 && !titleStopwords.contains($0) || $0.allSatisfy(\.isNumber) })
    }

    private static let titleStopwords: Set<String> = [
        "the", "a", "an", "of", "for", "on", "in", "at", "to", "by", "and", "or", "is", "are", "due",
        "der", "die", "das", "des", "dem", "den", "ein", "eine", "zur", "zum", "im", "am", "fur", "und", "oder", "bis", "von",
    ]
}

/// A text with whitespace and typographic punctuation normalized, mapped back to the original:
/// every normalized character knows the range of the original it came from, so a match in the
/// normalized text is cut from the original byte for byte.
public struct NormalizedText: Sendable {
    /// Normalized characters.
    public let characters: [Character]
    /// For each normalized character, the original range it stands for.
    public let sources: [Range<String.Index>]
    public let original: String

    public init(_ text: String) {
        original = text
        var characters: [Character] = []
        var sources: [Range<String.Index>] = []
        characters.reserveCapacity(text.count)
        var index = text.startIndex
        var pendingSpace: Range<String.Index>?
        while index < text.endIndex {
            let next = text.index(after: index)
            let character = text[index]
            if character.isWhitespace {
                if !characters.isEmpty {
                    pendingSpace = pendingSpace.map { $0.lowerBound..<next } ?? (index..<next)
                }
            } else {
                if let space = pendingSpace {
                    characters.append(" ")
                    sources.append(space)
                    pendingSpace = nil
                }
                for plain in Self.plain(character) {
                    characters.append(plain)
                    sources.append(index..<next)
                }
            }
            index = next
        }
        self.characters = characters
        self.sources = sources
    }

    /// The original text of the first occurrence of `needle` (normalized the same way), or nil.
    public func originalSpan(of needle: String) -> Substring? {
        let pattern = NormalizedText(needle).characters
        guard !pattern.isEmpty, pattern.count <= characters.count else { return nil }
        let first = pattern[0]
        var start = 0
        let lastStart = characters.count - pattern.count
        while start <= lastStart {
            if characters[start] == first {
                var offset = 1
                while offset < pattern.count, characters[start + offset] == pattern[offset] { offset += 1 }
                if offset == pattern.count {
                    let lower = sources[start].lowerBound
                    let upper = sources[start + pattern.count - 1].upperBound
                    return original[lower..<upper]
                }
            }
            start += 1
        }
        return nil
    }

    /// `text` with typographic punctuation and spaces made plain (no whitespace collapsing).
    public static func plainCharacters(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        for character in text {
            for plain in plain(character) { output.append(plain) }
        }
        return output
    }

    /// The plain form of one character (curly quotes → straight, dashes → "-", "…" → "...",
    /// non-breaking and thin spaces → " ", soft hyphens dropped).
    public static func plain(_ character: Character) -> [Character] {
        switch character {
        case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}", "\u{00B4}", "`": return ["'"]
        case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}", "\u{00AB}", "\u{00BB}": return ["\""]
        case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}": return ["-"]
        case "\u{2026}": return [".", ".", "."]
        case "\u{00A0}", "\u{2007}", "\u{2009}", "\u{200A}", "\u{202F}": return [" "]
        case "\u{00AD}", "\u{200B}", "\u{FEFF}": return []
        default: return [character]
        }
    }
}
