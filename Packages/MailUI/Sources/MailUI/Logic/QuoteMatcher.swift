import Foundation

/// Finds the exact quotes items were read from (`tracked_item_source.quote`, a verified
/// substring of the mail) in the text the reader shows. The shown text can differ from
/// `body_text` in whitespace (HTML paragraphs, line wraps, non-breaking spaces) and typography
/// (curly quotes, dashes), so both sides are compared with whitespace runs collapsed, typographic
/// quotes and dashes folded and case ignored.
enum QuoteMatcher {
    /// Ranges of `text` matching `quote`, in order, not overlapping.
    static func ranges(of quote: String, in text: String) -> [Range<String.Index>] {
        let folded = normalized(text)
        return matches(of: quote, in: folded).map { folded[$0.lowerBound].range.lowerBound..<folded[$0.upperBound - 1].range.upperBound }
    }

    /// Character-offset ranges of `text` matching `quote` (offsets count `Character`s of `text`).
    static func offsetRanges(of quote: String, in folded: [Folded]) -> [Range<Int>] {
        matches(of: quote, in: folded).map { folded[$0.lowerBound].offset..<folded[$0.upperBound - 1].endOffset }
    }

    /// Ranges of indices into `folded` matching `quote`.
    private static func matches(of quote: String, in haystack: [Folded]) -> [Range<Int>] {
        let needle = normalized(quote).map(\.character)
        guard let first = needle.first, haystack.count >= needle.count else { return [] }
        var found: [Range<Int>] = []
        var start = 0
        let last = haystack.count - needle.count
        while start <= last {
            guard haystack[start].character == first else {
                start += 1
                continue
            }
            var offset = 1
            while offset < needle.count, haystack[start + offset].character == needle[offset] {
                offset += 1
            }
            if offset == needle.count {
                found.append(start..<(start + needle.count))
                start += needle.count
            } else {
                start += 1
            }
        }
        return found
    }

    /// One compared character and the span of the original text it stands for (a collapsed
    /// whitespace run is one space).
    struct Folded {
        var character: Character
        var range: Range<String.Index>
        /// `Character` offsets of `range` in the original text.
        var offset: Int
        var endOffset: Int
    }

    /// `text` folded for comparison: leading and trailing whitespace dropped, whitespace runs as
    /// one space, invisible characters (soft hyphen, zero-width space) skipped.
    static func normalized(_ text: String) -> [Folded] {
        var folded: [Folded] = []
        folded.reserveCapacity(text.utf8.count)
        var index = text.startIndex
        var offset = 0
        var pendingSpace: (range: Range<String.Index>, offset: Int, endOffset: Int)?
        while index < text.endIndex {
            let next = text.index(after: index)
            let character = text[index]
            defer {
                index = next
                offset += 1
            }
            if isInvisible(character) { continue }
            if character.isWhitespace {
                if let space = pendingSpace {
                    pendingSpace = (space.range.lowerBound..<next, space.offset, offset + 1)
                } else {
                    pendingSpace = (index..<next, offset, offset + 1)
                }
                continue
            }
            if let space = pendingSpace, !folded.isEmpty {
                folded.append(Folded(character: " ", range: space.range, offset: space.offset, endOffset: space.endOffset))
            }
            pendingSpace = nil
            folded.append(Folded(character: fold(character), range: index..<next, offset: offset, endOffset: offset + 1))
        }
        return folded
    }

    private static func isInvisible(_ character: Character) -> Bool {
        character == "\u{00AD}" || character == "\u{200B}" || character == "\u{200C}" || character == "\u{200D}" || character == "\u{FEFF}"
    }

    private static func fold(_ character: Character) -> Character {
        switch character {
        case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}", "`", "\u{00B4}": return "'"
        case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}", "\u{00AB}", "\u{00BB}": return "\""
        case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}": return "-"
        default:
            if character.isASCII {
                return character.isUppercase ? Character(character.lowercased()) : character
            }
            let lowered = character.lowercased()
            return lowered.count == 1 ? Character(lowered) : character
        }
    }
}
