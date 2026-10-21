import Deadlines
import Foundation
import StudyCore

/// Everything the pass reads about one lecture (plan §1), loaded in one read: the transcript lines
/// of all its recordings on the lecture's timeline ("l1", "l2", …; `LectureRecordingMerge`), the
/// slide sections of each recording's own alignment (`LectureOutline`), the deck and its pages,
/// the student's flags, the course.
///
/// Every recording of the lecture (2026-10-21; before, only the one with the most lines):
/// recordings one after the other are read in time order; two recordings of the same stretch (two
/// devices at once) are not doubled, each shared stretch keeps the lines of the recording with
/// more words there (`LectureRecordingMerge` has the rules). A line keeps its recording and its
/// time on that recording's clock (`start`), so every row the pass writes names the recording and
/// moment it was said on; `clock` orders it on the timeline. With one recording, ids, times,
/// sections and prompts are what they were (no unit runs again). One deck: the lecture's range,
/// else the deck with the most timed spans of its recordings (else the coarse span's).
struct LectureMaterial: Sendable {
    struct Line: Sendable {
        /// "l17": its position on the timeline; stable while the transcripts are.
        var id: String
        var index: Int
        var segment: TranscriptSegment
        /// Index into `sections`.
        var section: Int
        var flagged: Bool
        /// Seconds on the lecture's timeline (`LectureTimeline`; with one recording, `start`).
        var clock: Double

        /// As first transcribed (what read units see; patches are offsets into it).
        var original: String { segment.originalText }
        /// With the corrections applied (what synthesis sees and quotes are found in).
        var text: String { segment.text }
        /// Seconds on its recording's clock (what rows and chips store).
        var start: Double { segment.startTime }
        var end: Double { segment.endTime }
        /// The recording it was said on.
        var recordingID: Recording.ID { segment.recordingID }
        /// Spoken words (of the original).
        var wordCount: Int { TextRules.wordCount(segment.originalText) }
    }

    struct Section: Sendable {
        var index: Int
        /// Nil for an off-slide stretch or an unaligned transcript.
        var page: Int?
        var title: String
        /// Seconds on `recordingID`'s clock.
        var start: Double
        var end: Double
        var source: SpanSource?
        var confidence: Double?
        /// Indices into `lines`.
        var lines: [Int]
        var isOffSlide: Bool
        /// The recording whose alignment it comes from.
        var recordingID: Recording.ID

        /// An automatic span under 0.4 confidence: no summary for it.
        var isLowConfidence: Bool { source == .auto && (confidence ?? 1) < 0.4 }

        /// `align` attribute of the read prompt.
        var alignLabel: String {
            switch source {
            case .stamp?: "stamp"
            case .manual?: "manual"
            case .auto? where isLowConfidence: "auto-low"
            default: "auto"
            }
        }
    }

    var lecture: Lecture
    var course: Course?
    /// The recording with the most lines (the lecture summary's); every line names its own.
    var recordingID: Recording.ID
    /// The recordings with lines, in timeline order.
    var recordings: [Recording.ID]
    /// Where each recording sits on the lecture's timeline.
    var timeline: LectureTimeline
    var deck: Deck?
    /// The deck's pages by number.
    var pages: [Int: DeckPage]
    var lines: [Line]
    var sections: [Section]
    /// Pages the lecture covered: its timed sections and its coarse spans of the deck.
    var lecturePages: [Int]
    /// Spoken language (BCP 47): the lecture's, else the course's, else the transcript's.
    var language: String
    /// Slide sections exist (else read units are 15-minute blocks).
    var hasSlides: Bool

    var isGerman: Bool { language.lowercased().hasPrefix("de") }
    /// Lines of more than one recording.
    var hasSeveralRecordings: Bool { recordings.count > 1 }

    func line(id: String) -> Line? {
        let key = id.trimmingCharacters(in: .whitespaces).lowercased()
        guard key.hasPrefix("l"), let number = Int(key.dropFirst()), number >= 1, number <= lines.count else { return nil }
        let line = lines[number - 1]
        return line.id == key ? line : lines.first { $0.id == key }
    }

    func lineIndex(segmentID: TranscriptSegment.ID) -> Int? {
        lines.firstIndex { $0.segment.id == segmentID }
    }

    /// The slide on screen while a line was said (nil off-slide).
    func page(ofLine index: Int) -> Int? {
        sections[lines[index].section].page
    }

    /// Where a section starts on the lecture's timeline.
    func clock(of section: Section) -> Double {
        timeline.seconds(section.start, on: section.recordingID)
    }

    func slideText(_ page: Int) -> String {
        pages[page]?.text ?? ""
    }

    func slideTitle(_ page: Int) -> String {
        DeckPage.title(fromPageText: slideText(page))
    }

    /// Lines as `TranscriptQuote` finds quotes in them (corrected text).
    var quoteLines: [TranscriptQuote.Line] {
        lines.map { TranscriptQuote.Line(id: $0.id, text: $0.text, start: $0.start, words: $0.segment.words ?? []) }
    }

    /// "Data Centers (DC)".
    var courseName: String {
        guard let course else { return "" }
        return course.shortName.isEmpty || course.shortName == course.name ? course.name : "\(course.name) (\(course.shortName))"
    }

    /// "Lecture 2: Virtualization".
    var lectureName: String {
        let title = lecture.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = lecture.number else { return title.isEmpty ? "Lecture" : title }
        return title.isEmpty ? "Lecture \(number)" : "Lecture \(number): \(title)"
    }

    /// The prompt's first line: course, lecture, day, lecturers, spoken language.
    var header: String {
        var parts: [String] = []
        if !courseName.isEmpty { parts.append("Course: \(courseName)") }
        parts.append(lectureName)
        if let held = lecture.heldAt {
            parts.append("held \(held.formatted(.iso8601.year().month().day()))")
        }
        if let professors = course?.professors, !professors.isEmpty {
            parts.append("Lecturers: \(professors.joined(separator: ", "))")
        }
        parts.append("Spoken language: \(language.isEmpty ? "unknown" : language)")
        return PromptText.escape(parts.joined(separator: ". ")) + "."
    }

    /// `header` as the input hash sees it: the lecture and its language. A course rename, a
    /// lecturer or the day never sends a unit again (the prompt still carries them).
    var hashedHeader: String {
        PromptText.escape("\(lectureName). Spoken language: \(language.isEmpty ? "unknown" : language)") + "."
    }

    /// The course's glossary terms that a word of `texts` starts like (folded; the first 5
    /// letters, a shorter term word whole): a glossary edit sends only the blocks it concerns.
    func glossaryTerms(matching texts: [String]) -> [String] {
        let terms = course?.glossaryTerms ?? []
        guard !terms.isEmpty else { return [] }
        var words: Set<String> = []
        var stems: Set<Substring> = []
        for text in texts {
            for word in TextFolding.words(text) {
                words.insert(word)
                if word.count >= 5 { stems.insert(word.prefix(5)) }
            }
        }
        return terms.filter { term in
            TextFolding.words(term).contains { word in
                word.count < 5 ? words.contains(word) : stems.contains(word.prefix(5))
            }
        }
    }

    // MARK: - Loading

    /// Nil when the lecture is gone or has no transcript lines.
    static func load(_ lectureID: Lecture.ID, in db: Database) throws -> LectureMaterial? {
        guard let lecture = try Lecture.find(lectureID).fetchOne(db) else { return nil }
        let course = try Course.find(lecture.courseID).fetchOne(db)
        let segments = try TranscriptSegment
            .where { $0.lectureID.eq(lectureID) }
            .order(by: \.startTime)
            .fetchAll(db)
        let reference = Lecture.ID?.some(lectureID)
        let recordingRows = try Recording.where { $0.lectureID.eq(reference) }.fetchAll(db)
        let merge = LectureRecordingMerge.merge(recordings: recordingRows, segments: segments.filter(LectureRecordingMerge.isSpoken))
        let kept = merge.segments
        var perRecording: [Recording.ID: Int] = [:]
        for segment in kept { perRecording[segment.recordingID, default: 0] += 1 }
        guard let recordingID = perRecording.max(by: { $0.value == $1.value ? $0.key.uuidString > $1.key.uuidString : $0.value < $1.value })?.key
        else { return nil }
        let included = Set(merge.recordings)
        let several = included.count > 1
        let timeline = merge.timeline

        let spans = try LectureDeckSpan.where { $0.lectureID.eq(lectureID) }.fetchAll(db)
        // mr: the lecture's slides are its range of a deck (`LectureSlides.current`): the pass
        // reads only those pages, so its input hash changes with the range. Without a range (a
        // capture's stamped deck), the deck most of the recordings' slide spans are on, whole.
        let range = try LectureSlides.current(lectureID: lectureID, in: db)
        var timedPerDeck: [Deck.ID: Int] = [:]
        for span in spans where span.isTimed && span.firstPage != nil && (span.recordingID.map(included.contains) ?? true) {
            timedPerDeck[span.deckID, default: 0] += 1
        }
        let mostTimed: Deck.ID? = timedPerDeck.max(by: { $0.value == $1.value ? $0.key.uuidString > $1.key.uuidString : $0.value < $1.value })?.key
        let deckID: Deck.ID? = range?.deckID ?? mostTimed
        let deck = try deckID.flatMap { try Deck.find($0).fetchOne(db) }
        var deckPages: [DeckPage] = []
        if let range {
            deckPages = try LectureSlides.pages(of: range, in: db)
        } else if let deck {
            let id = deck.id
            deckPages = try DeckPage.where { $0.deckID.eq(id) }.order(by: \.pageNumber).fetchAll(db)
        }
        let inRange: ClosedRange<Int>? = range?.pages
        // Each recording's slide visits, on its own clock (its own alignment).
        func timed(_ recording: Recording.ID) -> [LectureDeckSpan] {
            spans.filter { span in
                guard span.isTimed, span.deckID == deck?.id, span.recordingID == nil || span.recordingID == recording else { return false }
                guard let inRange, let page = span.firstPage else { return true }
                return inRange.contains(page)
            }
        }
        var byRecording: [Recording.ID: [TranscriptSegment]] = [:]
        for segment in kept { byRecording[segment.recordingID, default: []].append(segment) }
        var outlines: [Recording.ID: LectureOutline] = [:]
        for id in included {
            outlines[id] = LectureOutline(segments: byRecording[id] ?? [], spans: timed(id), pages: deckPages)
        }

        var lines: [Line] = []
        var sections: [Section] = []
        if !several, let outline = outlines[recordingID] {
            // One recording: its slide visits as they are (empty ones too), lines in time order.
            var sectionOfSegment: [TranscriptSegment.ID: Int] = [:]
            for (index, section) in outline.sections.enumerated() {
                for segment in section.segments { sectionOfSegment[segment.id] = index }
            }
            sections = outline.sections.enumerated().map { index, section in
                Section(
                    index: index, page: section.page, title: section.title, start: section.start, end: section.end,
                    source: section.source, confidence: section.confidence, lines: [], isOffSlide: section.isOffSlide,
                    recordingID: recordingID)
            }
            for segment in kept.sorted(by: { $0.startTime < $1.startTime }) {
                guard let section = sectionOfSegment[segment.id] else { continue }
                let index = lines.count
                lines.append(Line(
                    id: "l\(index + 1)", index: index, segment: segment, section: section, flagged: false,
                    clock: timeline.seconds(segment.startTime, on: segment.recordingID)))
                sections[section].lines.append(index)
            }
        } else {
            // Several: a section per run of lines of one slide visit of one recording, in
            // timeline order (a visit that a shared stretch cuts in two is two sections).
            var visitOfSegment: [TranscriptSegment.ID: (recording: Recording.ID, visit: Int)] = [:]
            for (id, outline) in outlines {
                for (index, section) in outline.sections.enumerated() {
                    for segment in section.segments { visitOfSegment[segment.id] = (id, index) }
                }
            }
            var current: (recording: Recording.ID, visit: Int)?
            for segment in kept {
                guard let found = visitOfSegment[segment.id], let visit = outlines[found.recording]?.sections[found.visit] else { continue }
                if current?.recording != found.recording || current?.visit != found.visit {
                    let opens = visit.segments.first?.id == segment.id
                    sections.append(Section(
                        index: sections.count, page: visit.page, title: visit.title, start: opens ? visit.start : segment.startTime,
                        end: segment.endTime, source: visit.source, confidence: visit.confidence, lines: [], isOffSlide: visit.isOffSlide,
                        recordingID: found.recording))
                    current = found
                }
                let index = lines.count
                let section = sections.count - 1
                lines.append(Line(
                    id: "l\(index + 1)", index: index, segment: segment, section: section, flagged: false,
                    clock: timeline.seconds(segment.startTime, on: segment.recordingID)))
                sections[section].lines.append(index)
                sections[section].end = visit.segments.last?.id == segment.id ? visit.end : max(sections[section].end, segment.endTime)
            }
        }
        guard !lines.isEmpty else { return nil }

        // The student's flags (F in class) mark the line said at that moment (on the timeline: a
        // flag in a stretch another recording kept marks that recording's line). Only flags
        // captured in class carry a host time; flags added later in Review stay out of the pass.
        for id in merge.recordings {
            guard let recording = try Recording.find(id).fetchOne(db), recording.sampleRate > 0 else { continue }
            let flags = try SlideEvent
                .where { $0.recordingID.eq(id) && $0.kind.eq(SlideEventKind.flag) && $0.hostTime.isNot(nil) }
                .fetchAll(db)
                .compactMap { $0.sampleTime.map { Double($0) / recording.sampleRate } }
            for time in flags {
                let moment = timeline.seconds(time, on: id)
                let index = lines.lastIndex { $0.clock <= moment + 0.5 } ?? 0
                lines[index].flagged = true
            }
        }

        let visits = outlines.values.flatMap(\.sections)
        var covered = Set(visits.compactMap(\.page))
        if let range {
            covered.formUnion(range.pages)
        }
        let pages = Dictionary(deckPages.map { ($0.pageNumber, $0) }, uniquingKeysWith: { first, _ in first })
        covered = covered.filter { pages[$0] != nil || deckPages.isEmpty }

        var languages: [String: Int] = [:]
        for segment in kept { languages[segment.lang, default: 0] += 1 }
        let spoken = languages.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.first?.key
        let language = [lecture.language, course?.language ?? ""].first { !$0.isEmpty } ?? spoken ?? ""
        if several {
            StudyPass.log.info(
                "Lecture material from \(included.count, privacy: .public) recordings: \(lines.count, privacy: .public) lines, \(merge.dropped, privacy: .public) left out in \(merge.overlaps, privacy: .public) shared stretches, \(merge.moved, privacy: .public) placed after the one before"
            )
        }
        return LectureMaterial(
            lecture: lecture, course: course, recordingID: recordingID, recordings: merge.recordings, timeline: timeline, deck: deck,
            pages: pages, lines: lines, sections: sections, lecturePages: covered.sorted(), language: language,
            hasSlides: visits.contains { $0.page != nil })
    }
}
