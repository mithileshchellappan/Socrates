import Agent
import Deadlines
import Foundation
import MailIntelligence
import StudyCore

/// Organisational slides as a triage source (docs/plan-course-rules.md): the pages of a course's
/// deck that say how the exercises, the admission and the exam work.
///
/// - Found in code, no model: a page names an exam or coursework rule (`ruleWords`) and has at
///   least one more cue; the strongest `maximumPages` of a deck, in page order.
/// - One `slides` event per deck version ("slides:<deck id>:<blob sha256>", `detail` the page
///   numbers, `lecture_id` the lecture showing the first), recorded on every wake for the course
///   decks that have none yet: the library's decks once, then each deck imported or filed to a
///   course (AppAgent follows the `deck` table). A deck without such pages gets a `skipped` row,
///   so it is read once.
/// - Triage reads the pages as escaped, delimited data (`prepared`); a page that talks to a model
///   (`InjectionGuard`) is left out and makes the event untrusted (its items never go into the
///   calendar on their own). What it decides is checked against the pages (`FactMaterial.slides`).
enum SlideEvents {
    /// Pages of one deck triage reads.
    static let maximumPages = 8
    /// Characters of one page triage reads.
    static let pageCharacters = 1_500

    static func sourceKey(_ deck: Deck) -> String {
        "slides:\(deck.id.uuidString.lowercased()):\(deck.blobSHA256)"
    }

    /// The deck a `slides` event reads.
    static func deckID(of event: AgentEvent) -> Deck.ID? {
        let parts = event.sourceKey.split(separator: ":")
        guard parts.count == 3, parts[0] == "slides" else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    // MARK: - Recording

    /// Records the events of the course decks that have none yet; returns how many wait for triage.
    @discardableResult
    static func record(services: StudyServices) async throws -> Int {
        let kind = AgentEventKind.slides
        let rows = try await services.database.read { db in
            (
                decks: try Deck.where { $0.courseID.isNot(nil) }.fetchAll(db),
                keys: Set(try AgentEvent.where { $0.kind.eq(kind) }.select { $0.sourceKey }.fetchAll(db))
            )
        }
        let events = AgentEventRepository(store: services.records)
        var pending = 0
        for deck in rows.decks where !deck.blobSHA256.isEmpty && !rows.keys.contains(sourceKey(deck)) {
            if Task.isCancelled { break }
            let deckID = deck.id
            let pages = try await services.database.read { db in
                try DeckPage.where { $0.deckID.eq(deckID) }.order(by: \.pageNumber).fetchAll(db)
            }
            // Page text not there yet (a deck still syncing, a repair to come): read it later.
            guard pages.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { continue }
            let found = organisationalPages(pages)
            let lectureID: Lecture.ID? = if let first = found.first {
                try await services.database.read { db in try LectureSlides.lecture(showing: first, of: deckID, in: db) }
            } else {
                nil
            }
            let event = AgentEvent(
                kind: kind, state: found.isEmpty ? .skipped : .pending, sourceKey: sourceKey(deck), courseID: deck.courseID,
                lectureID: lectureID, detail: found.isEmpty ? nil : found.map(String.init).joined(separator: ",")
            )
            if try await events.record(event) != nil, !found.isEmpty { pending += 1 }
        }
        return pending
    }

    // MARK: - Detection

    /// The deck's organisational pages: the strongest `maximumPages`, in page order.
    static func organisationalPages(_ pages: [DeckPage]) -> [Int] {
        let scored = pages.compactMap { page -> (number: Int, score: Int)? in
            let score = score(page.text)
            return score > 0 ? (page.pageNumber, score) : nil
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.number < $1.number }
            .prefix(maximumPages)
            .map(\.number)
            .sorted()
    }

    /// The page's distinct cue words when one of them names a rule and there are at least two;
    /// else 0. (Not `TranscriptCues`: its session words, room, online, moved, extra, are common on
    /// content slides.)
    static func score(_ text: String) -> Int {
        let words = Set(TextFolding.words(text))
        let rules = words.filter { word in ruleWords.contains(word) || rulePrefixes.contains { word.hasPrefix($0) } }
        guard !rules.isEmpty else { return 0 }
        let cues = words.filter { word in !rules.contains(word) && (cueWords.contains(word) || cuePrefixes.contains { word.hasPrefix($0) }) }
        let score = rules.count + cues.count
        return score >= 2 ? score : 0
    }

    /// Words that name an exam or coursework rule (DE/EN, folded).
    static let ruleWords: Set<String> = [
        "exam", "exams", "examination", "midterm", "admission", "admitted", "attendance", "homework", "coursework", "submission",
        "submissions", "grading", "organisation", "organization", "organisational", "organizational", "logistics", "benotung",
    ]

    static let rulePrefixes = [
        "klausur", "prufung", "modulprufung", "zulassung", "bonus", "vorleistung", "studienleistung", "leistungsnachweis", "testat",
        "anwesenheit", "organisatorisch", "ubungsblatt", "ubungsblatter", "abgabe",
    ]

    /// Words that go with them on an organisational page.
    static let cueWords: Set<String> = [
        "ubung", "ubungen", "uebung", "tutorium", "tutorien", "tutorial", "tutorials", "exercise", "exercises", "sheet", "sheets",
        "blatt", "punkte", "points", "gruppe", "gruppen", "group", "groups", "deadline", "deadlines", "frist", "mandatory", "credits", "ects", "schriftlich", "mundlich", "written", "oral", "minuten", "minutes", "anmeldung",
        "registration", "register", "grade", "termin", "termine", "percent", "prozent", "weekly", "wochentlich", "voraussetzung",
        "requirement", "requirements", "bestehen", "bestanden",
    ]

    static let cuePrefixes = ["anmelde", "pflicht"]

    // MARK: - Reading

    /// The event's pages as triage reads them (`<slides deck day><page n>…</page></slides>`,
    /// escaped data) and how its quotes are checked; nil when nothing is left to read.
    static func prepared(_ event: AgentEvent, services: StudyServices) async throws -> FactTriage.Prepared? {
        let numbers = (event.detail ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let deckID = deckID(of: event), !numbers.isEmpty else { return nil }
        let rows = try await services.database.read { db in
            (
                deck: try Deck.find(deckID).fetchOne(db),
                pages: try DeckPage.where { $0.deckID.eq(deckID) && $0.pageNumber.in(numbers) }.order(by: \.pageNumber).fetchAll(db),
                lecture: try event.lectureID.flatMap { try Lecture.find($0).fetchOne(db) }
            )
        }
        guard let deck = rows.deck else { return nil }
        let written = rows.pages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let readable = written.filter { !InjectionGuard.talksToModel($0.text) }
        guard !readable.isEmpty else { return nil }
        let pages = readable.map { FactMaterial.SlidePage(number: $0.pageNumber, text: String($0.text.prefix(pageCharacters))) }
        // Dates on the slides are read against the class they were shown in.
        let date = rows.lecture?.heldAt ?? deck.importedAt
        let day = CalendarDay(date, in: AppAgentModule.timeZone).rawValue
        let body = pages.map { "<page n=\"\($0.number)\">\(AgentXML.escape($0.text))</page>" }.joined(separator: "\n")
        return FactTriage.Prepared(
            text: "<slides deck=\"\(AgentXML.escape(deck.title))\" day=\"\(day)\">\n\(body)\n</slides>",
            material: .slides(deckID: deckID, pages: pages, date: date, trusted: readable.count == written.count),
            courseID: event.courseID ?? deck.courseID
        )
    }
}
