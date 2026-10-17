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
///   lists (word index with `text` weighted above `lemma_text`, trigram, near spellings, and each
///   "Also searched" phrasing).
/// - When few chunks match every term, chunks matching some of them follow.
public struct SearchEngine: Sendable {
    public let database: any DatabaseReader
    public let planner: (any QueryPlanning)?

    public init(database: any DatabaseReader, planner: (any QueryPlanning)? = nil) {
        self.database = database
        self.planner = planner
    }

    public func search(_ query: SearchQuery) async throws -> SearchResults {
        let started = ContinuousClock.now
        guard !query.isEmpty else { return SearchResults(query: query) }
        var texts = [query.text]
        var alternatives = query.alternatives
        if alternatives.isEmpty, let planner {
            do {
                alternatives = try await planner.alternatives(for: query)
            } catch {
                Log.search.error("Query planning failed: \(String(describing: error), privacy: .public)")
            }
        }
        for alternative in alternatives where !texts.contains(alternative) { texts.append(alternative) }

        let lemmatizer = Lemmatizer()
        let plans = texts.map { QueryPlan.make($0, lemmatizer: lemmatizer) }.filter { !$0.terms.isEmpty }
        guard !plans.isEmpty else { return SearchResults(query: query) }

        var outcome = try await database.read { db in
            try Retrieval(plans: plans, query: query, nearWords: [:]).run(db)
        }
        if !outcome.wantsNearWords.isEmpty {
            let wanted = outcome.wantsNearWords
            // `unsafeRead`: the vocabulary table lives in the connection's temp schema.
            let near = try await database.unsafeRead { db in
                var near: [TermKey: [String]] = [:]
                for key in wanted {
                    near[key] = try Fuzzy.words(near: plans[key.plan].terms[key.term].words[0], in: db)
                }
                return near
            }
            if near.values.contains(where: { !$0.isEmpty }) {
                outcome = try await database.read { db in
                    try Retrieval(plans: plans, query: query, nearWords: near).run(db)
                }
            }
        }
        var results = outcome.results
        results.duration = ContinuousClock.now - started
        return results
    }
}

struct TermKey: Hashable, Sendable {
    var plan: Int
    var term: Int
}

/// One search inside one read transaction.
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
    /// A long word is also looked up as a substring (German compounds) while it occurs in fewer
    /// chunks than this; a common word gains little from it and the trigram scan is not free.
    static let compoundLookupLimit = 200

    struct Outcome: Sendable {
        var results: SearchResults
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

    func run(_ db: Database) throws -> Outcome {
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

        let ordered = scored.values.sorted(by: Self.ranksBefore)
        let complete = ordered.prefix { $0.all }.prefix(query.limit)
        let partialCount = max(0, min(query.limit, Self.partialFill) - complete.count)
        let partial = ordered.dropFirst(complete.count).prefix(partialCount)
        let chosen = Array(complete) + Array(partial)
        let results = try assemble(db, chosen: chosen, matchers: matchers)
        return Outcome(results: results, wantsNearWords: wants)
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
        if query.scope != .all || query.courseID != nil {
            filter = "AND rowid IN (SELECT id FROM search_chunk c WHERE c.kind IN (\(kindFilter))"
            if let courseID = query.courseID {
                filter += " AND c.course_id = ?"
                arguments += [courseID.storageText]
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
        var start: Double?
        var text: String
        var lemmaText: String
    }

    private func uuid(_ value: String?) -> UUID? {
        value.flatMap(UUID.init(uuidString:))
    }

    private func assemble(_ db: Database, chosen: [Scored], matchers: [TermMatcher]) throws -> SearchResults {
        guard !chosen.isEmpty else { return SearchResults(query: query) }
        var chunks: [Int64: Chunk] = [:]
        let rows = try Row.fetchCursor(db, sql: """
            SELECT id, kind, course_id, lecture_id, deck_id, page_number, recording_id, note_id, start_time, text, lemma_text
            FROM search_chunk WHERE id IN (SELECT value FROM json_each(?))
            """, arguments: [Self.json(chosen.map(\.candidate.id))])
        while let row = try rows.next() {
            let id: Int64 = row[0]
            chunks[id] = Chunk(
                id: id, kind: SearchChunkKind(rawValue: row[1]), courseID: uuid(row[2]), lectureID: uuid(row[3]),
                deckID: uuid(row[4]), page: row[5], recordingID: uuid(row[6]), noteID: uuid(row[7]), start: row[8],
                text: row[9], lemmaText: row[10]
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

        var hits: [SearchHit] = []
        for entry in chosen {
            guard let meta = chunks[entry.candidate.id] else { continue }
            var hit = SearchHit(
                id: meta.id, kind: meta.kind, courseID: meta.courseID, lectureID: meta.lectureID, deckID: meta.deckID,
                page: meta.page, recordingID: meta.recordingID, noteID: meta.noteID, time: meta.start,
                snippet: Snippet.make(text: meta.text, lemmaText: meta.lemmaText, matchers: matchers),
                matchesAllTerms: entry.all, target: nil
            )
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

    /// Courses in order of their best hit, each course's lectures and decks likewise, then the notes.
    static func group(
        _ hits: [SearchHit],
        courses: [Course.ID: Course],
        lectures: [Lecture.ID: Lecture],
        decks: [Deck.ID: Deck]
    ) -> [SearchGroup] {
        var groups: [SearchGroup] = []
        var index: [SearchGroup.Kind: Int] = [:]
        var notes: [SearchHit] = []
        for hit in hits {
            let kind: SearchGroup.Kind
            if hit.kind == .note {
                notes.append(hit)
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
        return ordered
    }
}
