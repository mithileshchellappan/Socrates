import Alignment
import Foundation
import StudyCore

/// mr (docs/plan-actions.md §4 "Continuation detection"): finds the slides of a transcribed
/// recording whose lecture has none, among the decks the course's latest other lectures use ("the
/// session used the same slides as the earlier lecture, which I didn't record") and the course's
/// decks that arrived later (no lecture uses them, or filed since the lecture: slides uploaded
/// after class). On device: the `SlideAligner` runs over every page of each candidate, no
/// model. Slides filed later send the course's recent recordings back here
/// (`LectureSlides.queueContinuationChecks`).
///
/// Measures per candidate (`Measure`): coverage = the share of the speech time the aligner put
/// on a slide; confidence = the duration-weighted mean confidence of those slide spans; the
/// window = the contiguous pages between the 1st and 99th percentile of on-slide time. The best
/// coverage × confidence is accepted above the `Thresholds`; within `newestWinsWithin` of it the
/// first candidate wins (the newest lecture's deck, a later deck after the lectures' decks).
/// Reads only: `LectureProcessor`'s `align` stage writes the link, its change row and the
/// alignment in one transaction.
public struct ContinuationDetector: Sendable {
    /// Every constant of detection, in one place (calibrated once on the parity library; the
    /// numbers are in the Processing README).
    public struct Thresholds: Hashable, Sendable {
        /// Distinct decks of other lectures tried, newest lecture first.
        public var candidateLimit = 3
        /// Further course decks tried after those, newest imported first: decks no lecture uses
        /// and decks filed since the day before the lecture (slides that arrived later, e.g. a deck
        /// the professor uploads after class, filed to the course or to another lecture).
        public var laterDeckLimit = 2
        /// Share of the speech time on a slide.
        public var minimumCoverage = 0.6
        /// Duration-weighted mean confidence of the slide spans.
        public var minimumConfidence = 0.5
        /// Pages in the window.
        public var minimumWindowPages = 3
        /// The window: pages between these fractions of the on-slide time (calibrated: 5 % / 95 %
        /// cut DC L2's discussed slides 38–39; 1 % / 99 % keeps them and still drops a stray visit
        /// under 1 % of the on-slide time at either end).
        public var windowStart = 0.01
        public var windowEnd = 0.99
        /// An earlier candidate (a newer lecture's deck) scoring within this of the best wins.
        public var newestWinsWithin = 0.05

        public init() {}

        public static let `default` = Thresholds()
    }

    /// A deck of the course (another lecture's, or one that arrived later), with every page.
    public struct Candidate: Sendable {
        public var deckID: Deck.ID
        /// The newest other lecture using it (by when it was held); nil: no other lecture uses it.
        public var lectureID: Lecture.ID?
        public var pages: [DeckPage]

        public init(deckID: Deck.ID, lectureID: Lecture.ID?, pages: [DeckPage]) {
            self.deckID = deckID
            self.lectureID = lectureID
            self.pages = pages
        }
    }

    /// What one candidate deck scored against the recording.
    public struct Measure: Hashable, Sendable {
        public var deckID: Deck.ID
        public var coverage: Double
        public var confidence: Double
        /// The window (deck page numbers); 0 when nothing was on a slide.
        public var firstPage: Int
        public var lastPage: Int

        public var score: Double { coverage * confidence }
        public var windowPages: Int { firstPage > 0 ? lastPage - firstPage + 1 : 0 }

        public func passes(_ thresholds: Thresholds) -> Bool {
            coverage >= thresholds.minimumCoverage && confidence >= thresholds.minimumConfidence
                && windowPages >= thresholds.minimumWindowPages
        }
    }

    /// The deck and window detection settled on, and the transcript line that shows it.
    public struct Detection: Sendable {
        public var measure: Measure
        /// Every candidate's measure, newest lecture first (for logs).
        public var measures: [Measure]
        public var candidate: Candidate
        /// The window's pages of the deck, in page order.
        public var pages: [DeckPage]
        /// The best-matching transcript line on a slide inside the window (the change's quote).
        public var line: TranscriptSegment?

        /// The change row's quote: the line's original text, at most 300 characters (cut at a
        /// word end).
        public var quote: String {
            guard let text = line?.originalText.trimmingCharacters(in: .whitespacesAndNewlines) else { return "" }
            return Self.clipped(text, limit: 300)
        }

        static func clipped(_ text: String, limit: Int) -> String {
            guard text.count > limit else { return text }
            let prefix = String(text.prefix(limit))
            guard let space = prefix.lastIndex(of: " ") else { return prefix }
            return String(prefix[..<space])
        }
    }

    public var aligner: SlideAligner
    public var thresholds: Thresholds

    public init(aligner: SlideAligner = SlideAligner(), thresholds: Thresholds = .default) {
        self.aligner = aligner
        self.thresholds = thresholds
    }

    // MARK: - Candidates

    /// The decks of the course's latest lectures other than `lectureID` (newest `held_at` first,
    /// distinct, at most `candidateLimit`), then at most `laterDeckLimit` more of the course's
    /// decks, newest imported first: decks no lecture uses and decks imported since the day before
    /// the lecture (slides that arrived later: filed to the course, or to an older lecture beyond
    /// the newest ones); minus the decks the student turned down for it
    /// (`LectureSlides.declinedDeckIDs`). Inside the caller's read.
    public func candidates(lectureID: Lecture.ID, in db: Database) throws -> [Candidate] {
        guard let lecture = try Lecture.find(lectureID).fetchOne(db) else { return [] }
        let courseID = lecture.courseID
        let others = try Lecture.where { $0.courseID.eq(courseID) && $0.id.neq(lectureID) }.fetchAll(db)
        let newestFirst = others.sorted(by: Self.isNewer)
        let declined = try LectureSlides.declinedDeckIDs(lectureID: lectureID, in: db)
        var seen: Set<Deck.ID> = []
        var candidates: [Candidate] = []
        lectures: for other in newestFirst {
            // A lecture's own decks, its current one first.
            let ranges = try LectureSlides.ranges(lectureID: other.id, in: db).reversed()
            for range in ranges {
                let deckID = range.deckID
                guard !declined.contains(deckID), seen.insert(deckID).inserted else { continue }
                let pages = try DeckPage.where { $0.deckID.eq(deckID) }.order(by: \.pageNumber).fetchAll(db)
                guard !pages.isEmpty else { continue }
                candidates.append(Candidate(deckID: deckID, lectureID: other.id, pages: pages))
                if candidates.count >= thresholds.candidateLimit { break lectures }
            }
        }

        // Slides that arrived later.
        var users: [Deck.ID: Set<Lecture.ID>] = [:]
        for span in try LectureDeckSpan.where({ $0.startTime.is(nil) }).fetchAll(db) {
            users[span.deckID, default: []].insert(span.lectureID)
        }
        let since = (lecture.heldAt ?? lecture.createdAt).addingTimeInterval(-86_400)
        let later = try Deck.where { $0.courseID.eq(courseID) }.order { $0.importedAt.desc() }.fetchAll(db)
        var added = 0
        for deck in later where added < thresholds.laterDeckLimit {
            let deckID = deck.id
            let usedBy = users[deckID] ?? []
            guard usedBy.isEmpty || deck.importedAt >= since, !declined.contains(deckID), seen.insert(deckID).inserted else { continue }
            let pages = try DeckPage.where { $0.deckID.eq(deckID) }.order(by: \.pageNumber).fetchAll(db)
            guard !pages.isEmpty else { continue }
            let user = newestFirst.first { usedBy.contains($0.id) }
            candidates.append(Candidate(deckID: deckID, lectureID: user?.id, pages: pages))
            added += 1
        }
        return candidates
    }

    /// Newest held first; undated lectures after dated ones, newest created first.
    static func isNewer(_ lhs: Lecture, _ rhs: Lecture) -> Bool {
        let left: Date = lhs.heldAt ?? .distantPast
        let right: Date = rhs.heldAt ?? .distantPast
        if left != right { return left > right }
        return lhs.createdAt > rhs.createdAt
    }

    // MARK: - Detecting

    /// Runs detection for a lecture's recording: reads the candidates, the transcript and the
    /// course glossary, aligns against each candidate. Nil when no deck passes.
    public func detect(lecture: Lecture, recording: Recording, database: any DatabaseReader) async throws -> Detection? {
        let lectureID = lecture.id
        let recordingID = recording.id
        let courseID = lecture.courseID
        let read: (candidates: [Candidate], segments: [TranscriptSegment], glossary: String) = try await database.read { db in
            let found = try self.candidates(lectureID: lectureID, in: db)
            let segments = try TranscriptSegment.where { $0.recordingID.eq(recordingID) }.order(by: \.startTime).fetchAll(db)
            let glossary = try Course.find(courseID).fetchOne(db)?.glossary ?? ""
            return (found, segments, glossary)
        }
        let duration: Double? = recording.duration > 0 ? recording.duration : nil
        return detect(candidates: read.candidates, segments: read.segments, duration: duration, glossary: Glossary(text: read.glossary))
    }

    /// Detection over given candidates (newest first). Pure.
    public func detect(candidates: [Candidate], segments: [TranscriptSegment], duration: Double?, glossary: Glossary) -> Detection? {
        guard !segments.isEmpty, !candidates.isEmpty else { return nil }
        let transcript = AlignmentMapping.transcript(segments)
        var measures: [Measure] = []
        var results: [AlignmentResult] = []
        var stoplists: [Set<String>] = []
        for candidate in candidates {
            let slides = AlignmentMapping.slides(candidate.pages)
            let prepared = aligner.prepare(slides: slides, transcript: transcript, duration: duration, glossary: glossary)
            let result = prepared.align(anchors: [])
            measures.append(self.measure(result, deckID: candidate.deckID, transcript: transcript))
            results.append(result)
            stoplists.append(prepared.deckStoplist)
        }
        guard let index = choose(measures) else { return nil }
        let chosen = measures[index]
        let candidate = candidates[index]
        let window = chosen.firstPage...chosen.lastPage
        let pages = candidate.pages.filter { window.contains($0.pageNumber) }
        let line = bestLine(segments: segments, result: results[index], pages: pages, stoplist: stoplists[index])
        return Detection(measure: chosen, measures: measures, candidate: candidate, pages: pages, line: line)
    }

    /// The index of the accepted measure (they come newest lecture first), nil when none passes.
    public func choose(_ measures: [Measure]) -> Int? {
        var best: Double = -1
        for measure in measures where measure.passes(thresholds) {
            best = max(best, measure.score)
        }
        guard best >= 0 else { return nil }
        let floor = best - thresholds.newestWinsWithin
        return measures.firstIndex { $0.passes(thresholds) && $0.score >= floor }
    }

    // MARK: - Measures

    /// Coverage, confidence and window of one alignment.
    public func measure(_ result: AlignmentResult, deckID: Deck.ID, transcript: [TranscriptLine]) -> Measure {
        let slideSpans = result.spans.filter { $0.target.page != nil && $0.duration > 0 }
        // Coverage: speech time inside slide spans over all speech time.
        var speech: Double = 0
        var onSlide: Double = 0
        var spanIndex = 0
        for line in transcript.sorted(by: { $0.start < $1.start }) {
            let start: Double = line.start
            let end: Double = max(line.end, line.start)
            speech += end - start
            while spanIndex < slideSpans.count, slideSpans[spanIndex].end <= start { spanIndex += 1 }
            var index = spanIndex
            while index < slideSpans.count, slideSpans[index].start < end {
                let overlapStart: Double = max(start, slideSpans[index].start)
                let overlapEnd: Double = min(end, slideSpans[index].end)
                if overlapEnd > overlapStart { onSlide += overlapEnd - overlapStart }
                index += 1
            }
        }
        let coverage: Double = speech > 0 ? onSlide / speech : 0

        // Confidence: the slide spans' confidence weighted by their length.
        var slideTime: Double = 0
        var weighted: Double = 0
        var timeByPage: [Int: Double] = [:]
        for span in slideSpans {
            guard let page = span.target.page else { continue }
            slideTime += span.duration
            weighted += span.duration * span.confidence
            timeByPage[page, default: 0] += span.duration
        }
        let confidence: Double = slideTime > 0 ? weighted / slideTime : 0
        let window = Self.window(timeByPage, from: thresholds.windowStart, to: thresholds.windowEnd)
        return Measure(deckID: deckID, coverage: coverage, confidence: confidence, firstPage: window.first, lastPage: window.last)
    }

    /// The pages between the `from` and `to` fractions of the on-slide time, in page order;
    /// (0, 0) when there is none.
    static func window(_ timeByPage: [Int: Double], from: Double, to: Double) -> (first: Int, last: Int) {
        let pages = timeByPage.keys.sorted()
        let total: Double = timeByPage.values.reduce(0, +)
        guard total > 0, let lastPage = pages.last else { return (0, 0) }
        var first: Int?
        var last: Int?
        var cumulative: Double = 0
        for page in pages {
            cumulative += timeByPage[page] ?? 0
            let share: Double = cumulative / total
            if first == nil, share >= from { first = page }
            if last == nil, share >= to { last = page }
        }
        let start: Int = first ?? pages[0]
        let end: Int = max(last ?? lastPage, start)
        return (start, end)
    }

    /// The line on a window slide that shares the most terms with that slide (deck boilerplate
    /// left out); ties go to the earlier line. Nil when no line is on a window slide.
    func bestLine(segments: [TranscriptSegment], result: AlignmentResult, pages: [DeckPage], stoplist: Set<String>) -> TranscriptSegment? {
        let tokenizer = Tokenizer()
        var slideTerms: [Int: Set<String>] = [:]
        for page in pages {
            slideTerms[page.pageNumber] = Set(tokenizer.terms(in: page.text)).subtracting(stoplist)
        }
        var best: TranscriptSegment?
        var bestShared = -1
        for segment in segments {
            let middle: Double = (segment.startTime + max(segment.endTime, segment.startTime)) / 2
            guard let page = result.target(at: middle).page, let terms = slideTerms[page] else { continue }
            let said = Set(tokenizer.terms(in: segment.text))
            let shared: Int = said.intersection(terms).count
            if shared > bestShared {
                best = segment
                bestShared = shared
            }
        }
        return best
    }
}
