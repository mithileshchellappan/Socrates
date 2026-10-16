/// Maps a transcript word that is on no slide to the single slide word within one edit
/// (insertion, deletion, substitution or adjacent transposition) after the first two letters,
/// e.g. ASR "weizenbau" → slide "weizenbaum", "hyperivsor" → "hypervisor".
///
/// Uses a deletion-neighbourhood index (SymSpell style), so lookups do not scan the vocabulary.
/// Ambiguous words (two or more slide words within one edit) are left alone.
struct FuzzyMatcher: Sendable {
    let minimumLength: Int
    private let index: [String: [String]]

    init(vocabulary: Set<String>, minimumLength: Int) {
        self.minimumLength = minimumLength
        var index: [String: [String]] = [:]
        if minimumLength > 0 {
            for word in vocabulary where word.count >= minimumLength - 1 {
                for key in Self.deletionNeighbourhood(of: word) {
                    index[key, default: []].append(word)
                }
            }
        }
        self.index = index
    }

    func match(_ word: String) -> String? {
        guard minimumLength > 0, word.count >= minimumLength else { return nil }
        var found: Set<String> = []
        for key in Self.deletionNeighbourhood(of: word) {
            for candidate in index[key] ?? [] where candidate != word
                && candidate.prefix(2) == word.prefix(2)
                && Self.isWithinOneEdit(Array(word), Array(candidate)) {
                found.insert(candidate)
            }
        }
        return found.count == 1 ? found.first : nil
    }

    /// The word itself plus every single-character deletion.
    static func deletionNeighbourhood(of word: String) -> Set<String> {
        let characters = Array(word)
        var keys: Set<String> = [word]
        for index in characters.indices {
            var copy = characters
            copy.remove(at: index)
            keys.insert(String(copy))
        }
        return keys
    }

    /// Damerau-Levenshtein distance ≤ 1 (restricted to adjacent transpositions).
    static func isWithinOneEdit(_ a: [Character], _ b: [Character]) -> Bool {
        if a == b { return true }
        if abs(a.count - b.count) > 1 { return false }
        if a.count == b.count {
            var mismatches: [Int] = []
            for index in a.indices where a[index] != b[index] {
                mismatches.append(index)
                if mismatches.count > 2 { return false }
            }
            if mismatches.count == 1 { return true }
            if mismatches.count == 2 {
                let first = mismatches[0]
                let second = mismatches[1]
                return second == first + 1 && a[first] == b[second] && a[second] == b[first]
            }
            return false
        }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        var shortIndex = 0
        var longIndex = 0
        var skipped = false
        while shortIndex < short.count, longIndex < long.count {
            if short[shortIndex] == long[longIndex] {
                shortIndex += 1
                longIndex += 1
            } else {
                if skipped { return false }
                skipped = true
                longIndex += 1
            }
        }
        return true
    }
}
