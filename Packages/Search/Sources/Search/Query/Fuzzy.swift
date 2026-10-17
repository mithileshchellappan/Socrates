import Foundation
import GRDB

/// Near spellings for a word nothing else matched: ASR misspellings and slide typos ("Kubernetes" →
/// "Kubernets"). Looks through the index vocabulary (an `fts5vocab` table in the connection's
/// `temp` schema, so the library schema is untouched) for words one edit away (two for words of
/// eight letters or more).
enum Fuzzy {
    /// At most this many near words per term.
    static let maximumWords = 5

    /// Needs a connection that may create `temp` objects (`unsafeRead`).
    static func words(near term: String, in db: Database) throws -> [String] {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS temp.search_vocabulary USING fts5vocab(main, search_fts, col)
            """)
        let target = Array(term)
        let maximumEdits = target.count >= 8 ? 2 : 1
        var found: [(word: String, distance: Int, documents: Int)] = []
        // An edit before the second letter keeps the first or the second letter in place.
        var initials: [Character] = []
        for initial in target.prefix(2) where !initials.contains(initial) { initials.append(initial) }
        for initial in initials {
            guard let scalar = initial.unicodeScalars.first,
                  let next = Unicode.Scalar(scalar.value + 1)
            else { continue }
            let rows = try Row.fetchCursor(db, sql: """
                SELECT term, doc FROM temp.search_vocabulary WHERE col = 'text' AND term >= ? AND term < ?
                """, arguments: [String(initial), String(Character(next))])
            while let row = try rows.next() {
                let word: String = row["term"]
                guard word != term, abs(word.count - target.count) <= maximumEdits,
                      let distance = distance(target, Array(word), limit: maximumEdits)
                else { continue }
                found.append((word, distance, row["doc"]))
            }
        }
        // Closest first: fewest edits relative to length ("kubernetess" 1/11 before "kubrnetes" 1/10), then
        // the more common word.
        func similarity(_ candidate: (word: String, distance: Int, documents: Int)) -> Double {
            1 - Double(candidate.distance) / Double(max(candidate.word.count, target.count))
        }
        var unique: [String] = []
        let ordered = found.sorted { a, b in
            let (left, right) = (similarity(a), similarity(b))
            if left != right { return left > right }
            if a.documents != b.documents { return a.documents > b.documents }
            return a.word < b.word
        }
        for candidate in ordered where !unique.contains(candidate.word) {
            unique.append(candidate.word)
            if unique.count == maximumWords { break }
        }
        return unique
    }

    /// Optimal-string-alignment distance (insertions, deletions, substitutions, adjacent swaps),
    /// or nil when it exceeds `limit`.
    static func distance(_ a: [Character], _ b: [Character], limit: Int) -> Int? {
        if a == b { return 0 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) <= limit ? max(a.count, b.count) : nil }
        var previousPrevious = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previousPrevious[j - 2] + 1)
                }
                current[j] = value
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit { return nil }
            (previousPrevious, previous, current) = (previous, current, previousPrevious)
        }
        return previous[b.count] <= limit ? previous[b.count] : nil
    }
}
