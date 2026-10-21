/// ⇧↩ and ⌥↩ in the agent panel's composer (DESIGN 6.8): a new line that carries a list on.
///
/// A line that starts (after its indentation) with a number and ". " or ") " continues with the
/// next number, one that starts with "- ", "* " or "• " with the same bullet, both at the line's
/// indentation; the items after it in the same list are numbered on while they followed on from
/// each other. On an item with nothing after its marker the list ends: the marker goes and the
/// line stays, empty. Any other line gets a plain line break.
enum ComposerLines {
    struct Edit: Equatable {
        var text: String
        /// The caret afterwards, in characters from the start.
        var caret: Int
    }

    /// The text after ⇧↩ with `range` selected (an empty range is the caret).
    static func newLine(in text: String, replacing range: Range<String.Index>) -> Edit {
        let lineStart = text[..<range.lowerBound].lastIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[range.upperBound...].firstIndex(where: \.isNewline) ?? text.endIndex
        let head = text[..<range.lowerBound]
        let tail = text[range.upperBound...]
        // The marker has to be before the caret: a break inside or before it is a plain one.
        guard let marker = ListMarker(text[lineStart..<range.lowerBound]) else {
            let inserted = String(head) + "\n"
            return Edit(text: inserted + tail, caret: inserted.count)
        }
        let typed = text[marker.end..<range.lowerBound]
        let rest = text[range.upperBound..<lineEnd]
        if range.isEmpty, typed.allSatisfy(\.isWhitespace), rest.allSatisfy(\.isWhitespace) {
            // An empty item ends the list.
            let kept = String(text[..<lineStart])
            return Edit(text: kept + text[lineEnd...], caret: kept.count)
        }
        let inserted = String(head) + "\n" + marker.next
        // The words after the caret become the new item's, without the space before them.
        let moved = String(tail.drop { $0 == " " || $0 == "\t" })
        let following = marker.number.map { renumber(moved, after: $0 + 1, like: marker) } ?? moved
        return Edit(text: inserted + following, caret: inserted.count)
    }

    /// The lines after the split item's own text: the same list's next items (same indentation and
    /// delimiter) take the numbers after `number` while each was one more than the one before;
    /// lines indented deeper (a nested item, a wrapped line) are passed over; anything else ends it.
    private static func renumber(_ text: String, after number: Int, like marker: ListMarker) -> String {
        guard var lineBreak = text.firstIndex(where: \.isNewline) else { return text }
        var result = String(text[..<lineBreak])
        var expected = number + 1
        while lineBreak < text.endIndex {
            let start = text.index(after: lineBreak)
            let end = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex
            let line = text[start..<end]
            result.append(text[lineBreak])
            if let item = ListMarker(line), let digits = item.digits, item.number == expected - 1,
               item.indent == marker.indent, item.delimiter == marker.delimiter {
                result += line[..<digits.lowerBound]
                result += String(expected)
                result += line[digits.upperBound...]
                expected += 1
            } else if Self.isDeeper(line, than: marker) {
                result += line
            } else {
                result += text[start...]
                return result
            }
            lineBreak = end
        }
        return result
    }

    private static func isDeeper(_ line: Substring, than marker: ListMarker) -> Bool {
        guard let first = line.firstIndex(where: { $0 != " " && $0 != "\t" }) else { return false }
        return line.distance(from: line.startIndex, to: first) > marker.indent.count
    }
}

/// A list item's marker at the start of a line: its indentation, then a number with "." or ")",
/// or a bullet, then at least one space.
struct ListMarker {
    static let bullets: Set<Character> = ["-", "*", "•"]

    var indent: Substring
    /// Nil for a bullet.
    var number: Int?
    /// The number's digits in the line (nil for a bullet).
    var digits: Range<String.Index>?
    /// "." or ")" after a number, else the bullet.
    var delimiter: Character
    /// Where the item's own text starts (after the marker's spaces).
    var end: String.Index

    /// The next item's marker, at the same indentation.
    var next: String {
        if let number { return "\(indent)\(number + 1)\(delimiter) " }
        return "\(indent)\(delimiter) "
    }

    init?(_ line: Substring) {
        var index = line.startIndex
        while index < line.endIndex, Self.isSpace(line[index]) { index = line.index(after: index) }
        indent = line[line.startIndex..<index]
        guard index < line.endIndex else { return nil }
        if Self.bullets.contains(line[index]) {
            number = nil
            digits = nil
            delimiter = line[index]
            index = line.index(after: index)
        } else {
            let first = index
            while index < line.endIndex, line[index].isASCII, line[index].isWholeNumber { index = line.index(after: index) }
            // At most 9 digits: a number, not an ID or a phone number.
            guard index > first, line.distance(from: first, to: index) <= 9, let value = Int(line[first..<index]),
                  index < line.endIndex, line[index] == "." || line[index] == ")"
            else { return nil }
            number = value
            digits = first..<index
            delimiter = line[index]
            index = line.index(after: index)
        }
        guard index < line.endIndex, Self.isSpace(line[index]) else { return nil }
        while index < line.endIndex, Self.isSpace(line[index]) { index = line.index(after: index) }
        end = index
    }

    private static func isSpace(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }
}
