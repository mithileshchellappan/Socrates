import Foundation

/// Case- and accent-insensitive word matching for course names, lecturer surnames and glossary
/// terms in slide text and file names.
enum TextMatch {
    /// Lower-cased, accents folded, everything but letters and digits turned into single spaces.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var result = ""
        result.reserveCapacity(folded.count)
        var lastWasSpace = true
        for character in folded {
            if character.isLetter || character.isNumber {
                result.append(character)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        if result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    /// True when the words of `phrase` appear in `text` in order as whole words.
    static func contains(_ text: String, phrase: String) -> Bool {
        let needle = normalize(phrase)
        guard !needle.isEmpty else { return false }
        return (" " + normalize(text) + " ").contains(" " + needle + " ")
    }

    /// Same as `contains` with `text` already normalized.
    static func containsNormalized(_ normalizedText: String, phrase: String) -> Bool {
        let needle = normalize(phrase)
        guard !needle.isEmpty else { return false }
        return (" " + normalizedText + " ").contains(" " + needle + " ")
    }

    /// The lecturer's surname from "Prof. Dr. Ada Example" → "Example"; titles and initials
    /// are skipped. Nil when nothing name-like is left.
    static func surname(_ name: String) -> String? {
        let titles: Set<String> = ["prof", "dr", "ing", "phd", "pd", "jun", "hon", "rer", "nat", "mr", "mrs", "ms", "msc", "bsc", "dipl", "inf"]
        let words = name.split(whereSeparator: { $0 == " " || $0 == "," })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-")) }
            .filter { !$0.isEmpty && !titles.contains($0.lowercased()) }
        guard let last = words.last, last.count >= 3, last.first?.isLetter == true else { return nil }
        return last
    }

    /// Lower-cased word set for footer similarity.
    static func wordSet(_ text: String) -> Set<String> {
        Set(normalize(text).split(separator: " ").map(String.init).filter { $0.count > 1 && !$0.allSatisfy(\.isNumber) })
    }

    /// Jaccard similarity of two word sets.
    static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}

/// Lines repeated on most slides: the deck footer ("Data Centers by Ada Example | Bo
/// Sample 21" → "Data Centers by Ada Example | Bo Sample"). Page numbers are
/// stripped before lines are compared.
enum Footer {
    /// The repeated lines, most frequent first, in their original spelling.
    static func lines(pages: [String]) -> [String] {
        let usable = pages.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard usable.count >= 3 else { return [] }
        var counts: [String: Int] = [:]
        var spelling: [String: String] = [:]
        for text in usable {
            let lines = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // Footers and headers sit at the ends of the extracted text.
            let ends = Array(lines.prefix(1)) + Array(lines.suffix(2))
            var seen = Set<String>()
            for line in ends {
                let cleaned = stripPageNumber(line)
                let key = TextMatch.normalize(cleaned)
                guard key.filter(\.isLetter).count >= 6, seen.insert(key).inserted else { continue }
                counts[key, default: 0] += 1
                spelling[key] = spelling[key] ?? cleaned
            }
        }
        let threshold = max(2, Int((Double(usable.count) * 0.4).rounded(.up)))
        return counts
            .filter { $0.value >= threshold }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .compactMap { spelling[$0.key] }
    }

    /// "Data Centers by Ada Example | Bo Sample 21" → without the page number;
    /// also "Page 3", "Seite 3 von 40", "3 / 40" at either end.
    static func stripPageNumber(_ line: String) -> String {
        var words = line.split(separator: " ").map(String.init)
        func isNumberish(_ word: String) -> Bool {
            let lower = word.lowercased()
            return word.allSatisfy { $0.isNumber || $0 == "/" } || ["page", "seite", "slide", "folie", "von", "of", "/", "|", "–", "-"].contains(lower)
        }
        while let last = words.last, isNumberish(last) { words.removeLast() }
        while let first = words.first, isNumberish(first), first.contains(where: \.isNumber) || first.count == 1 { words.removeFirst() }
        return words.joined(separator: " ")
    }
}
