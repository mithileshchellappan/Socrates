import Foundation

/// Slide text as search shows it: without the footer and page number every page repeats
/// ("Data Centers by Ada Example | Bo Sample 18"), bullets as " · ", one line.
///
/// Otherwise "Example" would match all 88 slides of a deck, and every transcript line would
/// borrow the footer as slide context.
enum SlideText {
    /// Cleans the pages of one deck (index 0 = page 1). A line or trailing word run shared by at
    /// least half the pages (and three or more) is boilerplate.
    static func clean(_ pages: [String]) -> [String] {
        let threshold = max(3, (pages.count + 1) / 2)
        let lines = pages.map { $0.split(whereSeparator: \.isNewline).map(String.init) }

        // Repeated lines (separate footer/header lines in PDFKit text).
        var lineCounts: [String: Int] = [:]
        for page in lines {
            for key in Set(page.map(boilerplateKey)) where !key.isEmpty { lineCounts[key, default: 0] += 1 }
        }
        let repeatedLines = pages.count >= 4 ? Set(lineCounts.filter { $0.value >= threshold }.keys) : []
        var bodies = lines.enumerated().map { index, page in
            page.filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // The page number on its own line ("18"); other numbers ("1966") are content.
                if trimmed == String(index + 1) { return false }
                let key = boilerplateKey(line)
                return !repeatedLines.contains(key) && trimmed.contains(where: { $0.isLetter || $0.isNumber })
            }
            .joined(separator: "\n")
        }

        // A repeated trailing run of words (a footer glued to the body, as in one-line extractions:
        // "… drivers 18 Data Centers by Ada Example | Bo Sample 18"), with the page
        // number on either side of it.
        if pages.count >= 4, let footer = repeatedSuffix(bodies.map(words), threshold: threshold) {
            bodies = bodies.map { body in
                var tokens = words(body)
                dropPageNumber(&tokens)
                if tokens.count > footer.count, tokens.suffix(footer.count).map(Tokenizer.fold) == footer {
                    tokens.removeLast(footer.count)
                    dropPageNumber(&tokens)
                    return rebuild(body, keeping: tokens.count)
                }
                return body
            }
        }
        return bodies.map(flatten)
    }

    /// The text with bullets as " · " and all whitespace collapsed to single spaces.
    static func flatten(_ text: String) -> String {
        var parts: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            var bullet = false
            while let first = line.first, bullets.contains(first),
                  !(first == "§" && line.dropFirst().first { !$0.isWhitespace }?.isNumber == true) {
                bullet = true
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }
            parts.append(bullet && !parts.isEmpty ? "· " + line : line)
        }
        var flat = parts.joined(separator: " ")
        // Bullets inside a line, with or without spaces around them ("pay-as-you-go §Efficiency").
        // "§ 22 Abs. 3" (a German legal paragraph) stays; a § before words is a Wingdings bullet.
        var spaced = ""
        var index = flat.startIndex
        while index < flat.endIndex {
            let character = flat[index]
            let next = flat[flat.index(after: index)...].first { !$0.isWhitespace }
            if inlineBullets.contains(character), !(character == "§" && next?.isNumber == true) {
                spaced += " · "
            } else {
                spaced.append(character)
            }
            index = flat.index(after: index)
        }
        flat = spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while flat.hasPrefix("· ") { flat.removeFirst(2) }
        return flat.replacing("· ·", with: "·")
    }

    private static let bullets: Set<Character> = ["•", "§", "▪", "◦", "–", "-", "*", "·", "\u{F0A7}", "\u{F0B7}", "\u{F0D8}"]
    private static let inlineBullets: Set<Character> = ["§", "•", "▪", "◦", "\u{F0A7}", "\u{F0B7}", "\u{F0D8}"]

    /// Case- and digit-insensitive form of a line or word, so "Page 3" and "Page 4" compare equal.
    private static func boilerplateKey(_ text: String) -> String {
        Tokenizer.fold(text)
            .filter { !$0.isNumber }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func dropPageNumber(_ tokens: inout [String]) {
        if let last = tokens.last, last.allSatisfy(\.isNumber) { tokens.removeLast() }
    }

    /// The longest run of 3–16 trailing words (after the page number) shared by `threshold` pages.
    private static func repeatedSuffix(_ pages: [[String]], threshold: Int) -> [String]? {
        let trimmed = pages.map { page -> [String] in
            var tokens = page
            dropPageNumber(&tokens)
            return tokens.map(Tokenizer.fold)
        }
        for length in stride(from: 16, through: 3, by: -1) {
            var counts: [[String]: Int] = [:]
            for tokens in trimmed where tokens.count > length {
                counts[Array(tokens.suffix(length)), default: 0] += 1
            }
            if let (suffix, count) = counts.max(by: { $0.value < $1.value }), count >= threshold,
               suffix.contains(where: { $0.count > 1 && !$0.allSatisfy(\.isNumber) }) {
                return suffix
            }
        }
        return nil
    }

    /// `text` cut after its first `count` whitespace-separated words, keeping the original spacing.
    private static func rebuild(_ text: String, keeping count: Int) -> String {
        var seen = 0
        var inWord = false
        var end = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if inWord {
                    inWord = false
                    seen += 1
                    if seen == count { return String(text[..<end]) }
                }
            } else {
                inWord = true
                end = text.index(after: index)
            }
            index = text.index(after: index)
        }
        return text
    }
}
