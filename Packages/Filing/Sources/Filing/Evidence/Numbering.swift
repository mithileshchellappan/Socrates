import Foundation

/// Lecture numbers in file names and on slides: "02_Virtualization_Basics…" → 2,
/// "Slides I_ Overview" → 1 (Roman), "2 Virtualization Basics" → 2, "I: Overview" → 1.
enum Numbering {
    /// Numbers above this are versions, years or page counts, not lectures.
    static let maximum = 40

    /// Words that introduce a lecture number ("Lecture 3", "VL_05", "Slides I", "L03").
    static let keywords: Set<String> = [
        "lecture", "lec", "vorlesung", "vl", "slides", "slide", "folien", "foliensatz", "chapter", "chap",
        "kapitel", "session", "sitzung", "week", "woche", "unit", "part", "teil", "lektion", "topic", "l"
    ]

    /// The lecture number in a file name, with the text it came from.
    static func fileNumber(_ fileName: String) -> (number: Int, evidence: String)? {
        let base = (fileName as NSString).deletingPathExtension
        let words = Self.words(base)
        guard let first = words.first else { return nil }
        // A leading number: "02_Virtualization…", "3 - Storage". Not a leading date ("15-10-2026…").
        let leadingDate = words.count >= 3 && words.prefix(3).allSatisfy { Int($0) != nil }
        if let number = Int(first), first.count <= 2, (1...maximum).contains(number), !leadingDate,
           SlideDate.day(in: words.prefix(3).joined(separator: "-")) == nil {
            return (number, first)
        }
        // A keyword then a number: "Lecture 4", "VL_05", "Slides I_ Overview", "L03".
        for (index, word) in words.enumerated() {
            let lower = word.lowercased()
            if keywords.contains(lower), index + 1 < words.count, let number = value(words[index + 1]) {
                return (number, "\(word) \(words[index + 1])")
            }
            // Glued: "L03", "VL5", "Lecture3".
            if let split = word.firstIndex(where: \.isNumber), split != word.startIndex {
                let prefix = word[..<split].lowercased()
                let digits = word[split...]
                if keywords.contains(prefix), digits.allSatisfy(\.isNumber), let number = Int(digits), (1...maximum).contains(number) {
                    return (number, word)
                }
            }
        }
        return nil
    }

    /// A numbered heading: "2 Virtualization Basics" → (2, "Virtualization Basics"),
    /// "I: Introduction" → (1, "Introduction"), "Lecture 3: Storage Systems" → (3, "Storage Systems").
    /// A bare Roman numeral needs a colon or period after it ("I am" is not lecture 1).
    static func numberedTitle(_ line: String) -> (number: Int, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard SlideDate.day(in: trimmed) == nil else { return nil }
        var rest = Substring(trimmed)
        var hadKeyword = false
        if let space = rest.firstIndex(where: { $0 == " " }), keywords.contains(rest[..<space].lowercased()), rest[..<space].count > 1 {
            rest = rest[space...].drop(while: { $0 == " " })
            hadKeyword = true
        }
        let token = rest.prefix { $0.isNumber || "IVX".contains($0) }
        guard !token.isEmpty, let number = value(String(token)) else { return nil }
        var after = rest.dropFirst(token.count)
        let separator = after.first
        let isRoman = token.allSatisfy { "IVX".contains($0) }
        if let separator, ":.)–-".contains(separator) {
            after = after.dropFirst()
        } else if separator != " " || (isRoman && !hadKeyword) {
            return nil
        }
        let title = after.trimmingCharacters(in: .whitespaces)
        let firstWord = title.prefix { !$0.isWhitespace }
        guard firstWord.count >= 3, firstWord.first?.isLetter == true, !SlideDate.isMonthName(String(firstWord)) else { return nil }
        return (number, title)
    }

    /// 1–40 from digits or an upper-case Roman numeral.
    static func value(_ token: String) -> Int? {
        if let number = Int(token) { return (1...maximum).contains(number) ? number : nil }
        guard let number = roman(token) else { return nil }
        return (1...maximum).contains(number) ? number : nil
    }

    /// Upper-case Roman numerals up to XL; nil for anything else (including lower case).
    static func roman(_ token: String) -> Int? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50]
        guard !token.isEmpty, token.count <= 6, token.allSatisfy({ values[$0] != nil }) else { return nil }
        var total = 0
        var previous = 0
        for character in token.reversed() {
            let value = values[character] ?? 0
            total += value < previous ? -value : value
            previous = max(previous, value)
        }
        // Reject non-canonical spellings ("IIII", "VX").
        return canonicalRoman(total) == token ? total : nil
    }

    static func canonicalRoman(_ number: Int) -> String {
        let table: [(Int, String)] = [(40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var rest = number
        var text = ""
        for (value, symbol) in table {
            while rest >= value {
                text += symbol
                rest -= value
            }
        }
        return text
    }

    /// Words of a file name: underscores, dashes, dots and spaces separate.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " || $0 == "." || $0 == "(" || $0 == ")" })
            .map(String.init)
    }
}
