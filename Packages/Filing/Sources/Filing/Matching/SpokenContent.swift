import Foundation
import StudyCore

/// What was said in a recording, held against the slides in the library: the TF-IDF cosine of
/// the transcript's words with each deck's words (IDF over the decks), and per course its best
/// deck. Only words that are on some slide count, so small talk and admin talk do not dilute it.
///
/// Measured on three lecture decks (DC 01, DC 02, CL I): DC L2 0.53 for DC 02 against
/// 0.20 for CL I; CL L1 0.48 for CL I against 0.22 for DC 02; the Sensor Networks
/// seminar (no slides in the library) at most 0.33, 1.2× the next course.
struct SpokenContent: Sendable {
    struct DeckWords: Sendable {
        var deckID: Deck.ID
        var courseID: Course.ID
        var counts: [String: Int]
    }

    struct Match: Sendable, Equatable {
        var courseID: Course.ID
        var deckID: Deck.ID
        /// Cosine with the best deck, 0…1.
        var similarity: Double
        /// Best cosine with a deck of another course (0 when no other course has slides).
        var runnerUp: Double

        /// How many times better than the next course.
        var ratio: Double { runnerUp > 0 ? similarity / runnerUp : 3 }

        /// Weight of the `spokenContent` filing signal: 0.75 at the minimum ratio, up to 0.95.
        var weight: Double {
            min(0.95, 0.75 + 0.2 * (min(ratio, 3) - SpokenContent.minimumRatio))
        }
    }

    /// The best course's deck must reach this cosine…
    static let minimumSimilarity = 0.35
    /// …or this when no other course has slides to compare with.
    static let minimumLoneSimilarity = 0.5
    /// …and be this many times the best deck of any other course.
    static let minimumRatio = 1.8
    /// Fewer distinct slide words than this in the transcript: too little to go on.
    static let minimumTerms = 60

    /// Words of four letters or more, lower-cased and accent-folded, without common English and
    /// German function words, with their counts.
    static func words(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for word in TextMatch.normalize(text).split(separator: " ") where word.count >= 4 {
            guard word.allSatisfy(\.isLetter) else { continue }
            let token = String(word)
            if stopwords.contains(token) { continue }
            counts[token, default: 0] += 1
        }
        return counts
    }

    /// The course (and its deck) the transcript clearly belongs to, or nil when it is not clear.
    static func match(transcript: [String: Int], decks: [DeckWords]) -> Match? {
        guard !decks.isEmpty else { return nil }
        var documentFrequency: [String: Int] = [:]
        for deck in decks {
            for word in deck.counts.keys { documentFrequency[word, default: 0] += 1 }
        }
        let total = Double(decks.count)
        func vector(_ counts: [String: Int]) -> [String: Double] {
            var result: [String: Double] = [:]
            for (word, count) in counts {
                guard let frequency = documentFrequency[word], count > 0 else { continue }
                result[word] = (1 + log(Double(count))) * log(1 + total / Double(frequency))
            }
            return result
        }
        let spoken = vector(transcript)
        guard spoken.count >= minimumTerms else { return nil }
        let spokenNorm = norm(spoken)
        guard spokenNorm > 0 else { return nil }

        var bestPerCourse: [Course.ID: (deckID: Deck.ID, similarity: Double)] = [:]
        for deck in decks {
            let slides = vector(deck.counts)
            let slidesNorm = norm(slides)
            guard slidesNorm > 0 else { continue }
            var dot = 0.0
            for (word, weight) in spoken {
                if let other = slides[word] { dot += weight * other }
            }
            let similarity = dot / (spokenNorm * slidesNorm)
            if similarity > (bestPerCourse[deck.courseID]?.similarity ?? -1) {
                bestPerCourse[deck.courseID] = (deck.deckID, similarity)
            }
        }
        let ranked = bestPerCourse.sorted { $0.value.similarity > $1.value.similarity }
        guard let best = ranked.first else { return nil }
        let runnerUp = ranked.dropFirst().first?.value.similarity ?? 0
        let floor = ranked.count > 1 ? minimumSimilarity : minimumLoneSimilarity
        guard best.value.similarity >= floor else { return nil }
        if runnerUp > 0, best.value.similarity / runnerUp < minimumRatio { return nil }
        return Match(courseID: best.key, deckID: best.value.deckID, similarity: best.value.similarity, runnerUp: runnerUp)
    }

    private static func norm(_ vector: [String: Double]) -> Double {
        sqrt(vector.values.reduce(0) { $0 + $1 * $1 })
    }

    /// Function words that carry no topic (English and German, four letters or more).
    static let stopwords: Set<String> = [
        // English
        "this", "that", "with", "from", "have", "were", "what", "when", "which", "there", "their", "they", "them",
        "then", "than", "these", "those", "will", "would", "could", "should", "about", "into", "your", "just",
        "like", "also", "some", "more", "most", "very", "much", "many", "such", "only", "other", "over", "well",
        "because", "being", "been", "here", "where", "while", "each", "make", "made", "does", "doing", "done",
        "okay", "yeah", "right", "know", "think", "going", "want", "need", "really", "thing", "things",
        "people", "actually", "basically", "maybe", "sort", "kind", "mean", "today", "again", "first", "second",
        "still", "same", "both", "every", "even", "ever", "whatever", "something", "someone", "anything",
        "nothing", "always", "never", "often", "already", "able", "after", "before", "under", "above",
        "between", "through", "during", "without", "within", "against", "among", "once", "said", "says",
        "look", "come", "take", "give", "good", "time", "year", "years", "next", "last", "part",
        // German
        "oder", "eine", "einen", "einem", "einer", "eines", "dass", "sind", "wird", "werden", "wurde", "haben",
        "hatte", "nicht", "noch", "auch", "aber", "wenn", "dann", "denn", "doch", "schon", "sehr", "mehr",
        "kann", "konnen", "muss", "mussen", "soll", "sollen", "diese", "dieser", "dieses", "diesem", "diesen",
        "etwas", "immer", "heute", "hier", "dort", "weil", "sich", "nach", "ihre", "ihren", "unser",
        "unsere", "eben", "halt", "genau", "jetzt", "einfach", "gibt", "geht", "machen",
    ]
}
