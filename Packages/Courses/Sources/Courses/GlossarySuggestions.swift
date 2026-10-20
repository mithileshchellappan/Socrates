import Foundation
import NaturalLanguage
import StudyCore

/// A term the glossary could take, and where it came from (Course Settings ▸ Glossary ▸
/// Suggested).
public struct GlossarySuggestion: Hashable, Sendable, Identifiable {
    public enum Source: Hashable, Sendable {
        /// The student corrected the transcript there; `replaced` is what the transcriber wrote.
        case correction(lectureID: Lecture.ID, lectureNumber: Int?, time: Double, replaced: String)
        /// On a slide a transcribed lecture showed, never in its transcript.
        case slide(lectureID: Lecture.ID?, deckID: Deck.ID, page: Int)
    }

    public var term: String
    public var source: Source

    public init(term: String, source: Source) {
        self.term = term
        self.source = source
    }

    public var id: String { term.lowercased() }
}

/// A word from the course's slides the glossary field completes to, with its first page.
public struct GlossaryCompletion: Hashable, Sendable {
    public var term: String
    public var page: Int

    public init(term: String, page: Int) {
        self.term = term
        self.page = page
    }
}

/// What the glossary can suggest for one course: ranked suggestions and the slide words typing
/// completes to. Glossary edits are applied by the caller (`suggestions(excluding:…)`), so the
/// vocabulary only changes with the course's transcripts and slides.
public struct GlossaryVocabulary: Hashable, Sendable {
    /// Corrections first (newest lecture first, then by time), then slide terms by how long the
    /// lectures stayed on their slides.
    public var suggestions: [GlossarySuggestion]
    /// Terms first (words without a dictionary entry), then the more frequent.
    public var completions: [GlossaryCompletion]

    public init(suggestions: [GlossarySuggestion] = [], completions: [GlossaryCompletion] = []) {
        self.suggestions = suggestions
        self.completions = completions
    }

    public static let empty = GlossaryVocabulary()

    /// The first `limit` suggestions the glossary does not have (also as singular or plural) and
    /// the student has not dismissed (lower-cased terms).
    public func suggestions(excluding glossary: [String], dismissed: Set<String> = [], limit: Int = 3) -> [GlossarySuggestion] {
        let known = GlossarySuggestions.glossaryKeys(glossary)
        var result: [GlossarySuggestion] = []
        for suggestion in suggestions where result.count < limit {
            let key = suggestion.term.lowercased()
            guard !dismissed.contains(key), !GlossarySuggestions.covers(known, key) else { continue }
            result.append(suggestion)
        }
        return result
    }

    /// The slide word `prefix` (two letters or more, case-insensitive) is the start of, unless the
    /// glossary has it already. Nil when nothing longer matches.
    public func completion(for prefix: String, excluding glossary: [String]) -> GlossaryCompletion? {
        let typed = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard typed.count >= 2 else { return nil }
        let known = GlossarySuggestions.glossaryKeys(glossary)
        return completions.first { completion in
            let key = completion.term.lowercased()
            return key.count > typed.count && key.hasPrefix(typed) && !GlossarySuggestions.covers(known, key)
        }
    }
}

/// Finds glossary terms without a model, offline: the student's transcript corrections, and
/// term-like words on slides that the lecture showed but the transcriber never wrote (so it
/// probably misheard them).
///
/// Slide terms are acronyms (QEMU), words with inner capitals (VirtualBox, IaaS, OS-level), and
/// words on two pages or more that have no dictionary entry (virtio, Bitmovin). Left out: title
/// slides, a deck's running header and footer (words on more than a third of its pages), the
/// lecturers' names, stopwords, plural forms of known words, and anything the transcripts
/// contain.
public enum GlossarySuggestions {
    public struct Segment: Hashable, Sendable {
        public var lectureID: Lecture.ID
        public var startTime: Double
        public var text: String
        public var originalText: String
        public var revision: Int

        public init(lectureID: Lecture.ID, startTime: Double, text: String, originalText: String, revision: Int) {
            self.lectureID = lectureID
            self.startTime = startTime
            self.text = text
            self.originalText = originalText
            self.revision = revision
        }
    }

    public struct Page: Hashable, Sendable {
        public var deckID: Deck.ID
        public var pageNumber: Int
        public var text: String

        public init(deckID: Deck.ID, pageNumber: Int, text: String) {
            self.deckID = deckID
            self.pageNumber = pageNumber
            self.text = text
        }
    }

    /// Which pages of which deck a lecture showed; with times for one visit (`LectureDeckSpan`).
    /// Without seconds: the lecture's range of the deck (its coarse span; mr: one deck serves
    /// several lectures, each with its range).
    public struct Span: Hashable, Sendable {
        public var lectureID: Lecture.ID
        public var deckID: Deck.ID
        public var firstPage: Int
        public var lastPage: Int
        public var seconds: Double

        public init(lectureID: Lecture.ID, deckID: Deck.ID, firstPage: Int, lastPage: Int, seconds: Double = 0) {
            self.lectureID = lectureID
            self.deckID = deckID
            self.firstPage = firstPage
            self.lastPage = lastPage
            self.seconds = seconds
        }
    }

    public struct Input: Sendable {
        /// Lecture numbers ("L2"), for correction sources.
        public var lectureNumbers: [Lecture.ID: Int]
        /// The newest lecture first; corrections follow this order.
        public var lectureOrder: [Lecture.ID]
        public var segments: [Segment]
        /// Every page of the course's decks, decks in the order sources should prefer.
        public var pages: [Page]
        public var spans: [Span]
        /// Lecturers' names: never suggested.
        public var names: [String]

        public init(
            lectureNumbers: [Lecture.ID: Int] = [:],
            lectureOrder: [Lecture.ID] = [],
            segments: [Segment] = [],
            pages: [Page] = [],
            spans: [Span] = [],
            names: [String] = []
        ) {
            self.lectureNumbers = lectureNumbers
            self.lectureOrder = lectureOrder
            self.segments = segments
            self.pages = pages
            self.spans = spans
            self.names = names
        }
    }

    /// The course's vocabulary. `knownWords` returns which of the given lower-cased words have a
    /// dictionary entry (default: `Lexicon` in `language`).
    public static func vocabulary(
        _ input: Input,
        language: String = "en",
        knownWords: ((Set<String>) -> Set<String>)? = nil
    ) -> GlossaryVocabulary {
        let candidates = slideCandidates(input, transcript: TranscriptText(input.segments))
        var lookups = Set<String>()
        for candidate in candidates.values where candidate.mayBeSuggested {
            lookups.formUnion(candidate.dictionaryKeys)
        }
        let known = knownWords?(lookups) ?? Lexicon.knownWords(lookups, language: language)

        let corrections = correctionSuggestions(input)
        var seen = Set(corrections.map(\.id))
        var suggestions = corrections
        for candidate in rankedSlideTerms(candidates, known: known) where !seen.contains(candidate.key) {
            seen.insert(candidate.key)
            suggestions.append(GlossarySuggestion(
                term: candidate.term,
                source: .slide(lectureID: candidate.lectureID, deckID: candidate.deckID, page: candidate.firstPage)
            ))
        }
        return GlossaryVocabulary(suggestions: suggestions, completions: completions(candidates))
    }

    // MARK: - Corrections

    /// Words a correction brought in that the transcriber did not write, newest lecture first.
    static func correctionSuggestions(_ input: Input) -> [GlossarySuggestion] {
        let rank = Dictionary(input.lectureOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let corrected = input.segments
            .filter { $0.revision > 0 && $0.text != $0.originalText }
            .sorted { lhs, rhs in
                let left = rank[lhs.lectureID] ?? Int.max
                let right = rank[rhs.lectureID] ?? Int.max
                return left == right ? lhs.startTime < rhs.startTime : left < right
            }
        let excluded = Set(input.names.flatMap(words).map { $0.lowercased() })
        var seen = Set<String>()
        var result: [GlossarySuggestion] = []
        for segment in corrected {
            let before = tokens(in: segment.originalText)
            let beforeKeys = Set(before.map { $0.lowercased() })
            for change in wordDiff(before, tokens(in: segment.text)) where !change.inserted.isEmpty {
                let replaced = change.removed.joined(separator: " ")
                for word in change.inserted {
                    let key = word.lowercased()
                    guard word.filter(\.isLetter).count >= 3, !stopwords.contains(key), !beforeKeys.contains(key),
                          !excluded.contains(key), seen.insert(key).inserted else { continue }
                    result.append(GlossarySuggestion(
                        term: word,
                        source: .correction(
                            lectureID: segment.lectureID, lectureNumber: input.lectureNumbers[segment.lectureID],
                            time: segment.startTime, replaced: replaced
                        )
                    ))
                }
            }
        }
        return result
    }

    /// The changed stretches between two word lists (longest common subsequence, case-insensitive).
    public static func wordDiff(_ old: [String], _ new: [String]) -> [(removed: [String], inserted: [String])] {
        let a = old.map { $0.lowercased() }
        let b = new.map { $0.lowercased() }
        guard !a.isEmpty || !b.isEmpty else { return [] }
        // lengths[i][j]: LCS of a[i...] and b[j...]
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var changes: [(removed: [String], inserted: [String])] = []
        var removed: [String] = []
        var inserted: [String] = []
        func flush() {
            if !removed.isEmpty || !inserted.isEmpty { changes.append((removed, inserted)) }
            removed = []
            inserted = []
        }
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                flush()
                i += 1
                j += 1
            } else if j < b.count, i == a.count || lengths[i][j + 1] >= lengths[i + 1][j] {
                inserted.append(new[j])
                j += 1
            } else {
                removed.append(old[i])
                i += 1
            }
        }
        flush()
        return changes
    }

    // MARK: - Slide terms

    struct Candidate {
        var key: String
        var forms: [String: Int] = [:]
        /// Every page of the course's decks with the word: (deck index, page).
        var pages: Set<PageRef> = []
        /// Pages a transcribed lecture showed (title slides aside).
        var shownPages: Set<PageRef> = []
        /// Seconds the lectures stayed on each shown page.
        var secondsByPage: [PageRef: Double] = [:]
        var seconds: Double { secondsByPage.values.reduce(0, +) }
        /// On more than a third of a deck's pages: a running header or footer.
        var isBoilerplate = false
        /// The transcripts have it: the transcriber knows the word.
        var isTranscribed = false

        /// The spelling the slides use most (lower case on a tie: "Ballooning:" opens a bullet).
        var term: String {
            forms.max { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value }?.key ?? key
        }

        /// Shown by a transcribed lecture, neither header nor footer, never transcribed.
        var mayBeSuggested: Bool { !shownPages.isEmpty && !isBoilerplate && !isTranscribed }

        var shape: Shape { GlossarySuggestions.shape(term) }

        /// The lower-cased words a dictionary decides on: the word, or each part of a compound.
        var dictionaryKeys: [String] {
            switch shape {
            case .acronym, .word: [key]
            case .mixed, .none: []
            }
        }

        var firstShown: PageRef? { shownPages.min() }
        var firstPage: Int { firstShown?.page ?? pages.min()?.page ?? 0 }
        var deckID: Deck.ID { firstShown?.deckID ?? pages.min()?.deckID ?? UUID() }
        var lectureID: Lecture.ID? { firstShown?.lectureID }
    }

    struct PageRef: Hashable, Comparable {
        var deckIndex: Int
        var deckID: Deck.ID
        var page: Int
        var lectureID: Lecture.ID?

        static func < (lhs: PageRef, rhs: PageRef) -> Bool {
            (lhs.deckIndex, lhs.page) < (rhs.deckIndex, rhs.page)
        }

        static func == (lhs: PageRef, rhs: PageRef) -> Bool {
            lhs.deckID == rhs.deckID && lhs.page == rhs.page
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(deckID)
            hasher.combine(page)
        }
    }

    enum Shape {
        /// All capitals, three letters or more: QEMU, AMD-V, QCOW2.
        case acronym
        /// A capital after the first letter of a part: VirtualBox, IaaS, OS-level, inter-VM.
        case mixed
        /// A plain word: virtio, Bitmovin.
        case word
        /// Not a term: short, numbered, or a lower-case compound (pay-as-you-go).
        case none
    }

    static func shape(_ token: String) -> Shape {
        let letters = token.filter(\.isLetter)
        guard letters.count >= 3 else { return .none }
        if letters.allSatisfy(\.isUppercase) { return .acronym }
        if token.contains(where: \.isNumber) { return .none }
        let parts = token.split(separator: "-")
        if parts.contains(where: { $0.dropFirst().contains(where: \.isUppercase) }) { return .mixed }
        return parts.count > 1 ? .none : .word
    }

    /// A lecture and one of its decks.
    struct LectureDeck: Hashable {
        var lectureID: Lecture.ID
        var deckID: Deck.ID
    }

    /// Every word on the course's slides, with the pages it is on and those transcribed lectures
    /// showed.
    static func slideCandidates(_ input: Input, transcript: TranscriptText) -> [String: Candidate] {
        let transcribed = Set(input.segments.map(\.lectureID))
        var deckIndex: [Deck.ID: Int] = [:]
        var pageCount: [Deck.ID: Int] = [:]
        for page in input.pages {
            if deckIndex[page.deckID] == nil { deckIndex[page.deckID] = deckIndex.count }
            pageCount[page.deckID, default: 0] += 1
        }
        // mr: a lecture's range of a deck (a span without seconds); a visit counts only inside it.
        var ranges: [LectureDeck: ClosedRange<Int>] = [:]
        for span in input.spans where span.seconds == 0 && span.firstPage <= span.lastPage {
            ranges[LectureDeck(lectureID: span.lectureID, deckID: span.deckID)] = span.firstPage...span.lastPage
        }
        // Pages the transcribed lectures showed, the lecture that showed them, and for how long.
        var shownBy: [Deck.ID: [Int: Lecture.ID]] = [:]
        var seconds: [Deck.ID: [Int: Double]] = [:]
        for span in input.spans where transcribed.contains(span.lectureID) && span.firstPage <= span.lastPage {
            let range = ranges[LectureDeck(lectureID: span.lectureID, deckID: span.deckID)]
            for page in span.firstPage...span.lastPage {
                if span.seconds > 0, let range, !range.contains(page) { continue }
                if shownBy[span.deckID]?[page] == nil { shownBy[span.deckID, default: [:]][page] = span.lectureID }
                if span.seconds > 0 { seconds[span.deckID, default: [:]][page, default: 0] += span.seconds }
            }
        }

        let excluded = Set(input.names.flatMap(words).map { $0.lowercased() })
        var candidates: [String: Candidate] = [:]
        var pagesPerDeck: [String: [Deck.ID: Int]] = [:]
        for page in input.pages {
            guard let index = deckIndex[page.deckID] else { continue }
            let lecture = shownBy[page.deckID]?[page.pageNumber]
            let shown = lecture != nil && page.pageNumber > 1
            var onPage = Set<String>()
            for token in tokens(in: withoutLinks(page.text)) {
                let key = token.lowercased()
                guard token.filter(\.isLetter).count >= 3, !stopwords.contains(key), !excluded.contains(key) else { continue }
                var candidate = candidates[key] ?? Candidate(key: key)
                candidate.forms[token, default: 0] += 1
                let ref = PageRef(deckIndex: index, deckID: page.deckID, page: page.pageNumber, lectureID: lecture)
                candidate.pages.insert(ref)
                if shown, !candidate.shownPages.contains(ref) {
                    candidate.shownPages.insert(ref)
                    candidate.secondsByPage[ref] = seconds[page.deckID]?[page.pageNumber] ?? 0
                }
                candidates[key] = candidate
                if onPage.insert(key).inserted { pagesPerDeck[key, default: [:]][page.deckID, default: 0] += 1 }
            }
        }
        for key in candidates.keys {
            candidates[key]?.isBoilerplate = pagesPerDeck[key]?.contains { deckID, count in
                count > 2 && Double(count) > Double(pageCount[deckID] ?? 0) / 3
            } ?? false
            candidates[key]?.isTranscribed = transcript.contains(key)
        }
        return candidates
    }

    /// Term-like candidates the lectures showed, by seconds on their slides (then pages, then
    /// reading order). Plurals of other candidates fold into them.
    static func rankedSlideTerms(_ candidates: [String: Candidate], known: Set<String>) -> [Candidate] {
        var terms: [String: Candidate] = [:]
        for (key, candidate) in candidates where candidate.mayBeSuggested {
            switch candidate.shape {
            case .acronym:
                guard !known.contains(key) else { continue }
            case .mixed:
                break
            case .word:
                guard candidate.pages.count >= 2, !known.contains(key) else { continue }
            case .none:
                continue
            }
            terms[key] = candidate
        }
        // "VMMs" → "VMM"; "VMs" (singular too short) goes.
        for key in terms.keys.sorted() {
            guard let singular = singular(of: key), let candidate = terms[key] else { continue }
            if singular.filter(\.isLetter).count < 3 {
                terms[key] = nil
            } else if var stem = terms[singular] {
                stem.pages.formUnion(candidate.pages)
                let added = candidate.shownPages.subtracting(stem.shownPages)
                stem.shownPages.formUnion(added)
                stem.secondsByPage.merge(candidate.secondsByPage) { first, _ in first }
                terms[singular] = stem
                terms[key] = nil
            } else if let stem = candidates[singular], stem.isTranscribed || stem.isBoilerplate {
                terms[key] = nil
            }
        }
        return terms.values.sorted { lhs, rhs in
            if lhs.seconds != rhs.seconds { return lhs.seconds > rhs.seconds }
            if lhs.pages.count != rhs.pages.count { return lhs.pages.count > rhs.pages.count }
            if let left = lhs.firstShown, let right = rhs.firstShown, left != right { return left < right }
            return lhs.key < rhs.key
        }
    }

    /// Every slide word of four letters or more: words the transcriber never wrote first, then
    /// by pages.
    static func completions(_ candidates: [String: Candidate]) -> [GlossaryCompletion] {
        candidates.values
            .filter { $0.key.count >= 4 && $0.shape != .none }
            .map { candidate in (candidate: candidate, isTerm: !candidate.isTranscribed) }
            .sorted { lhs, rhs in
                if lhs.isTerm != rhs.isTerm { return lhs.isTerm }
                if lhs.candidate.pages.count != rhs.candidate.pages.count { return lhs.candidate.pages.count > rhs.candidate.pages.count }
                return lhs.candidate.key < rhs.candidate.key
            }
            .map { GlossaryCompletion(term: $0.candidate.term, page: $0.candidate.firstPage) }
    }

    // MARK: - Text

    /// The transcripts as words (lower-cased) and as one lower-cased text for compounds.
    struct TranscriptText {
        var words: Set<String> = []
        var text = ""

        init(_ segments: [Segment]) {
            var joined: [String] = []
            for segment in segments {
                let tokens = GlossarySuggestions.tokens(in: segment.text).map { $0.lowercased() }
                words.formUnion(tokens)
                for token in tokens where token.contains("-") {
                    words.formUnion(token.split(separator: "-").map(String.init))
                }
                joined.append(tokens.joined(separator: " "))
            }
            text = " " + joined.joined(separator: " ").replacing("-", with: " ") + " "
        }

        /// The word, or a compound's parts in a row ("OS-level" ↔ "os level"), or its joined form.
        func contains(_ key: String) -> Bool {
            if words.contains(key) { return true }
            guard key.contains("-") else { return false }
            return words.contains(key.replacing("-", with: "")) || text.contains(" \(key.replacing("-", with: " ")) ")
        }
    }

    /// Words: a letter, then letters and digits, hyphens inside ("AMD-V", "x86-32" → "x86-32").
    /// Compatibility forms are folded first (NFKC): a formula's mathematical italic "𝑃𝑟𝑒𝑐𝑖𝑠𝑖𝑜𝑛" is
    /// the word "Precision", ligatures ("ﬁ") are letters.
    static func tokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var pendingHyphen = false
        for character in text.precomposedStringWithCompatibilityMapping {
            if character.isLetter || (character.isNumber && !current.isEmpty) {
                if pendingHyphen {
                    current.append("-")
                    pendingHyphen = false
                }
                current.append(character)
            } else if character == "-", !current.isEmpty, !pendingHyphen {
                pendingHyphen = true
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = ""
                pendingHyphen = false
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func words(_ text: String) -> [String] {
        text.precomposedStringWithCompatibilityMapping.split(whereSeparator: { !$0.isLetter && $0 != "-" }).map(String.init)
    }

    /// The text without URLs, mail addresses and host names ("(http://wiki.example.org/)").
    static func withoutLinks(_ text: String) -> String {
        let hosts: Set<String> = ["org", "com", "net", "de", "io", "edu", "gov", "eu", "uk"]
        return text
            .split(whereSeparator: \.isWhitespace)
            .filter { chunk in
                let lowered = chunk.lowercased()
                if lowered.contains("://") || lowered.hasPrefix("www.") || lowered.hasPrefix("(www.") || lowered.contains("@") {
                    return false
                }
                let host = lowered.split(separator: "/").first ?? ""
                guard host.contains(".") else { return true }
                let suffix = host.split(separator: ".").last.map { $0.filter(\.isLetter) } ?? ""
                return !hosts.contains(String(suffix))
            }
            .joined(separator: " ")
    }

    /// "VMMs" → "VMM", "boxes" → "box" (lower-cased); nil when the word is not a plural form.
    static func singular(of key: String) -> String? {
        guard key.count >= 3, key.hasSuffix("s"), !key.hasSuffix("ss") else { return nil }
        return String(key.dropLast())
    }

    /// Glossary entries and their words, lower-cased.
    static func glossaryKeys(_ glossary: [String]) -> Set<String> {
        var keys = Set<String>()
        for term in glossary {
            let lowered = term.lowercased()
            keys.insert(lowered)
            for word in tokens(in: lowered) { keys.insert(word) }
        }
        return keys
    }

    /// The glossary has `key`, its singular or its plural.
    static func covers(_ glossary: Set<String>, _ key: String) -> Bool {
        if glossary.contains(key) || glossary.contains(key + "s") { return true }
        return singular(of: key).map(glossary.contains) ?? false
    }

    /// Function words of English and German slides.
    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "these", "those", "are", "was", "were", "been", "being",
        "have", "has", "had", "not", "but", "can", "could", "should", "would", "will", "may", "might", "must", "shall",
        "into", "onto", "over", "under", "than", "then", "there", "their", "they", "them", "what", "which", "who",
        "whom", "when", "where", "why", "how", "all", "any", "each", "few", "more", "most", "other", "some", "such",
        "only", "own", "same", "too", "very", "just", "also", "about", "after", "before", "between", "through",
        "during", "per", "via", "etc", "its", "our", "your", "you", "she", "his", "her", "him", "one", "two", "use",
        "used", "using", "see", "e.g", "i.e", "der", "die", "das", "und", "oder", "mit", "von", "für", "auf", "aus",
        "bei", "ist", "sind", "ein", "eine", "einer", "eines", "einem", "einen", "nicht", "auch", "wie", "als", "zum",
        "zur", "den", "dem", "des", "im", "am", "es", "sie", "wir", "ihr", "man", "kann", "werden", "wird", "wurde",
        "noch", "nur", "nach", "über", "unter", "vor", "bis", "durch", "gegen", "ohne", "um", "wenn", "dass", "weil",
    ]
}

/// Which words a language's dictionary knows (they have a lemma), through NaturalLanguage: offline,
/// no model download.
public enum Lexicon {
    /// The lower-cased `words` that have a lemma in `language` (BCP 47), English or German (slides
    /// at Exampleton mix them).
    public static func knownWords(_ words: Set<String>, language: String = "en") -> Set<String> {
        var languages: [NLLanguage] = []
        for code in [NLLanguage(rawValue: String(language.prefix(2))), .english, .german]
        where !languages.contains(code) && NLTagger.availableTagSchemes(for: .word, language: code).contains(.lemma) {
            languages.append(code)
        }
        let tagger = NLTagger(tagSchemes: [.lemma])
        var known = Set<String>()
        for word in words where !word.isEmpty {
            tagger.string = word
            for language in languages {
                tagger.setLanguage(language, range: word.startIndex..<word.endIndex)
                let (tag, _) = tagger.tag(at: word.startIndex, unit: .word, scheme: .lemma)
                if tag != nil {
                    known.insert(word)
                    break
                }
            }
        }
        return known
    }
}
