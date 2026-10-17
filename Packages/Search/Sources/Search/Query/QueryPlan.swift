import Foundation

/// A query split into terms, each with the FTS5 expressions that find it.
///
/// Per word: `text:"word"*` (prefix, so results arrive while typing) OR `lemma_text:"stem"*` for
/// its German and English lemmas. Words are ANDed by the engine; a "quoted phrase" matches exactly;
/// a hyphenated word ("hardware-assisted") is a phrase of its parts.
struct QueryPlan: Sendable {
    struct LemmaForm: Hashable, Sendable {
        var word: String
        var prefix: Bool
    }

    enum TrigramUse: Sendable {
        case never
        /// Only when the word index finds nothing for the term.
        case fallback
        /// Always (long words: German compounds such as "Lastverteilung" for "verteilung").
        case always
    }

    struct Term: Sendable {
        /// Folded words (lower case, no diacritics).
        var words: [String]
        /// As typed, lower-cased, words joined by single spaces: the trigram pattern.
        var raw: String
        var quoted: Bool
        /// A function word: never decides whether a chunk matches.
        var stopword: Bool
        /// Lemma alternatives for a single word; one lemma per word for a phrase.
        var lemmas: [LemmaForm]
        var trigram: TrigramUse
        /// May fall back to near spellings ("Kubernetes" → "Kubernets") when nothing else matches.
        var fuzzy: Bool

        var isPhrase: Bool { words.count > 1 }

        /// The FTS5 expression for chunks containing this term.
        var expression: String {
            if quoted { return "text:\(Self.phrase(words))" }
            var options = ["text:\(Self.phrase(words))*"]
            if isPhrase {
                if lemmas.count == words.count, lemmas.map(\.word) != words {
                    options.append("lemma_text:\(Self.phrase(lemmas.map(\.word)))")
                }
            } else {
                for lemma in lemmas {
                    options.append("lemma_text:\(Self.phrase([lemma.word]))\(lemma.prefix ? "*" : "")")
                }
            }
            return options.count == 1 ? options[0] : "(" + options.joined(separator: " OR ") + ")"
        }

        /// Extra rank for the exact word (over words that merely start with it).
        var bonusExpression: String? {
            quoted ? nil : "text:\(Self.phrase(words))"
        }

        static func phrase(_ words: [String]) -> String {
            "\"" + words.map { $0.replacing("\"", with: "\"\"") }.joined(separator: " ") + "\""
        }
    }

    var text: String
    var terms: [Term]

    /// Indices of the terms that decide a match: all but function words (all, if that is all
    /// there is).
    var decisive: [Int] {
        let content = terms.indices.filter { !terms[$0].stopword }
        return content.isEmpty ? Array(terms.indices) : content
    }

    /// All query words adjacent and in order, for multi-word queries: ranks the exact phrase
    /// above the same words scattered.
    var phraseExpression: String? {
        guard terms.count >= 2 else { return nil }
        let words = terms.flatMap(\.words)
        return "text:\(Term.phrase(words))*"
    }

    /// The expression matching any term (plus exact-word bonuses), for ranking.
    var rankingExpression: String {
        var parts = terms.map(\.expression)
        parts += terms.compactMap(\.bonusExpression)
        if let phraseExpression { parts.append(phraseExpression) }
        return parts.joined(separator: " OR ")
    }

    // MARK: - Parsing

    static func make(_ text: String, lemmatizer: Lemmatizer) -> QueryPlan {
        var terms: [Term] = []
        var seen = Set<[String]>()
        for (piece, quoted) in pieces(of: text) {
            let tokens = Tokenizer.tokens(in: piece)
            guard !tokens.isEmpty else { continue }
            let words = tokens.map(\.folded)
            guard seen.insert(words).inserted else { continue }
            let raw = tokens.map { piece[$0.range].lowercased() }.joined(separator: " ")
            let single = words.count == 1 && !quoted
            let stopword = single && Stopwords.contains(words[0])
            let lemmas: [LemmaForm]
            if quoted {
                lemmas = []
            } else if single {
                lemmas = wordLemmas(String(piece[tokens[0].range]), folded: words[0], lemmatizer: lemmatizer)
            } else {
                lemmas = tokens.map { token in
                    let word = String(piece[token.range])
                    let lemma = lemmatizer.lemma(ofWord: word, language: "en") ?? lemmatizer.lemma(ofWord: word, language: "de")
                    return LemmaForm(word: Tokenizer.fold(lemma ?? word), prefix: false)
                }
            }
            let length = raw.count
            let trigram: TrigramUse = stopword || length < 3 ? .never : (single && length >= 6 ? .always : .fallback)
            terms.append(Term(
                words: words, raw: raw, quoted: quoted, stopword: stopword, lemmas: lemmas, trigram: trigram,
                fuzzy: single && !stopword && length >= 4 && words[0].allSatisfy(\.isLetter)
            ))
        }
        return QueryPlan(text: text, terms: terms)
    }

    /// Lemma forms of one typed word: its German and English lemmas, widened to a stem where that
    /// is safe ("virtualized" → `virtualiz*`, which also finds "virtualization").
    static func wordLemmas(_ word: String, folded: String, lemmatizer: Lemmatizer) -> [LemmaForm] {
        var forms: [LemmaForm] = []
        for language in ["en", "de"] {
            guard let lemma = lemmatizer.lemma(ofWord: word, language: language) else { continue }
            if let stem = WordForms.stem(of: lemma, language: language) {
                forms.append(LemmaForm(word: stem, prefix: true))
            } else {
                forms.append(LemmaForm(word: Tokenizer.fold(lemma), prefix: false))
            }
        }
        if forms.isEmpty {
            // No lemma (a term NLTagger does not know): drop an English plural and widen.
            var base = folded
            if base.count >= 5, base.hasSuffix("s"), !base.hasSuffix("ss") { base.removeLast() }
            if let stem = WordForms.stem(of: base, language: "en"), stem != folded {
                forms.append(LemmaForm(word: stem, prefix: true))
            }
        }
        var unique: [LemmaForm] = []
        for form in forms where !unique.contains(form) && !(form.prefix && form.word == folded) {
            unique.append(form)
        }
        return unique
    }

    /// Whitespace-separated pieces and "quoted phrases" (an unclosed quote runs to the end).
    static func pieces(of text: String) -> [(String, Bool)] {
        var pieces: [(String, Bool)] = []
        var current = ""
        var quoted = false
        func flush() {
            let piece = current.trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { pieces.append((piece, quoted)) }
            current = ""
        }
        for character in text {
            if character == "\"" || character == "“" || character == "”" || character == "„" {
                flush()
                quoted.toggle()
            } else if character.isWhitespace, !quoted {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return pieces
    }
}
