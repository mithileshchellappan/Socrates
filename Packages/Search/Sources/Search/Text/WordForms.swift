import Foundation

/// Light suffix trimming on top of NLTagger lemmas, so one prefix query on `lemma_text` covers a
/// word family: "virtualize" and "virtualization" both become `virtualiz*`, "Verteilung" and
/// "verteilen" `verteil*`. Lemmas already undo inflection; this undoes the common derivations.
enum WordForms {
    /// Shortest stem worth a prefix query: shorter prefixes match too many unrelated words.
    static let minimumStem = 5

    /// The prefix to query `lemma_text` with for a lemma in `language`, or nil to match the lemma
    /// exactly (too short to widen).
    static func stem(of lemma: String, language: String) -> String? {
        let word = Tokenizer.fold(lemma)
        guard word.count >= 4 else { return nil }
        let rules = language.hasPrefix("de") ? germanRules : englishRules
        for (suffix, replacement) in rules where word.hasSuffix(suffix) {
            let stem = String(word.dropLast(suffix.count)) + replacement
            if stem.count >= minimumStem { return stem }
        }
        return word
    }

    // Longest suffix first. English: derivations to a shared stem, then a silent final e.
    private static let englishRules: [(String, String)] = [
        ("ization", "iz"), ("isation", "is"), ("ation", "at"), ("ness", ""), ("ment", ""), ("ize", "iz"), ("ise", "is"), ("ate", "at"), ("e", ""),
    ]

    // German: nominalisations and infinitives to the verb stem.
    private static let germanRules: [(String, String)] = [
        ("ierung", "ier"), ("ungen", ""), ("ung", ""), ("ieren", "ier"), ("en", ""), ("e", ""),
    ]
}

/// Function words that never decide whether a chunk matches (they still rank).
enum Stopwords {
    static func contains(_ folded: String) -> Bool { words.contains(folded) }

    private static let words: Set<String> = [
        // English
        "a", "about", "above", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at",
        "be", "because", "been", "before", "being", "between", "both", "but", "by", "can", "could", "did",
        "do", "does", "doing", "down", "during", "each", "few", "for", "from", "further", "had", "has", "have",
        "having", "he", "her", "here", "hers", "him", "his", "how", "i", "if", "in", "into", "is", "it", "its",
        "just", "me", "more", "most", "my", "no", "nor", "not", "now", "of", "off", "on", "once", "only", "or",
        "other", "our", "out", "over", "own", "same", "she", "should", "so", "some", "such", "than", "that",
        "the", "their", "them", "then", "there", "these", "they", "this", "those", "through", "to", "too",
        "under", "until", "up", "very", "was", "we", "were", "what", "when", "where", "which", "while", "who",
        "whom", "why", "will", "with", "would", "you", "your",
        // German (folded: umlauts without dots)
        "aber", "als", "am", "an", "auch", "auf", "aus", "bei", "bin", "bis", "bist", "da", "damit", "dann",
        "das", "dass", "dem", "den", "denn", "der", "des", "die", "dies", "diese", "dieser", "dieses", "doch",
        "du", "durch", "ein", "eine", "einem", "einen", "einer", "eines", "er", "es", "fur", "hat", "hatte",
        "ich", "ihr", "im", "ist", "ja", "jetzt", "kann", "mit", "nach", "nicht", "noch", "nur", "ob", "oder",
        "ohne", "schon", "sehr", "sein", "sich", "sie", "sind", "so", "uber", "um", "und", "uns", "unter",
        "vom", "von", "vor", "war", "waren", "was", "wenn", "wer", "wie", "wir", "wird", "wo", "zu", "zum", "zur",
    ]
}
