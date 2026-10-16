import Foundation

/// Tells German from English text by counting unambiguous function words.
///
/// Used to spot chunks that Whisper translated (German speech decoded with the English token comes
/// out as English text) and in the evaluation. Words common to both languages ("in", "was",
/// "also", "will", "man", "so", "an", "um") are not counted.
public enum TextLanguage {
    public struct Score: Hashable, Sendable {
        public var german: Int
        public var english: Int
        public var words: Int
    }

    static let german = Set<String>([
        "der", "die", "das", "den", "dem", "des", "und", "ist", "nicht", "ich", "sie", "wir", "es",
        "ein", "eine", "einen", "einem", "einer", "zu", "mit", "auf", "für", "von", "im", "sich",
        "auch", "dass", "daß", "wenn", "aber", "oder", "wie", "noch", "nur", "schon", "hier", "jetzt",
        "dann", "ja", "nein", "haben", "hat", "habe", "sind", "wird", "werden", "kann", "können",
        "muss", "müssen", "gibt", "bei", "aus", "über", "mal", "doch", "einfach", "eben", "genau",
        "ihr", "ihre", "unser", "diese", "dieser", "dieses", "heute", "keine", "kein", "sehr",
        "gut", "alle", "weil", "denn", "wir", "uns", "euch", "mich", "mir", "dir", "dich", "zum",
        "zur", "vom", "beim", "bis", "nach", "durch", "gegen", "ohne", "sein", "war", "waren",
        "wäre", "würde", "hätte", "sollen", "soll", "wollen", "möchte", "okay", "nämlich", "eigentlich",
        "vielleicht", "natürlich", "also", "dazu", "davon", "darauf", "dabei", "damit", "wo", "wer",
        "warum", "welche", "welcher", "welches", "etwas", "nichts", "viel", "viele", "mehr", "immer",
        "wieder", "gerade", "bitte", "danke", "ihnen", "jemand", "erst", "zwei", "drei", "diesem",
    ])

    static let english = Set<String>([
        "the", "and", "is", "are", "were", "to", "of", "that", "this", "it", "you", "we", "they",
        "he", "she", "have", "has", "had", "be", "been", "not", "with", "for", "on", "at", "as", "by",
        "from", "or", "but", "if", "what", "which", "there", "their", "about", "can", "would",
        "should", "do", "does", "did", "just", "like", "yeah", "right", "now", "here", "then",
        "because", "a", "these", "those", "your", "our", "them", "its", "it's", "that's", "there's",
        "we're", "you're", "they're", "don't", "doesn't", "can't", "isn't", "very", "well", "when",
        "where", "who", "why", "how", "all", "some", "any", "more", "other", "into", "than", "also",
        "only", "one", "two", "three", "after", "before", "over", "under", "between", "same",
        "thing", "things", "something", "nothing", "really", "actually", "basically", "maybe",
        "let's", "i'm", "i", "me", "my", "him", "her", "his", "could", "will", "going", "get", "got",
    ])

    /// Words removed from both lists because they are frequent in both languages.
    static let ambiguous: Set<String> = ["in", "an", "so", "was", "also", "will", "man", "um", "okay"]

    public static func score(_ text: String) -> Score {
        var score = Score(german: 0, english: 0, words: 0)
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            let word = String(raw).lowercased().trimmingCharacters(in: .punctuationCharacters.subtracting(["'"]).union(.symbols))
            guard !word.isEmpty else { continue }
            score.words += 1
            guard !ambiguous.contains(word) else { continue }
            if german.contains(word) { score.german += 1 }
            if english.contains(word) { score.english += 1 }
        }
        return score
    }

    /// "de", "en", or nil when the text is too short or mixed.
    public static func guess(_ text: String, minimumHits: Int = 4) -> String? {
        let score = score(text)
        guard score.german + score.english >= minimumHits else { return nil }
        if score.german >= 2 * score.english, score.german >= 3 { return "de" }
        if score.english >= 2 * score.german, score.english >= 3 { return "en" }
        return nil
    }
}
