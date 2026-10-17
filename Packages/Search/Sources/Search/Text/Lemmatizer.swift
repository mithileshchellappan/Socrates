import Foundation
import NaturalLanguage

/// Lemmas for the `lemma_text` column and for query terms (NLTagger `.lemma`), German and English.
///
/// Not thread-safe (NLTagger is not): one instance per indexing pass or query. Reusing one tagger
/// across many texts is what keeps a 90-minute transcript under the indexing budget.
final class Lemmatizer {
    private let tagger = NLTagger(tagSchemes: [.lemma])
    private let recognizer = NLLanguageRecognizer()

    init() {
        recognizer.languageConstraints = [.german, .english]
    }

    /// "de" or "en" for `text`, else `fallback`. Short or mixed texts fall back.
    func language(of text: String, fallback: String) -> String {
        recognizer.reset()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        guard let (best, probability) = hypotheses.max(by: { $0.value < $1.value }), probability >= 0.7 else {
            return fallback
        }
        return best.rawValue
    }

    /// One lower-cased lemma per word of `text` (as `Tokenizer` cuts it), space separated, so the
    /// n-th lemma belongs to the n-th word. A word without a lemma stands for itself.
    func lemmaText(of text: String, language: String) -> String {
        let tokens = Tokenizer.tokens(in: text)
        guard !tokens.isEmpty else { return "" }
        let lemmas = tagLemmas(text, language: language)
        var output = ""
        output.reserveCapacity(text.utf8.count)
        for token in tokens {
            if !output.isEmpty { output.append(" ") }
            if let lemma = lemmas[token.range.lowerBound], lemma.range == token.range,
               let word = Self.singleWord(lemma.value) {
                output.append(word)
            } else {
                output.append(text[token.range].lowercased())
            }
        }
        return output
    }

    /// The lemma of one word in `language` ("de"/"en"), lower-cased; nil when NLTagger has none.
    func lemma(ofWord word: String, language: String) -> String? {
        let lemmas = tagLemmas(word, language: language)
        guard let first = lemmas[word.startIndex], first.range == word.startIndex..<word.endIndex else { return nil }
        return Self.singleWord(first.value)
    }

    private struct Tagged {
        var range: Range<String.Index>
        var value: String
    }

    private func tagLemmas(_ text: String, language: String) -> [String.Index: Tagged] {
        tagger.string = text
        let whole = text.startIndex..<text.endIndex
        if let language = Self.nlLanguage(language) {
            tagger.setLanguage(language, range: whole)
        }
        var lemmas: [String.Index: Tagged] = [:]
        tagger.enumerateTags(in: whole, unit: .word, scheme: .lemma, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if let tag { lemmas[range.lowerBound] = Tagged(range: range, value: tag.rawValue) }
            return true
        }
        return lemmas
    }

    private static func nlLanguage(_ code: String) -> NLLanguage? {
        switch code.prefix(2).lowercased() {
        case "de": .german
        case "en": .english
        case "": nil
        default: NLLanguage(rawValue: String(code.prefix(2)).lowercased())
        }
    }

    /// The lemma lower-cased when it is exactly one word (keeps lemma n aligned with word n).
    private static func singleWord(_ lemma: String) -> String? {
        let words = Tokenizer.tokens(in: lemma)
        guard words.count == 1, let word = words.first, word.range == lemma.startIndex..<lemma.endIndex else { return nil }
        return lemma.lowercased()
    }
}
