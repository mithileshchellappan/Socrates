import Agent
import Deadlines
import Foundation
import StudyCore

/// Organisational slides as a triage source (docs/plan-course-rules.md): the pages of a course's
/// deck that say how the exercises, the admission and the exam work.
///
/// - Found in code, no model: a page names an exam or coursework rule (`ruleFamilies`) and has
///   enough other cues (`score`); the strongest `maximumPages` of a deck, in page order.
/// - One `slides` event per deck version and course ("slides:<deck id>:<blob sha256>:<course id>",
///   `detail` the pages as "<number>:<hash of their words>"), recorded for the course decks that
///   have none yet once every page row is there: the library's decks at launch, then each deck
///   imported, filed to a course or given its pages (AppAgent follows `deck` and `deck_page`).
///   A deck without such pages, of a past semester's course, or whose pages an earlier event of
///   its course read already (a weekly deck repeats its organisational slide) gets a `skipped`
///   row, so it is read once.
/// - Triage reads the pages as escaped, delimited data (`prepared`); a page that talks to a model
///   (`UntrustedText`) is left out and makes the event untrusted (its items never go into the
///   calendar on their own). What it decides is checked against the pages (`FactMaterial.slides`).
enum SlideEvents {
    /// Pages of one deck triage reads.
    static let maximumPages = 8
    /// Characters of one page triage reads.
    static let pageCharacters = 1_500
    /// Days after its lecture period (or, without a semester, the deck's import) a course's slides
    /// are a past semester's and are not read.
    static let pastSemesterDays = 150

    static func sourceKey(_ deck: Deck) -> String {
        "slides:\(deck.id.uuidString.lowercased()):\(deck.blobSHA256):\(deck.courseID?.uuidString.lowercased() ?? "")"
    }

    /// The deck a `slides` event reads.
    static func deckID(of event: AgentEvent) -> Deck.ID? {
        let parts = event.sourceKey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "slides" else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    /// A page triage reads: its number and the hash of its words.
    struct Page: Hashable, Sendable {
        var number: Int
        var hash: String

        init(number: Int, hash: String) {
            self.number = number
            self.hash = hash
        }

        init(_ page: DeckPage) {
            self.init(number: page.pageNumber, hash: AgentText.revision(TextFolding.words(page.text).joined(separator: " ")))
        }

        var detail: String { "\(number):\(hash)" }
    }

    /// The pages an event names ("3:1a2b3c4d,7:…"; an older row's bare numbers have no hash).
    static func selectedPages(of event: AgentEvent) -> [Page] {
        (event.detail ?? "").split(separator: ",").compactMap { item in
            let parts = item.split(separator: ":")
            guard let number = parts.first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }
            return Page(number: number, hash: parts.count > 1 ? String(parts[1]) : "")
        }
    }

    // MARK: - Recording

    /// Records the events of the course decks that have none yet; returns how many wait for triage.
    @discardableResult
    static func record(services: StudyServices, now: Date) async throws -> Int {
        let kind = AgentEventKind.slides
        let rows = try await services.database.read { db in
            (
                decks: try Deck.where { $0.courseID.isNot(nil) }.order(by: \.importedAt).fetchAll(db),
                courses: try Course.all.fetchAll(db),
                semesters: try Semester.all.fetchAll(db),
                events: try AgentEvent.where { $0.kind.eq(kind) }.fetchAll(db)
            )
        }
        let keys = Set(rows.events.map(\.sourceKey))
        let lectureEnds = Dictionary(rows.courses.compactMap { course in
            course.semesterID.flatMap { id in rows.semesters.first { $0.id == id } }.map { (course.id, $0.lectureEnd) }
        }, uniquingKeysWith: { first, _ in first })
        // The pages each course's earlier events read (the same slide in next week's deck is not read again).
        var read: [Course.ID: Set<String>] = [:]
        for event in rows.events where event.state != .failed {
            guard let courseID = event.courseID else { continue }
            read[courseID, default: []].formUnion(selectedPages(of: event).map(\.hash).filter { !$0.isEmpty })
        }
        let today = CalendarDay(now, in: AppAgentModule.timeZone)
        let events = AgentEventRepository(store: services.records)
        var pending = 0
        for deck in rows.decks where !deck.blobSHA256.isEmpty && !keys.contains(sourceKey(deck)) {
            if Task.isCancelled { break }
            guard let courseID = deck.courseID else { continue }
            let deckID = deck.id
            let pages = try await services.database.read { db in
                try DeckPage.where { $0.deckID.eq(deckID) }.order(by: \.pageNumber).fetchAll(db)
            }
            // Pages still to come (a deck syncing, rows a repair writes): read once they are all there.
            guard pages.count >= deck.pageCount else { continue }
            let ended = lectureEnds[courseID] ?? CalendarDay(deck.importedAt, in: AppAgentModule.timeZone)
            let past = ended.adding(days: pastSemesterDays) < today
            let found = past ? [] : organisationalPages(pages).filter { !read[courseID, default: []].contains($0.hash) }
            read[courseID, default: []].formUnion(found.map(\.hash))
            let event = AgentEvent(
                kind: kind, state: found.isEmpty ? .skipped : .pending, sourceKey: sourceKey(deck), courseID: courseID,
                detail: found.isEmpty ? nil : found.map(\.detail).joined(separator: ",")
            )
            if try await events.record(event) != nil, !found.isEmpty { pending += 1 }
        }
        return pending
    }

    // MARK: - Detection

    /// The deck's organisational pages: the strongest `maximumPages`, in page order.
    static func organisationalPages(_ pages: [DeckPage]) -> [Page] {
        let scored = pages.compactMap { page -> (page: DeckPage, score: Int)? in
            let score = score(page.text)
            return score > 0 ? (page, score) : nil
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.page.pageNumber < $1.page.pageNumber }
            .prefix(maximumPages)
            .map { Page($0.page) }
            .sorted { $0.number < $1.number }
    }

    /// Word forms (folded) of one family; a trailing "*" matches the start of a word. A family
    /// counts once, however many of its forms a page has.
    typealias Family = [String]

    /// The page's score: the rule families it names plus the cue families, when it names a rule and
    /// reaches 3 (2 under an organisational heading); else 0. (Not `TranscriptCues`: its session
    /// words, room, online, moved, extra, are common on content slides.)
    static func score(_ text: String) -> Int {
        let words = Set(TextFolding.words(text))
        func names(_ family: Family) -> Bool {
            words.contains { word in family.contains { form in form.hasSuffix("*") ? word.hasPrefix(form.dropLast()) : word == form } }
        }
        let rules = ruleFamilies.count(where: names)
        guard rules > 0 else { return 0 }
        let score = rules + cueFamilies.count(where: names)
        return score >= (names(headingFamily) ? 2 : 3) ? score : 0
    }

    /// An organisational page's heading.
    static let headingFamily: Family = [
        "organisation", "organization", "organisational", "organizational", "organisatorisch*", "orga", "logistics",
    ]

    /// Families that name an exam or coursework rule (DE/EN, folded). Only the organisational forms
    /// of Klausur and Prüfung: a content deck's "Klausuraufgabe" or "prüfungsrelevant" is not one.
    static let ruleFamilies: [Family] = [
        headingFamily,
        ["exam", "exams", "examination", "examinations", "midterm", "midterms"],
        ["klausur", "klausuren", "klausurtermin", "klausurtermine", "klausuranmeldung", "klausurzulassung", "nachklausur", "klausurdauer"],
        [
            "prufung", "prufungen", "prufungsform", "prufungsanmeldung", "prufungstermin", "prufungstermine", "prufungsleistung",
            "prufungszeitraum", "modulprufung", "modulprufungen",
        ],
        ["admission", "admitted", "zulassung*"],
        ["bonus*"],
        ["vorleistung*", "studienleistung*", "leistungsnachweis*", "testat*"],
        ["attendance", "anwesenheit*"],
        ["homework", "coursework", "submission", "submissions", "abgabe*"],
        ["ubungsblatt*", "uebungsblatt*"],
        ["grading", "benotung"],
    ]

    /// Families that go with them on an organisational page.
    static let cueFamilies: [Family] = [
        ["ubung", "ubungen", "uebung", "uebungen", "exercise", "exercises", "tutorium", "tutorien", "tutorial", "tutorials"],
        ["sheet", "sheets", "blatt", "blatter"],
        ["punkte", "points"],
        ["gruppe", "gruppen", "group", "groups"],
        ["deadline", "deadlines", "frist", "fristen"],
        ["mandatory", "pflicht*"],
        ["credits", "ects", "leistungspunkte"],
        ["schriftlich", "written", "mundlich", "oral"],
        ["minuten", "minutes"],
        ["anmeldung", "anmelde*", "registration", "register"],
        ["grade", "grades"],
        ["termin", "termine"],
        ["percent", "prozent"],
        ["weekly", "wochentlich"],
        ["voraussetzung", "voraussetzungen", "requirement", "requirements"],
        ["bestehen", "bestanden"],
    ]

    // MARK: - Reading

    /// The event's pages as triage reads them (`<slides deck day><page n>…</page></slides>`,
    /// escaped data) and how its quotes are checked; nil when nothing is left to read or the deck
    /// is filed to another course since (that course's own event reads it).
    static func prepared(_ event: AgentEvent, services: StudyServices) async throws -> FactTriage.Prepared? {
        let numbers = selectedPages(of: event).map(\.number)
        guard let deckID = deckID(of: event), let first = numbers.min() else { return nil }
        let rows = try await services.database.read { db in
            (
                deck: try Deck.find(deckID).fetchOne(db),
                pages: try DeckPage.where { $0.deckID.eq(deckID) && $0.pageNumber.in(numbers) }.order(by: \.pageNumber).fetchAll(db),
                // The lecture showing the first page as the deck is linked now.
                lecture: try LectureSlides.lecture(showing: first, of: deckID, in: db).flatMap { try Lecture.find($0).fetchOne(db) }
            )
        }
        guard let deck = rows.deck, let courseID = deck.courseID, courseID == event.courseID else { return nil }
        let written = rows.pages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let readable = written.filter { !UntrustedText.talksToModel($0.text) }
        guard !readable.isEmpty else { return nil }
        let pages = readable.map { FactMaterial.SlidePage(number: $0.pageNumber, text: String($0.text.prefix(pageCharacters))) }
        // Dates on the slides are read against the class they were shown in.
        let date = rows.lecture?.heldAt ?? deck.importedAt
        let day = CalendarDay(date, in: AppAgentModule.timeZone).rawValue
        let body = pages.map { "<page n=\"\($0.number)\">\(AgentXML.escape($0.text))</page>" }.joined(separator: "\n")
        return FactTriage.Prepared(
            text: "<slides deck=\"\(AgentXML.escape(deck.title))\" day=\"\(day)\">\n\(body)\n</slides>",
            material: .slides(deckID: deckID, pages: pages, date: date, trusted: readable.count == written.count),
            courseID: courseID
        )
    }
}
