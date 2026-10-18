import Foundation
import GRDB
import StudyCore

/// Keyword search over `search_chunk` (FTS5 word index + trigram index).
///
/// - A chunk matches when it contains every decisive term (function words never decide). A term
///   matches by word prefix, by lemma, by trigram substring (long words always; others when the
///   word index has nothing) or, as a last resort, by a near spelling.
/// - A transcript line also counts a term its slide contains (the slide on screen while it was
///   said), as long as it contains one decisive term itself: "paravirtualization drawback" finds
///   a line on its drawback said over the paravirtualization slide.
/// - Ranking: every term > the exact phrase > more terms > Reciprocal Rank Fusion of the bm25
///   lists (word index with `text` weighted above `lemma_text`, trigram, near spellings, each
///   "Also searched" phrasing, and M5's semantic neighbours).
/// - When few chunks match every term, chunks matching some of them follow; then (M5) up to 8
///   chunks only the semantic index found (meaning without the words: a German query over
///   English slides before its plan lands).
public struct SearchEngine: Sendable {
    public let database: any DatabaseReader
    public let planner: (any QueryPlanning)?
    /// M5: on-device semantic neighbours fused with the keyword lists (`SemanticIndex`). Nil:
    /// keyword search only.
    public let semantic: (any SemanticSearching)?

    /// Semantic neighbours asked for per search (the RRF list and the fill after keyword hits).
    static let semanticLimit = 40

    public init(database: any DatabaseReader, planner: (any QueryPlanning)? = nil, semantic: (any SemanticSearching)? = nil) {
        self.database = database
        self.planner = planner
        self.semantic = semantic
    }

    /// Searches `query.text` and `query.alternatives` at once. Never waits for the planner (M5:
    /// the first results show at once): callers fetch alternatives with
    /// `plannedAlternatives(for:)` and search again with them.
    public func search(_ query: SearchQuery) async throws -> SearchResults {
        let started = ContinuousClock.now
        guard !query.isEmpty else { return SearchResults(query: query) }
        if query.scope == .web {
            // The Web segment: the reading that matches itself and the reading on the slides of
            // what the material search finds, as in All's Web group.
            var material = query
            material.scope = .material
            var results = try await search(material)
            results.query = query
            results.groups = results.groups.filter { $0.kind == .web }
            results.duration = ContinuousClock.now - started
            return results
        }
        var texts = [query.text]
        var keys: Set<String> = [QueryPlans.key(for: query.text)]
        var alternatives: [String] = []
        for alternative in query.alternatives where keys.insert(QueryPlans.key(for: alternative)).inserted {
            texts.append(alternative)
            alternatives.append(alternative)
        }

        let lemmatizer = Lemmatizer()
        let plans = texts.map { QueryPlan.make($0, lemmatizer: lemmatizer) }.filter { !$0.terms.isEmpty }
        guard !plans.isEmpty else { return SearchResults(query: query) }

        // The semantic index works on its own actor while the keyword lists are read.
        let searchTexts = texts
        async let neighbours = semanticNeighbours(of: searchTexts, query: query)

        var retrieval = Retrieval(plans: plans, query: query, nearWords: [:])
        var scoring = try await database.read { [retrieval] db in try retrieval.score(db) }
        if !scoring.wantsNearWords.isEmpty {
            let wanted = scoring.wantsNearWords
            // `unsafeRead`: the vocabulary table lives in the connection's temp schema.
            let near = try await database.unsafeRead { db in
                var near: [TermKey: [String]] = [:]
                for key in wanted {
                    near[key] = try Fuzzy.words(near: plans[key.plan].terms[key.term].words[0], in: db)
                }
                return near
            }
            if near.values.contains(where: { !$0.isEmpty }) {
                retrieval = Retrieval(plans: plans, query: query, nearWords: near)
                scoring = try await database.read { [retrieval] db in try retrieval.score(db) }
            }
        }
        let semanticList = await neighbours
        var results = try await database.read { [retrieval, scoring] db in
            try retrieval.finish(db, scoring, semantic: semanticList)
        }
        results.alternatives = alternatives
        results.duration = ContinuousClock.now - started
        return results
    }

    /// The semantic index's chunk ids for the query and its alternatives, nearest first; empty
    /// without an index or on an error (logged).
    private func semanticNeighbours(of texts: [String], query: SearchQuery) async -> [Int64] {
        guard let semantic else { return [] }
        do {
            return try await semantic.nearest(to: texts, query: query, limit: Self.semanticLimit).map(\.chunkID)
        } catch {
            if !(error is CancellationError) {
                Log.search.error("Semantic search failed: \(String(describing: error), privacy: .public)")
            }
            return []
        }
    }

    /// The "Also searched" phrasings of `query`: the cached plan (`search_plan`, read with or
    /// without a planner), else the planner's answer (one Haiku call, cached), else none.
    /// Throws only `CancellationError`.
    public func plannedAlternatives(for query: SearchQuery) async throws -> [String] {
        if let cached = await QueryPlans.cached(query.text, in: database) { return cached }
        guard let planner else { return [] }
        do {
            return try await planner.alternatives(for: query)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            Log.search.error("Query planning failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}

struct TermKey: Hashable, Sendable {
    var plan: Int
    var term: Int
}

/// One search: the keyword lists scored in one read transaction (`score`), then fused with the
/// semantic list and assembled in another (`finish`).
struct Retrieval {
    let plans: [QueryPlan]
    let query: SearchQuery
    let nearWords: [TermKey: [String]]

    /// Ranked list length per index (RRF only looks this far; chunks matching more terms rank
    /// near the top of the word list anyway).
    static let listLimit = 400
    static let fusionConstant = 60.0
    /// Partial matches fill the list up to this many hits when few chunks match every term.
    static let partialFill = 10
    /// Chunks only the semantic index found follow the keyword hits, at most this many.
    static let semanticFill = 8
    /// Further reading on the hits' slides (the Web group), at most this many.
    static let relatedReadingLimit = 5
    /// A long word is also looked up as a substring (German compounds) while it occurs in fewer
    /// chunks than this; a common word gains little from it and the trigram scan is not free.
    static let compoundLookupLimit = 200

    struct Scoring: Sendable {
        var scored: [Int64: Scored]
        var matchers: [TermMatcher]
        /// Terms nothing matched that may try near spellings.
        var wantsNearWords: [TermKey]
    }

    /// What scoring needs of a candidate (the rest is read for the chosen hits only).
    struct Candidate {
        var id: Int64
        var kind: SearchChunkKind
        /// The slide on screen (transcript lines), for slide context.
        var page: PageKey?
    }

    struct Scored {
        var candidate: Candidate
        var all = false
        var phrase = false
        var coverage = 0.0
        var terms = 0
        var fusion = 0.0
    }

    /// A deck page; deck ids stay text here (no UUID parsing in the hot loop).
    struct PageKey: Hashable {
        var deck: String
        var page: Int
    }

    func score(_ db: Database) throws -> Scoring {
        var wants: [TermKey] = []
        var matchers: [TermMatcher] = []
        var scored: [Int64: Scored] = [:]
        var slideMap: [Int64: PageKey]?

        for (planIndex, plan) in plans.enumerated() {
            var own: [Set<Int64>] = []
            var trigramPatterns: [String] = []
            var nearExpressions: [String] = []

            for (termIndex, term) in plan.terms.enumerated() {
                let key = TermKey(plan: planIndex, term: termIndex)
                var rows = try rowIDs(db, table: "search_fts", expression: term.expression)
                var usedTrigram = false
                let lookUpSubstring = switch term.trigram {
                case .never: false
                case .fallback: rows.isEmpty
                case .always: rows.count < Self.compoundLookupLimit
                }
                if lookUpSubstring {
                    let pattern = QueryPlan.Term.phrase([term.raw])
                    let found = try rowIDs(db, table: "search_trigram", expression: pattern)
                    if !found.isEmpty {
                        rows.formUnion(found)
                        usedTrigram = true
                        trigramPatterns.append(pattern)
                    }
                }
                let near = nearWords[key] ?? []
                for word in near {
                    let expression = "text:\(QueryPlan.Term.phrase([word]))"
                    rows.formUnion(try rowIDs(db, table: "search_fts", expression: expression))
                    nearExpressions.append(expression)
                }
                if rows.isEmpty, term.fuzzy, nearWords[key] == nil { wants.append(key) }
                own.append(rows)
                matchers.append(TermMatcher(term: term, usedTrigram: usedTrigram, nearWords: near))
            }

            var lists = [try ranked(db, table: "search_fts", expression: plan.rankingExpression)]
            if !trigramPatterns.isEmpty {
                lists.append(try ranked(db, table: "search_trigram", expression: trigramPatterns.joined(separator: " OR ")))
            }
            if !nearExpressions.isEmpty {
                // Closest spelling first ("Kubernets" before "Kubrnetes" for "Kubernetes"), each by bm25.
                var nearList: [Int64] = []
                var seen = Set<Int64>()
                for expression in nearExpressions {
                    for id in try ranked(db, table: "search_fts", expression: expression) where seen.insert(id).inserted {
                        nearList.append(id)
                    }
                }
                lists.append(nearList)
            }
            let phraseRows = try plan.phraseExpression.map { try rowIDs(db, table: "search_fts", expression: $0) } ?? []

            var fusion: [Int64: Double] = [:]
            for list in lists {
                for (rank, id) in list.enumerated() {
                    fusion[id, default: 0] += 1 / (Self.fusionConstant + Double(rank + 1))
                }
            }
            let decisive = plan.decisive
            var candidates = try self.candidates(db, ids: Set(fusion.keys).subtracting(scored.keys))
            for (id, entry) in scored { candidates[id] = entry.candidate }

            // Slide context: the pages each decisive term occurs on (only when a line needs it).
            var slidePages: [Int: Set<PageKey>] = [:]
            let needsContext = decisive.count >= 2 && candidates.values.contains { candidate in
                candidate.page != nil && !decisive.allSatisfy { own[$0].contains(candidate.id) }
            }
            if needsContext {
                let slides = try slideMap ?? allSlides(db)
                slideMap = slides
                for index in decisive {
                    var pages = Set<PageKey>()
                    for (id, page) in slides where own[index].contains(id) { pages.insert(page) }
                    slidePages[index] = pages
                }
            }

            for (id, score) in fusion {
                guard let candidate = candidates[id] else { continue }
                var ownCount = 0
                var ownDecisive = 0
                var covered = 0
                for index in plan.terms.indices where own[index].contains(id) { ownCount += 1 }
                for index in decisive {
                    if own[index].contains(id) {
                        ownDecisive += 1
                        covered += 1
                    } else if let page = candidate.page, slidePages[index]?.contains(page) == true {
                        covered += 1
                    }
                }
                guard ownDecisive > 0 else { continue }
                var entry = scored[id] ?? Scored(candidate: candidate)
                entry.all = entry.all || covered == decisive.count
                entry.phrase = entry.phrase || phraseRows.contains(id)
                entry.coverage = max(entry.coverage, Double(ownDecisive) / Double(decisive.count))
                entry.terms = max(entry.terms, ownCount)
                entry.fusion += score
                scored[id] = entry
            }
        }

        return Scoring(scored: scored, matchers: matchers, wantsNearWords: wants)
    }

    /// Fuses the semantic list (`semantic`, nearest first) with the keyword scores and assembles
    /// the hits. The semantic list joins the RRF lists, so within a keyword tier (every term,
    /// phrase, more terms) a chunk it also found ranks higher; the tiers stay as they are. Chunks
    /// only the semantic list found follow the keyword hits (at most `semanticFill`).
    func finish(_ db: Database, _ scoring: Scoring, semantic: [Int64]) throws -> SearchResults {
        var scored = scoring.scored
        for (rank, id) in semantic.enumerated() where scored[id] != nil {
            scored[id]?.fusion += 1 / (Self.fusionConstant + Double(rank + 1))
        }
        let ordered = scored.values.sorted(by: Self.ranksBefore)
        let complete = ordered.prefix { $0.all }.prefix(query.limit)
        let partialCount = max(0, min(query.limit, Self.partialFill) - complete.count)
        let partial = ordered.dropFirst(complete.count).prefix(partialCount)
        var chosen = Array(complete) + Array(partial)
        let room = min(Self.semanticFill, query.limit - chosen.count)
        if room > 0, !semantic.isEmpty {
            let taken = Set(chosen.map(\.candidate.id))
            let extra = Array(semantic.lazy.filter { !taken.contains($0) }.prefix(room))
            let candidates = try self.candidates(db, ids: Set(extra).subtracting(scored.keys))
            for id in extra {
                if let entry = scored[id] {
                    chosen.append(entry)
                } else if let candidate = candidates[id] {
                    chosen.append(Scored(candidate: candidate))
                }
            }
        }
        if query.scope.kinds.contains(.furtherReading) {
            chosen += try relatedReadings(db, of: chosen)
        }
        return try assemble(db, chosen: chosen, matchers: scoring.matchers)
    }

    /// Further reading the study pass verified for the slides of the hits (a slide hit's page, a
    /// line's or a note's slide), in the order of those hits, at most `relatedReadingLimit`: the
    /// Web group's papers and manuals for what was found ("Your material first, then the web").
    private func relatedReadings(_ db: Database, of chosen: [Scored]) throws -> [Scored] {
        let ids = chosen.map(\.candidate.id)
        guard !ids.isEmpty else { return [] }
        let taken = Set(ids)
        let position = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let pairs = try Row.fetchAll(db, sql: """
            SELECT r.id AS reading, h.id AS hit FROM search_chunk h
            JOIN search_chunk r ON r.kind = 'further_reading' AND r.deck_id = h.deck_id AND r.page_number = h.page_number
            WHERE h.id IN (SELECT value FROM json_each(?)) AND h.kind IN ('transcript', 'slide', 'note')
            """, arguments: [Self.json(ids)])
        var ordered: [(Int64, Int)] = []
        for row in pairs {
            let reading: Int64 = row["reading"]
            let hit: Int64 = row["hit"]
            ordered.append((reading, position[hit] ?? Int.max))
        }
        var seen = taken
        var related: [Scored] = []
        for (reading, _) in ordered.sorted(by: { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }) where seen.insert(reading).inserted {
            related.append(Scored(candidate: Candidate(id: reading, kind: .furtherReading, page: nil)))
            if related.count == Self.relatedReadingLimit { break }
        }
        return related
    }

    static func ranksBefore(_ a: Scored, _ b: Scored) -> Bool {
        if a.all != b.all { return a.all }
        if a.phrase != b.phrase { return a.phrase }
        if a.coverage != b.coverage { return a.coverage > b.coverage }
        if a.terms != b.terms { return a.terms > b.terms }
        if a.fusion != b.fusion { return a.fusion > b.fusion }
        return a.candidate.id < b.candidate.id
    }

    // MARK: - Queries

    private var kindFilter: String {
        query.scope.kinds.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    }

    private func rowIDs(_ db: Database, table: String, expression: String) throws -> Set<Int64> {
        var ids = Set<Int64>()
        let cursor = try Int64.fetchCursor(db, sql: "SELECT rowid FROM \"\(table)\" WHERE \"\(table)\" MATCH ?", arguments: [expression])
        while let id = try cursor.next() { ids.insert(id) }
        return ids
    }

    /// In-scope rows matching `expression`, best bm25 first (`text` weighted above `lemma_text`).
    private func ranked(_ db: Database, table: String, expression: String) throws -> [Int64] {
        let rank = table == "search_fts" ? "bm25(search_fts, 1.0, 0.4)" : "bm25(\(table))"
        var arguments: StatementArguments = [expression]
        var filter = ""
        if query.scope != .all || query.courseID != nil || query.lectureID != nil {
            filter = "AND rowid IN (SELECT id FROM search_chunk c WHERE c.kind IN (\(kindFilter))"
            if let courseID = query.courseID {
                filter += " AND c.course_id = ?"
                arguments += [courseID.storageText]
            }
            if let lectureID = query.lectureID {
                // A slide belongs to its deck, not a lecture: the lecture's slides are the pages
                // inside its deck spans.
                filter += """
                     AND (c.lecture_id = ? OR (c.kind = 'slide' AND EXISTS (SELECT 1 FROM lecture_deck_span s
                       WHERE s.lecture_id = ? AND s.deck_id = c.deck_id AND s.first_page IS NOT NULL
                         AND c.page_number BETWEEN s.first_page AND coalesce(s.last_page, s.first_page))))
                    """
                arguments += [lectureID.storageText, lectureID.storageText]
            }
            filter += ")"
        }
        arguments += [Self.listLimit]
        return try Int64.fetchAll(db, sql: """
            SELECT rowid FROM "\(table)" WHERE "\(table)" MATCH ? \(filter) ORDER BY \(rank) LIMIT ?
            """, arguments: arguments)
    }

    /// Every slide chunk's page.
    private func allSlides(_ db: Database) throws -> [Int64: PageKey] {
        var slides: [Int64: PageKey] = [:]
        let rows = try Row.fetchCursor(db, sql: """
            SELECT id, deck_id, page_number FROM search_chunk
            WHERE kind = 'slide' AND deck_id IS NOT NULL AND page_number IS NOT NULL
            """)
        while let row = try rows.next() { slides[row[0]] = PageKey(deck: row[1], page: row[2]) }
        return slides
    }

    private func candidates(_ db: Database, ids: Set<Int64>) throws -> [Int64: Candidate] {
        guard !ids.isEmpty else { return [:] }
        var candidates: [Int64: Candidate] = [:]
        let rows = try Row.fetchCursor(db, sql: """
            SELECT id, kind, deck_id, page_number FROM search_chunk WHERE id IN (SELECT value FROM json_each(?))
            """, arguments: [Self.json(ids)])
        while let row = try rows.next() {
            let id: Int64 = row[0]
            let kind = SearchChunkKind(rawValue: row[1])
            var page: PageKey?
            if kind == .transcript, let deck: String = row[2], let number: Int = row[3] { page = PageKey(deck: deck, page: number) }
            candidates[id] = Candidate(id: id, kind: kind, page: page)
        }
        return candidates
    }

    static func json(_ ids: some Collection<Int64>) -> String {
        "[" + ids.map(String.init).joined(separator: ",") + "]"
    }

    // MARK: - Results

    /// A chosen hit's row.
    struct Chunk {
        var id: Int64
        var kind: SearchChunkKind
        var courseID: Course.ID?
        var lectureID: Lecture.ID?
        var deckID: Deck.ID?
        var page: Int?
        var recordingID: Recording.ID?
        var noteID: Note.ID?
        var mailMessageID: MailMessage.ID?
        var start: Double?
        var text: String
        var lemmaText: String
        /// A further-reading chunk's annotation.
        var sourceID: UUID?
    }

    private func uuid(_ value: String?) -> UUID? {
        value.flatMap(UUID.init(uuidString:))
    }

    private func assemble(_ db: Database, chosen: [Scored], matchers: [TermMatcher]) throws -> SearchResults {
        guard !chosen.isEmpty else { return SearchResults(query: query) }
        var chunks: [Int64: Chunk] = [:]
        let rows = try Row.fetchCursor(db, sql: """
            SELECT id, kind, course_id, lecture_id, deck_id, page_number, recording_id, note_id, start_time, text, lemma_text,
                   mail_message_id, source_id
            FROM search_chunk WHERE id IN (SELECT value FROM json_each(?))
            """, arguments: [Self.json(chosen.map(\.candidate.id))])
        while let row = try rows.next() {
            let id: Int64 = row[0]
            chunks[id] = Chunk(
                id: id, kind: SearchChunkKind(rawValue: row[1]), courseID: uuid(row[2]), lectureID: uuid(row[3]),
                deckID: uuid(row[4]), page: row[5], recordingID: uuid(row[6]), noteID: uuid(row[7]),
                mailMessageID: uuid(row[11]), start: row[8], text: row[9], lemmaText: row[10], sourceID: uuid(row[12])
            )
        }

        let courses = Dictionary(try Course.all.fetchAll(db).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let lectures = Dictionary(try Lecture.all.fetchAll(db).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let deckIDs = Set(chunks.values.compactMap { $0.kind == .slide ? $0.deckID : nil })
        let decks = Dictionary(
            try Deck.where { $0.id.in(Array(deckIDs)) }.fetchAll(db).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let spans = try LectureDeckSpan.where { $0.deckID.in(Array(deckIDs)) }.fetchAll(db)
        let noteIDs = chunks.values.compactMap { $0.kind == .note ? $0.noteID : nil }
        var noteTitles: [Note.ID: String] = [:]
        if !noteIDs.isEmpty {
            for note in try Note.where({ $0.id.in(noteIDs) }).fetchAll(db) { noteTitles[note.id] = note.searchTitle }
        }

        let messageIDs = Set(chunks.values.compactMap { $0.kind == .mail ? $0.mailMessageID : nil })
        var messages: [MailMessage.ID: MailMessage] = [:]
        if !messageIDs.isEmpty {
            for message in try MailMessage.where({ $0.id.in(Array(messageIDs)) }).fetchAll(db) { messages[message.id] = message }
        }

        let readingIDs = chunks.values.compactMap { $0.kind == .furtherReading ? $0.sourceID : nil }
        var readings: [Annotation.ID: Annotation] = [:]
        if !readingIDs.isEmpty {
            for annotation in try Annotation.where({ $0.id.in(readingIDs) }).fetchAll(db) where annotation.hiddenAt == nil {
                readings[annotation.id] = annotation
            }
        }

        var hits: [SearchHit] = []
        var mailSeen: Set<MailMessage.ID> = []
        for entry in chosen {
            guard let meta = chunks[entry.candidate.id] else { continue }
            if meta.kind == .mail {
                // One hit per message: its best chunk (`chosen` is best first).
                guard let messageID = meta.mailMessageID, let message = messages[messageID],
                      mailSeen.insert(messageID).inserted else { continue }
                hits.append(SearchHit(
                    id: meta.id, kind: .mail, courseID: meta.courseID ?? message.courseID,
                    snippet: Snippet.make(text: meta.text, lemmaText: meta.lemmaText, matchers: matchers),
                    matchesAllTerms: entry.all, target: .mail(messageID), title: message.subject, mailMessageID: messageID,
                    sender: message.fromName.isEmpty ? message.fromAddress : message.fromName, text: meta.text
                ))
                continue
            }
            var hit = SearchHit(
                id: meta.id, kind: meta.kind, courseID: meta.courseID, lectureID: meta.lectureID, deckID: meta.deckID,
                page: meta.page, recordingID: meta.recordingID, noteID: meta.noteID, time: meta.start,
                snippet: Snippet.make(text: meta.text, lemmaText: meta.lemmaText, matchers: matchers),
                matchesAllTerms: entry.all, target: nil
            )
            hit.text = meta.text
            switch meta.kind {
            case .transcript:
                if let lectureID = meta.lectureID {
                    hit.target = .lecture(lectureID, page: meta.page, time: meta.start, plays: true, recording: meta.recordingID)
                }
            case .slide:
                if let deckID = meta.deckID, let page = meta.page,
                   let visit = Self.firstVisit(deck: deckID, page: page, spans: spans, lectures: lectures) {
                    hit.lectureID = visit.lecture
                    hit.time = visit.time
                    hit.recordingID = visit.recording
                    hit.courseID = hit.courseID ?? lectures[visit.lecture]?.courseID
                    hit.target = .lecture(visit.lecture, page: page, time: visit.time, plays: false, recording: visit.recording)
                } else if let courseID = meta.courseID {
                    hit.target = .course(courseID)
                }
            case .furtherReading:
                // Its title and byline from the annotation (a hidden one is gone); a click opens
                // the page, the target is the slide it was found for.
                guard let annotation = meta.sourceID.flatMap({ readings[$0] }) else { continue }
                hit.title = annotation.body
                hit.byline = annotation.detail.flatMap { $0.isEmpty ? nil : $0 }
                hit.url = annotation.citations.first { $0.kind == .web }?.url
                hit.annotationID = annotation.id
                hit.time = nil
                if let lectureID = meta.lectureID {
                    hit.target = .lecture(lectureID, page: meta.page, time: nil, plays: false)
                } else if let courseID = meta.courseID {
                    hit.target = .course(courseID)
                }
            default:
                hit.title = meta.noteID.flatMap { noteTitles[$0] }
                if let lectureID = meta.lectureID {
                    hit.target = .lecture(lectureID, page: meta.page, time: meta.start, plays: false, recording: meta.recordingID)
                } else if let courseID = meta.courseID {
                    hit.target = .course(courseID)
                }
            }
            hits.append(hit)
        }
        let hitLectures = Set(hits.compactMap(\.lectureID))
        return SearchResults(
            query: query,
            groups: Self.group(hits, courses: courses, lectures: lectures, decks: decks),
            courses: courses,
            lectures: lectures.filter { hitLectures.contains($0.key) },
            decks: decks
        )
    }

    /// The lecture that showed `page` of `deck` first (earliest lecture, then earliest visit) and
    /// when; a lecture whose deck range only covers the page (no timed visit) comes after those.
    static func firstVisit(
        deck: Deck.ID, page: Int, spans: [LectureDeckSpan], lectures: [Lecture.ID: Lecture]
    ) -> (lecture: Lecture.ID, time: Double?, recording: Recording.ID?)? {
        let covering = spans.filter { span in
            guard span.deckID == deck, let first = span.firstPage else { return false }
            return first <= page && page <= (span.lastPage ?? first)
        }
        func order(_ span: LectureDeckSpan) -> (Date, Double) {
            (lectures[span.lectureID]?.heldAt ?? .distantFuture, span.startTime ?? .infinity)
        }
        if let timed = covering.filter({ $0.startTime != nil }).min(by: { order($0) < order($1) }) {
            return (timed.lectureID, timed.startTime, timed.recordingID)
        }
        if let coarse = covering.min(by: { order($0) < order($1) }) {
            return (coarse.lectureID, nil, nil)
        }
        return nil
    }

    /// Courses in order of their best hit, each course's lectures and decks likewise, then the
    /// notes, then the web (M5: verified further reading), then mail (one hit per message).
    static func group(
        _ hits: [SearchHit],
        courses: [Course.ID: Course],
        lectures: [Lecture.ID: Lecture],
        decks: [Deck.ID: Deck]
    ) -> [SearchGroup] {
        var groups: [SearchGroup] = []
        var index: [SearchGroup.Kind: Int] = [:]
        var notes: [SearchHit] = []
        var web: [SearchHit] = []
        var mail: [SearchHit] = []
        for hit in hits {
            let kind: SearchGroup.Kind
            if hit.kind == .note {
                notes.append(hit)
                continue
            } else if hit.kind == .furtherReading {
                web.append(hit)
                continue
            } else if hit.kind == .mail {
                mail.append(hit)
                continue
            } else if let lectureID = hit.lectureID, lectures[lectureID] != nil {
                kind = .lecture(lectureID)
            } else if let deckID = hit.deckID {
                kind = .deck(deckID)
            } else {
                continue
            }
            if let position = index[kind] {
                groups[position].hits.append(hit)
            } else {
                let lecture = hit.lectureID.flatMap { lectures[$0] }
                let deck = hit.deckID.flatMap { decks[$0] }
                let courseID = lecture?.courseID ?? hit.courseID ?? deck?.courseID
                index[kind] = groups.count
                groups.append(SearchGroup(
                    kind: kind, course: courseID.flatMap { courses[$0] }, lecture: lecture,
                    deck: lecture == nil ? deck : nil, hits: [hit]
                ))
            }
        }
        // Keep a course's groups together, in the order its first group appeared.
        var courseOrder: [Course.ID?] = []
        for group in groups where !courseOrder.contains(group.course?.id) { courseOrder.append(group.course?.id) }
        var ordered = courseOrder.flatMap { courseID in groups.filter { $0.course?.id == courseID } }
        if !notes.isEmpty { ordered.append(SearchGroup(kind: .notes, course: nil, lecture: nil, deck: nil, hits: notes)) }
        if !web.isEmpty { ordered.append(SearchGroup(kind: .web, course: nil, lecture: nil, deck: nil, hits: web)) }
        if !mail.isEmpty { ordered.append(SearchGroup(kind: .mail, course: nil, lecture: nil, deck: nil, hits: mail)) }
        return ordered
    }
}
