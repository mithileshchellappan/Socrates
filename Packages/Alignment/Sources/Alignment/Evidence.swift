import Foundation

/// Slide vocabulary, transcript tokens on the time grid, and the TF-IDF similarity of every decoder
/// step's context window to every slide. Built once per lecture; anchors never change it.
struct Evidence: Sendable {
    let stepCount: Int
    let slideCount: Int
    /// Row-major `stepCount × slideCount` cosine similarities.
    let similarity: [Float]
    /// 0…1 per step.
    let evidence: [Float]
    /// The same for each step on its own (no context): noisy, but unbiased at boundaries. Used to place
    /// span boundaries inside the context radius after decoding.
    let stepSimilarity: [Float]
    let stepEvidence: [Float]
    /// Slides with identical term vectors share a group (e.g. two "Content Moderation" image slides).
    let duplicateGroup: [Int]
    /// Deck boilerplate terms that were removed (footers, course name, lecturer).
    let deckStoplist: Set<String>
    /// Transcript terms that were mapped onto slide terms (ASR misspellings, compounds), for diagnostics.
    let repairs: [String: String]

    struct TimedTerm {
        let term: String
        let time: Double
    }

    init(
        slides: [SlideText],
        transcript: [TranscriptLine],
        stepCount: Int,
        glossary: Glossary,
        parameters: AlignmentParameters
    ) {
        let tokenizer = Tokenizer(stemming: parameters.stemming)
        self.stepCount = stepCount
        slideCount = slides.count

        // Slides and the automatic per-deck stoplist.
        var slideTerms = slides.map { tokenizer.terms(in: $0.text) }
        let nonEmptyPages = slideTerms.filter { !$0.isEmpty }.count
        var pageFrequency: [String: Int] = [:]
        for terms in slideTerms {
            for term in Set(terms) { pageFrequency[term, default: 0] += 1 }
        }
        let threshold = max(Double(parameters.deckStoplistMinimumPages), parameters.deckStoplistFraction * Double(nonEmptyPages))
        let stoplist = Set(pageFrequency.filter { Double($0.value) >= threshold }.keys)
        deckStoplist = stoplist
        slideTerms = slideTerms.map { $0.filter { !stoplist.contains($0) } }
        let deckVocabulary = Set(slideTerms.joined())

        // Transcript terms with times.
        // Fuzzy targets are glossary terms only: against the whole slide vocabulary, one-edit matches are
        // mostly real words that ASR got right ("contract" vs. a slide's "contact"); see docs/decisions.md.
        let multipliers = glossary.termMultipliers(tokenizer: tokenizer, boost: parameters.glossaryBoost)
        let matcher = FuzzyMatcher(vocabulary: Set(multipliers.keys), minimumLength: parameters.fuzzyMatchMinimumLength)
        let (timedTerms, repairs) = Self.timedTerms(
            transcript: transcript,
            tokenizer: tokenizer,
            deckVocabulary: deckVocabulary,
            stoplist: stoplist,
            matcher: matcher,
            joinsCompounds: parameters.joinsCompounds,
            matchesCompoundPrefixes: parameters.matchesCompoundPrefixes
        )
        self.repairs = repairs

        // Term ids.
        var ids: [String: Int] = [:]
        func id(_ term: String) -> Int {
            if let existing = ids[term] { return existing }
            let new = ids.count
            ids[term] = new
            return new
        }
        let slideIDs = slideTerms.map { $0.map(id) }
        let timedIDs = timedTerms.map { (id: id($0.term), time: $0.time) }
        let termCount = ids.count

        // IDF over slides plus non-overlapping transcript chunks (as in the prototype).
        var documentFrequency = [Int](repeating: 0, count: termCount)
        var documentCount = 0
        for terms in slideIDs where !terms.isEmpty {
            documentCount += 1
            for term in Set(terms) { documentFrequency[term] += 1 }
        }
        var chunks: [Int: Set<Int>] = [:]
        for timed in timedIDs {
            chunks[Int(timed.time / parameters.idfChunkDuration), default: []].insert(timed.id)
        }
        documentCount += chunks.count
        for chunk in chunks.values {
            for term in chunk { documentFrequency[term] += 1 }
        }
        var idf = [Float](repeating: 0, count: termCount)
        for (term, index) in ids {
            let frequency = max(1, documentFrequency[index])
            idf[index] = Float(log(Double(max(documentCount, 1)) / Double(frequency)) * (multipliers[term] ?? 1))
        }

        // Normalized slide vectors and the inverted index term -> [(slide, weight)]. Terms are visited in id
        // order so float sums (and therefore results) do not depend on dictionary iteration order.
        var postings = [[(slide: Int32, weight: Float)]](repeating: [], count: termCount)
        var groups: [Int] = []
        var groupOf: [[Int]: Int] = [:]
        for (slide, terms) in slideIDs.enumerated() {
            var counts: [Int: Float] = [:]
            for term in terms { counts[term, default: 0] += 1 }
            let ordered = counts.keys.sorted()
            var weights: [(term: Int, weight: Float)] = []
            var norm: Float = 0
            for term in ordered {
                let weight = Self.termFrequencyWeight(counts[term] ?? 0) * idf[term]
                guard weight > 0 else { continue }
                weights.append((term, weight))
                norm += weight * weight
            }
            norm = norm.squareRoot()
            if norm > 0 {
                for entry in weights { postings[entry.term].append((Int32(slide), entry.weight / norm)) }
            }
            // Slides with the same terms (two copies of an image slide) are interchangeable.
            let signature = terms.sorted()
            if weights.isEmpty {
                groups.append(slide + slides.count)
            } else if let group = groupOf[signature] {
                groups.append(group)
            } else {
                groupOf[signature] = slide
                groups.append(slide)
            }
        }
        duplicateGroup = groups

        // Terms per decoder step, as sparse (term, count) lists in id order.
        var binCounts = [[Int: Float]](repeating: [:], count: stepCount)
        for timed in timedIDs {
            let step = min(stepCount - 1, max(0, Int(timed.time / parameters.stepDuration)))
            binCounts[step][timed.id, default: 0] += 1
        }
        let bins = binCounts.map { bin in bin.keys.sorted().map { (term: $0, count: bin[$0] ?? 0) } }

        // Context windows → cosine similarity per slide. Dense accumulators with a touched list keep this
        // linear in the number of tokens.
        func score(radius: Int, fullEvidence: Double) -> (similarity: [Float], evidence: [Float]) {
            var similarity = [Float](repeating: 0, count: stepCount * slides.count)
            var evidence = [Float](repeating: 0, count: stepCount)
            var window = [Float](repeating: 0, count: termCount)
            var touched: [Int] = []
            var scores = [Float](repeating: 0, count: slides.count)
            for step in 0..<stepCount {
                for term in touched { window[term] = 0 }
                touched.removeAll(keepingCapacity: true)
                for offset in -radius...radius {
                    let neighbor = step + offset
                    guard neighbor >= 0, neighbor < stepCount else { continue }
                    let weight = 1 - Float(abs(offset)) / Float(radius + 1)
                    for entry in bins[neighbor] {
                        if window[entry.term] == 0 { touched.append(entry.term) }
                        window[entry.term] += entry.count * weight
                    }
                }
                var tokens: Float = 0
                var norm: Float = 0
                for index in scores.indices { scores[index] = 0 }
                for term in touched {
                    let count = window[term]
                    tokens += count
                    let weight = Self.termFrequencyWeight(count) * idf[term]
                    guard weight > 0 else { continue }
                    norm += weight * weight
                    for posting in postings[term] { scores[Int(posting.slide)] += weight * posting.weight }
                }
                evidence[step] = Float(min(1, Double(tokens) / fullEvidence))
                guard norm > 0 else { continue }
                let inverse = 1 / norm.squareRoot()
                let row = step * slides.count
                for slide in scores.indices { similarity[row + slide] = scores[slide] * inverse }
            }
            return (similarity, evidence)
        }

        let radius = max(0, parameters.contextRadius)
        (similarity, evidence) = score(radius: radius, fullEvidence: parameters.fullEvidenceTokens)
        // Triangular weights sum to radius + 1, so a single step needs proportionally fewer tokens.
        (stepSimilarity, stepEvidence) = score(radius: 0, fullEvidence: parameters.fullEvidenceTokens / Double(radius + 1))
    }

    /// Sublinear term frequency, continuous for fractional (context-weighted) counts.
    static func termFrequencyWeight(_ count: Float) -> Float {
        count >= 1 ? 1 + log(count) : count
    }

    static func timedTerms(
        transcript: [TranscriptLine],
        tokenizer: Tokenizer,
        deckVocabulary: Set<String>,
        stoplist: Set<String>,
        matcher: FuzzyMatcher,
        joinsCompounds: Bool,
        matchesCompoundPrefixes: Bool
    ) -> (terms: [TimedTerm], repairs: [String: String]) {
        var output: [TimedTerm] = []
        var cache: [String: String] = [:]
        var repairs: [String: String] = [:]

        /// Slide word for a transcript term that is on no slide: one edit away, or a compound prefix.
        func map(_ term: String) -> String {
            if deckVocabulary.contains(term) { return term }
            if let cached = cache[term] { return cached }
            var mapped = matcher.match(term)
            if mapped == nil, matchesCompoundPrefixes, term.count >= 9 {
                let characters = Array(term)
                for length in stride(from: characters.count - 3, through: 6, by: -1) {
                    let prefix = String(characters[..<length])
                    if deckVocabulary.contains(prefix) {
                        mapped = prefix
                        break
                    }
                }
            }
            cache[term] = mapped ?? term
            if let mapped { repairs[term] = mapped }
            return mapped ?? term
        }

        // Lectures repeat a few thousand distinct words; stem each once.
        var normalized: [String: String?] = [:]
        func normalize(_ raw: String) -> String? {
            if let known = normalized[raw] { return known }
            let term = tokenizer.normalize(raw)
            normalized[raw] = term
            return term
        }

        func emit(_ raws: [(raw: String, time: Double)]) {
            var index = 0
            while index < raws.count {
                if joinsCompounds, index + 1 < raws.count,
                   raws[index].raw.count >= 3, raws[index + 1].raw.count >= 3,
                   let joined = normalize(raws[index].raw + raws[index + 1].raw),
                   deckVocabulary.contains(joined) {
                    output.append(TimedTerm(term: joined, time: (raws[index].time + raws[index + 1].time) / 2))
                    repairs[raws[index].raw + " " + raws[index + 1].raw] = joined
                    index += 2
                    continue
                }
                if let term = normalize(raws[index].raw), !stoplist.contains(term) {
                    output.append(TimedTerm(term: map(term), time: raws[index].time))
                }
                index += 1
            }
        }

        for line in transcript {
            if line.words.isEmpty {
                let raws = tokenizer.rawTokens(in: line.text)
                guard !raws.isEmpty else { continue }
                let duration = max(0, line.end - line.start)
                let step = duration / Double(raws.count)
                emit(raws.enumerated().map { ($0.element, line.start + (Double($0.offset) + 0.5) * step) })
            } else {
                var raws: [(raw: String, time: Double)] = []
                for word in line.words {
                    let time = (word.start + max(word.start, word.end)) / 2
                    for raw in tokenizer.rawTokens(in: word.text) { raws.append((raw, time)) }
                }
                emit(raws)
            }
        }
        return (output, repairs)
    }
}
