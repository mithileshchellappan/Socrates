import CryptoKit
import Foundation
import SQLiteData

// Record types and values added in schema v18 (mt: course materials). docs/plan-materials.md §2–4
// and its "Build plan", docs/schema.md. The files and their text stay in the document bank
// (`document` with role `material`, Mac only); what is about the course is synced rows.

// MARK: - Values

/// Whose a kept document is (`document.role`).
public struct DocumentRole: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The student's own document (CV, handbook, regulations, …): the Documents screen, the
    /// agent's documents tools. Every row written before v18.
    public static let personal: Self = "personal"
    /// A course material's file, or a link's text snapshot: never on the Documents screen, never
    /// in `search_documents`; its search chunks are kind `material`.
    public static let material: Self = "material"
}

/// What a course material is (`course_material.kind`).
public struct MaterialKind: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// A textbook: a cover tile on the shelf, the reader with chapters, passages for the notes.
    public static let book: Self = "book"
    /// A paper (abstract, DOI or arXiv id).
    public static let paper: Self = "paper"
    /// Any other file the course uses (a lab handbook, a reading, a handout).
    public static let reference: Self = "reference"
    /// A GitHub repository (its facts and README, fetched without a token).
    public static let repository: Self = "repository"
    /// Any other public web page (its title, description and text).
    public static let website: Self = "website"

    /// The kinds of a file material (Show As ▸ Book / Paper / Reference).
    public static let files: [Self] = [.book, .paper, .reference]
    /// The kinds of a link.
    public static let links: [Self] = [.repository, .website]

    public var isFile: Bool { Self.files.contains(self) }
    public var isLink: Bool { Self.links.contains(self) }
}

/// Who decided a material's kind (`course_material.kind_source`). The card may change a guess but
/// never the student's or the agent's choice.
public struct MaterialKindSource: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// `MaterialClassifier` (code, from the PDF's pages), or the screen it was dropped on.
    public static let guess: Self = "guess"
    /// The Haiku card.
    public static let card: Self = "card"
    /// The student (Show As, the toast's Change…).
    public static let student: Self = "student"
    /// The agent at the student's request (`set_material_kind`, `add_material {kind}`).
    public static let agent: Self = "agent"

    /// A choice the card never overrides.
    public var isChosen: Bool { self == .student || self == .agent }
}

/// Where a material is (`course_material.state`).
public enum MaterialState: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// A file being read (text, sections, cover) or a link being fetched; a quit leaves it pending
    /// and the library resumes it at launch.
    case pending
    /// Read (or fetched): its pages are searchable. The card may still be on its way.
    case ready
    /// It could not be read or fetched (`error`: one readable sentence). Read Again / Refresh.
    case failed
    /// Named without its file (the agent's `add_material {title, authors, source}`): a quiet cover
    /// that takes a dropped PDF.
    case wanted
}

/// Where a material's `summary` comes from (`course_material.summary_source`).
public struct MaterialSummarySource: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The page's own words (a repository's description, `og:description`): secondary, no sparkle.
    public static let page: Self = "page"
    /// The Haiku card: grey with one sparkle.
    public static let ai: Self = "ai"
}

/// What the card and the link fetch know about a material besides its title and byline
/// (`course_material.facts`, JSON). Only what applies is set.
public struct MaterialFacts: Hashable, Sendable, Codable {
    // Files (the card, the PDF's metadata)
    public var edition: String?
    public var isbn: String?
    public var doi: String?
    public var arxivID: String?
    /// The PDF's own Title and Author metadata, as read (untrusted text).
    public var pdfTitle: String?
    public var pdfAuthor: String?
    // A repository (api.github.com, unauthenticated)
    public var owner: String?
    public var repo: String?
    /// The folder a `…/tree/<branch>/<path>` link points at (its README is the snapshot).
    public var path: String?
    public var defaultBranch: String?
    public var language: String?
    /// SPDX id ("MIT").
    public var license: String?
    public var topics: [String]?
    public var isArchived: Bool?
    // A website
    public var siteName: String?
    /// The cached favicon (`MaterialCovers.faviconURL(hash:paths:)`); nil: `globe`.
    public var faviconHash: String?
    /// A page that asked for a password or held under 500 characters of text: title and host only.
    public var isTitleOnly: Bool?
    /// The 403/429 rate limit's reset (GitHub): the row stays pending until then.
    public var retryAfter: Date?

    public init(
        edition: String? = nil, isbn: String? = nil, doi: String? = nil, arxivID: String? = nil,
        pdfTitle: String? = nil, pdfAuthor: String? = nil,
        owner: String? = nil, repo: String? = nil, path: String? = nil, defaultBranch: String? = nil,
        language: String? = nil, license: String? = nil, topics: [String]? = nil, isArchived: Bool? = nil,
        siteName: String? = nil, faviconHash: String? = nil, isTitleOnly: Bool? = nil, retryAfter: Date? = nil
    ) {
        self.edition = edition
        self.isbn = isbn
        self.doi = doi
        self.arxivID = arxivID
        self.pdfTitle = pdfTitle
        self.pdfAuthor = pdfAuthor
        self.owner = owner
        self.repo = repo
        self.path = path
        self.defaultBranch = defaultBranch
        self.language = language
        self.license = license
        self.topics = topics
        self.isArchived = isArchived
        self.siteName = siteName
        self.faviconHash = faviconHash
        self.isTitleOnly = isTitleOnly
        self.retryAfter = retryAfter
    }

    public static let empty = MaterialFacts()
}

/// What a section of a material is (`material_section.kind`).
public struct MaterialSectionKind: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Level 1 ("6 Coordination").
    public static let chapter: Self = "chapter"
    /// Level 2 ("6.2 Logical clocks").
    public static let section: Self = "section"
    /// Exercises / Problems / Übungen / Aufgaben: marked for Practice later.
    public static let exercises: Self = "exercises"
    /// Before chapter 1 (preface, contents).
    public static let front: Self = "front"
    /// Appendix, index, bibliography.
    public static let back: Self = "back"
}

/// Where a section was found (`material_section.source`), in the order they are tried.
public struct MaterialSectionSource: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let outline: Self = "outline"
    public static let contents: Self = "contents"
    public static let headings: Self = "headings"
    public static let card: Self = "card"
}

/// How much of a section a lecture covers (`material_coverage.strength`).
public enum CoverageStrength: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// The lecture teaches it: the notes page's "Ch. 6" chip, passages, book further reading,
    /// a book reading, book-first research.
    case core
    /// It touches it: "L3 · L4" in the reader, nothing more.
    case partial
}

/// Who said a lecture covers a section (`material_coverage.source`).
public enum CoverageSource: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// The study pass's `cover` unit (Haiku): replaced when the unit re-runs.
    case pass
    /// The lecturer named it in class (a transcript line, `quote`), found by the `cover` unit.
    case lecturer
    /// The student, through the agent (`set_lecture_coverage`): wins over every other row of the
    /// pair; `covers` false hides the pair. Never replaced by a re-run.
    case student
}

/// A passage of a material the student took to the agent (the reader's Ask About Selection):
/// `AgentContext.materialPassage`.
public struct MaterialPassageContext: Hashable, Sendable, Codable {
    /// ≤ `limit` characters, as selected (untrusted material text: delimited as data).
    public var text: String
    /// The 1-based PDF page it starts on.
    public var page: Int

    public static let limit = 2_000

    public init(text: String, page: Int) {
        self.text = String(text.prefix(Self.limit))
        self.page = page
    }
}

/// A coverage row as an `agent_change` keeps it (`set_lecture_coverage`: `before` / `after`), so
/// Undo can put the student's row back as it was (`exists` false: there was none).
public struct MaterialCoverageValues: Hashable, Sendable, Codable {
    public var id: MaterialCoverage.ID
    public var lectureID: Lecture.ID
    public var materialID: CourseMaterial.ID
    public var sectionID: MaterialSection.ID
    public var covers: Bool
    public var quote: String?

    public init(_ row: MaterialCoverage) {
        id = row.id
        lectureID = row.lectureID
        materialID = row.materialID
        sectionID = row.sectionID
        covers = row.covers
        quote = row.quote
    }

    /// The student's row with these values.
    public func row(updatedAt: Date) -> MaterialCoverage {
        MaterialCoverage(
            id: id, lectureID: lectureID, materialID: materialID, sectionID: sectionID, score: 1, strength: .core,
            source: .student, covers: covers, quote: quote, createdBy: .user, createdAt: updatedAt, updatedAt: updatedAt
        )
    }
}

/// The calls and limits of course materials (docs/plan-materials.md §3, §5). Every Haiku call is a
/// background in-code task (one at a time, paused at a usage limit); Opus never reads more than
/// `readCallCharacters` of a material per call and `readRunCharacters` per agent run.
public enum MaterialCalls {
    /// The card: one Haiku call per file (or per link without a description).
    public static let card = "materials.card"
    /// A chapter's ≤ 3-line summary, written the first time the chapter is current in the reader.
    public static let chapter = "materials.chapter"
    /// The study pass's `cover` unit (one per lecture).
    public static var cover: String { StudyStage.cover.callPurpose }

    public static let cardModel = "claude-haiku-5-5"
    public static let cardEffort = "low"
    public static let cardMaxTokens = 2_000
    public static let chapterModel = "claude-haiku-5-5"
    public static let chapterEffort = "low"
    public static let chapterMaxTokens = 600
    public static let coverModel = "claude-haiku-5-5"
    public static let coverEffort = "low"
    public static let coverMaxTokens = 1_200

    /// The card's input: metadata, outline, pages 1–12 (a paper: its first page), picked by code.
    public static let cardInputCharacters = 40_000
    /// A link's card: its snapshot's first characters.
    public static let linkCardInputCharacters = 12_000
    /// A chapter summary's input: its first two pages, its headings, each section's first sentences.
    public static let chapterInputCharacters = 12_000
    /// `read_material`: whole pages, at most this much per call.
    public static let readCallCharacters = 10_000
    /// `read_material`: at most this much material text per agent run ("Read budget reached for
    /// this answer; search instead.").
    public static let readRunCharacters = 40_000
    /// Lecture notes: at most this many book passages per notes version, each at most this long.
    public static let notesPassages = 3
    public static let notesPassageCharacters = 1_500
    /// Notes Ask: at most this many passages, each at most this long.
    public static let askPassages = 2
    public static let askPassageCharacters = 1_200
    /// The coverage unit: at most this many candidate sections per lecture.
    public static let coverCandidates = 12

    /// A file material (also a PDF fetched from a link) is at most this large.
    public static let maximumFileBytes = 200 * 1_024 * 1_024
    /// Link fetches (`PublicFetch`): one GET, at most this much read, this long.
    public static let fetchBytes = 1 << 20
    public static let fetchTimeout: TimeInterval = 8
    /// A link's readable text kept as its snapshot document.
    public static let snapshotCharacters = 100_000
    public static let userAgent = "Socrates/1 (course material)"
}

// MARK: - Records

/// One material of a course (docs/plan-materials.md): a file (a book, a paper, a reference; its
/// original and text are a `document` of role `material` in the bank, Mac only) or a link (a
/// repository or a website; its README or text is a snapshot document). The shelf's one list, one
/// order, one delete with Undo and one agent key (`mat 3f2a9c1e`). Synced: the phone can list
/// materials, open links and show chapters later; files never leave the Mac.
@Table("course_material")
public struct CourseMaterial: StudyRecord {
    public let id: UUID
    @Column("course_id") public var courseID: Course.ID
    public var kind: MaterialKind
    @Column("kind_source") public var kindSource: MaterialKindSource
    /// The course's book (first on the shelf, first for passages, the one chips name): at most one
    /// per course (by code: `MaterialRepository.setPrimary`).
    @Column("is_primary") public var isPrimary: Bool
    public var state: MaterialState
    /// Why reading or fetching failed: one readable sentence.
    public var error: String?
    /// As the material names itself (the card); the file name (without extension) or the link's
    /// host until then.
    public var title: String
    /// "Jo Example", "A. Sample, B. Placeholder" (≤ 6 authors), "example-org".
    public var byline: String
    public var year: Int?
    /// A link's address (also a file fetched from a link, e.g. an arXiv PDF).
    public var url: URL?
    /// The bank's document holding the file or the link's snapshot. Plain id (no foreign key: the
    /// document is Mac-only); readers tolerate a missing row ("not on this device").
    @Column("document_id") public var documentID: StudyDocument.ID?
    /// PDF pages (the document's page count once read).
    @Column("page_count") public var pageCount: Int
    /// printed page = PDF page − offset ("p. 214" is PDF page 231 at offset 17); nil: none known
    /// (chips name the PDF page).
    @Column("printed_offset") public var printedOffset: Int?
    /// 1–2 sentences, ≤ `summaryLimit` (the page's own description or the card's).
    public var summary: String
    @Column("summary_source") public var summarySource: MaterialSummarySource?
    @Column(as: MaterialFacts.JSONRepresentation.self) public var facts: MaterialFacts
    /// When a link was last fetched.
    @Column("fetched_at") public var fetchedAt: Date?
    /// SHA-256 of a link's snapshot text (Refresh writes a new snapshot only when it changed).
    @Column("text_sha256") public var textSHA256: String?
    /// Where the reader was (PDF page), written 2 s after scrolling rests and on leaving.
    @Column("last_page") public var lastPage: Int?
    @Column("sort_order") public var sortOrder: Int
    /// The card's call.
    @Column("api_call_id") public var apiCallID: APICall.ID?
    /// `user` (a drop, Import…, ⌘V) or `agent` (`add_material`).
    @Column("created_by") public var createdBy: Author
    @Column("added_at") public var addedAt: Date
    @Column("updated_at") public var updatedAt: Date

    public static let summaryLimit = 300

    public init(
        id: UUID = UUID(),
        courseID: Course.ID,
        kind: MaterialKind,
        kindSource: MaterialKindSource = .guess,
        isPrimary: Bool = false,
        state: MaterialState = .pending,
        error: String? = nil,
        title: String,
        byline: String = "",
        year: Int? = nil,
        url: URL? = nil,
        documentID: StudyDocument.ID? = nil,
        pageCount: Int = 0,
        printedOffset: Int? = nil,
        summary: String = "",
        summarySource: MaterialSummarySource? = nil,
        facts: MaterialFacts = .empty,
        fetchedAt: Date? = nil,
        textSHA256: String? = nil,
        lastPage: Int? = nil,
        sortOrder: Int = 0,
        apiCallID: APICall.ID? = nil,
        createdBy: Author = .user,
        addedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.courseID = courseID
        self.kind = kind
        self.kindSource = kindSource
        self.isPrimary = isPrimary
        self.state = state
        self.error = error
        self.title = title
        self.byline = byline
        self.year = year
        self.url = url
        self.documentID = documentID
        self.pageCount = pageCount
        self.printedOffset = printedOffset
        self.summary = String(summary.prefix(Self.summaryLimit))
        self.summarySource = summarySource
        self.facts = facts
        self.fetchedAt = fetchedAt
        self.textSHA256 = textSHA256
        self.lastPage = lastPage
        self.sortOrder = sortOrder
        self.apiCallID = apiCallID
        self.createdBy = createdBy
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }

    /// The key the agent and its citations use (`[[mat 3f2a9c1e p231]]`): the first 8 hex of the id.
    public var key: String { ChatCitation.key(id) }

    /// The printed page number of a PDF page; nil without an offset or before page 1.
    public func printedPage(pdfPage: Int) -> Int? {
        guard let printedOffset else { return nil }
        let printed = pdfPage - printedOffset
        return printed >= 1 ? printed : nil
    }

    /// The PDF page of a printed page number; nil without an offset or outside the PDF.
    public func pdfPage(printedPage: Int) -> Int? {
        guard let printedOffset else { return nil }
        let page = printedPage + printedOffset
        return page >= 1 && (pageCount == 0 || page <= pageCount) ? page : nil
    }

    /// "p. 214" (the printed number), else "p. 231" (the PDF page).
    public func pageLabel(pdfPage: Int) -> String {
        "p. \(printedPage(pdfPage: pdfPage) ?? pdfPage)"
    }

    /// Shelf order: the primary book first, then by `sort_order`, then as added.
    public static func shelfOrder(_ lhs: CourseMaterial, _ rhs: CourseMaterial) -> Bool {
        if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.addedAt < rhs.addedAt
    }
}

/// A chapter or section of a material (PDF pages), found from the PDF's outline, its contents
/// pages, its headings or the card, in that order. `key` is stable across re-reads, so coverage
/// and summaries survive Read Again (`MaterialRepository.replaceSections` keeps rows by key).
@Table("material_section")
public struct MaterialSection: StudyRecord {
    public let id: UUID
    @Column("material_id") public var materialID: CourseMaterial.ID
    /// `MaterialSection.key(number:title:)`.
    public var key: String
    /// "6", "6.2"; "" when unnumbered.
    public var number: String
    public var title: String
    /// 1 (chapter) or 2 (section); deeper levels are not kept.
    public var level: Int
    public var kind: MaterialSectionKind
    /// 1-based PDF pages, inclusive.
    @Column("first_page") public var firstPage: Int
    @Column("last_page") public var lastPage: Int
    /// The printed first page as the book shows it ("201", "xv"); nil when unknown.
    @Column("printed_first") public var printedFirst: String?
    public var source: MaterialSectionSource
    /// ≤ 3 lines, ≤ `summaryLimit` (AI: grey, one sparkle). Chapters only, written when first current.
    public var summary: String
    /// SHA-256 of the chapter's text + the summary prompt's version: never summarised twice.
    @Column("summary_hash") public var summaryHash: String?
    @Column("api_call_id") public var apiCallID: APICall.ID?
    @Column("sort_order") public var sortOrder: Int
    @Column("updated_at") public var updatedAt: Date

    public static let summaryLimit = 400

    public init(
        id: UUID = UUID(),
        materialID: CourseMaterial.ID,
        key: String? = nil,
        number: String = "",
        title: String,
        level: Int = 1,
        kind: MaterialSectionKind = .chapter,
        firstPage: Int,
        lastPage: Int,
        printedFirst: String? = nil,
        source: MaterialSectionSource = .outline,
        summary: String = "",
        summaryHash: String? = nil,
        apiCallID: APICall.ID? = nil,
        sortOrder: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.materialID = materialID
        self.key = key ?? Self.key(number: number, title: title)
        self.number = number
        self.title = title
        self.level = level
        self.kind = kind
        self.firstPage = firstPage
        self.lastPage = Swift.max(firstPage, lastPage)
        self.printedFirst = printedFirst
        self.source = source
        self.summary = String(summary.prefix(Self.summaryLimit))
        self.summaryHash = summaryHash
        self.apiCallID = apiCallID
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
    }

    /// 8 hex of the SHA-256 of the folded number and title ("6.2 Logical clocks"): stable across
    /// re-reads of the same book.
    public static func key(number: String, title: String) -> String {
        let digest = SHA256.hash(data: Data(TopicKey.fold("\(number) \(title)").utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    public var pages: ClosedRange<Int> { firstPage...Swift.max(firstPage, lastPage) }

    public func contains(page: Int) -> Bool { pages.contains(page) }

    /// "§6.2" for a numbered section, "Ch. 6" for a numbered chapter, else the title.
    public var citeLabel: String {
        guard !number.isEmpty else { return title }
        return level >= 2 ? "§\(number)" : "Ch. \(number)"
    }

    /// The deepest section holding `page` (a section before its chapter); nil when none does.
    public static func holding(page: Int, in sections: [MaterialSection]) -> MaterialSection? {
        sections.filter { $0.contains(page: page) }.max { ($0.level, -$0.firstPage) < ($1.level, -$1.firstPage) }
    }

    /// The chapter a section belongs to (itself for a chapter).
    public func chapter(in sections: [MaterialSection]) -> MaterialSection? {
        if level <= 1 { return self }
        return sections.filter { $0.level <= 1 && $0.materialID == materialID && $0.contains(page: firstPage) }
            .max { $0.firstPage < $1.firstPage }
    }

    /// The `goal` of a `material_chapter` task for this section (written and read by code).
    public var taskGoal: String { "Summarize section \(id.uuidString.lowercased()) of a course material." }

    /// The section a `material_chapter` task's goal names.
    public static func sectionID(fromTaskGoal goal: String) -> MaterialSection.ID? {
        goal.split(separator: " ").lazy.compactMap { UUID(uuidString: String($0)) }.first
    }
}

/// One lecture covering one section of a material (the study pass's `cover` unit, a lecturer
/// naming it, or the student's correction). The rows that count are `MaterialCoverage.effective`:
/// per (lecture, section) a student row decides; otherwise every pass and lecturer row does.
@Table("material_coverage")
public struct MaterialCoverage: StudyRecord {
    public let id: UUID
    @Column("lecture_id") public var lectureID: Lecture.ID
    @Column("material_id") public var materialID: CourseMaterial.ID
    @Column("section_id") public var sectionID: MaterialSection.ID
    /// The ai · topic annotation it was matched for (SET NULL when the pass replaces its topics).
    @Column("topic_id") public var topicID: Annotation.ID?
    /// That topic's title, kept when the row goes.
    public var topic: String
    /// 0…1.
    public var score: Double
    public var strength: CoverageStrength
    public var source: CoverageSource
    /// False: the student said the lecture does not cover the section (hides the pair).
    public var covers: Bool
    /// The lecturer's words naming the section (exact span of the line), or the student's.
    public var quote: String?
    @Column("transcript_segment_id") public var transcriptSegmentID: TranscriptSegment.ID?
    /// The `cover` unit that wrote it (CASCADE: a re-run replaces it); nil for student rows.
    @Column("study_unit_id") public var studyUnitID: StudyUnit.ID?
    @Column("api_call_id") public var apiCallID: APICall.ID?
    @Column("created_by") public var createdBy: Author
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        lectureID: Lecture.ID,
        materialID: CourseMaterial.ID,
        sectionID: MaterialSection.ID,
        topicID: Annotation.ID? = nil,
        topic: String = "",
        score: Double = 0,
        strength: CoverageStrength = .partial,
        source: CoverageSource = .pass,
        covers: Bool = true,
        quote: String? = nil,
        transcriptSegmentID: TranscriptSegment.ID? = nil,
        studyUnitID: StudyUnit.ID? = nil,
        apiCallID: APICall.ID? = nil,
        createdBy: Author = .agent,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.lectureID = lectureID
        self.materialID = materialID
        self.sectionID = sectionID
        self.topicID = topicID
        self.topic = topic
        self.score = Swift.min(1, Swift.max(0, score))
        self.strength = strength
        self.source = source
        self.covers = covers
        self.quote = quote
        self.transcriptSegmentID = transcriptSegmentID
        self.studyUnitID = studyUnitID
        self.apiCallID = apiCallID
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The rows that count: per (lecture, section) the student's newest row decides (kept only
    /// when it covers); without one every pass and lecturer row that covers. One row per pair
    /// (the strongest: core over partial, then the higher score).
    public static func effective(_ rows: [MaterialCoverage]) -> [MaterialCoverage] {
        struct Pair: Hashable { var lecture: Lecture.ID; var section: MaterialSection.ID }
        var student: [Pair: MaterialCoverage] = [:]
        for row in rows where row.source == .student {
            let pair = Pair(lecture: row.lectureID, section: row.sectionID)
            if let known = student[pair], known.updatedAt >= row.updatedAt { continue }
            student[pair] = row
        }
        var best: [Pair: MaterialCoverage] = [:]
        for row in rows where row.covers {
            let pair = Pair(lecture: row.lectureID, section: row.sectionID)
            if let decided = student[pair] {
                if decided.covers { best[pair] = decided }
                continue
            }
            guard row.source != .student else { continue }
            if let known = best[pair], (known.strength == .core ? 1 : 0, known.score) >= (row.strength == .core ? 1 : 0, row.score) {
                continue
            }
            best[pair] = row
        }
        return best.values.sorted { ($0.lectureID.uuidString, $0.sectionID.uuidString) < ($1.lectureID.uuidString, $1.sectionID.uuidString) }
    }
}

// MARK: - Deleting

/// Every row a material delete removed (`MaterialRepository.delete`), so Undo writes them back as
/// they were: the materials, their sections and coverage, their book further-reading rows and book
/// readings. The documents are the library's (`MaterialLibrary`): it deletes a role-material
/// document no other material uses and restores it with the bank's own Undo.
public struct MaterialDeletion: Hashable, Sendable {
    public var materials: [CourseMaterial]
    public var sections: [MaterialSection]
    public var coverage: [MaterialCoverage]
    /// ai · further_reading annotations citing the material (`SourceRef.materialID`).
    public var furtherReading: [Annotation]
    /// `study_reading` rows of the material (`material_id`).
    public var readings: [StudyReading]
    /// The bank's deletions (`DocumentBank.delete`) of the role-material documents no other
    /// material used; the library adds them and restores them through the bank first.
    public var documents: [DocumentDeletion]

    public init(
        materials: [CourseMaterial] = [], sections: [MaterialSection] = [], coverage: [MaterialCoverage] = [],
        furtherReading: [Annotation] = [], readings: [StudyReading] = [], documents: [DocumentDeletion] = []
    ) {
        self.materials = materials
        self.sections = sections
        self.coverage = coverage
        self.furtherReading = furtherReading
        self.readings = readings
        self.documents = documents
    }

    public var isEmpty: Bool { materials.isEmpty }
}

// MARK: - Contracts between packages

/// What the screens and the app's commands ask of the material library (Documents' `Materials`
/// target implements it as `MaterialLibrary`; the app injects it, Mac only). Every add returns at
/// once with `pending` rows; reading, fetching, sections, the cover and the card follow in the
/// background. All writes are the student's (`created_by user`); the agent's own adds go through
/// the library directly (AppAgent).
public protocol MaterialLibraryActions: Sendable {
    /// Files (PDFs and the bank's other types) dropped, pasted or imported on a course's Materials:
    /// `kind` nil = the classifier's guess (a PDF neither book nor paper is a reference here). A
    /// file that is already a material of the course comes back as it is.
    func add(files: [URL], to course: Course.ID, as kind: MaterialKind?) async throws -> [CourseMaterial]
    /// A URL (public https is fetched; anything else is kept as a link card that opens in the
    /// browser). A `.webloc` file is passed here by its URL.
    func add(link: URL, to course: Course.ID) async throws -> CourseMaterial
    /// A PDF dropped on a wanted book's cover: the wanted row becomes that file's material (its
    /// title and byline stay until the card writes its own).
    func fill(_ wanted: CourseMaterial.ID, with file: URL) async throws -> CourseMaterial
    /// Deletes materials (no confirmation): the rows of `MaterialDeletion`, and each role-material
    /// document no other material uses. Edit ▸ Undo "Delete Material" passes it to `restore`.
    func delete(_ ids: [CourseMaterial.ID]) async throws -> MaterialDeletion
    func restore(_ deletion: MaterialDeletion) async throws
    /// Show As ▸ Book / Paper / Reference (`kind_source` student).
    func setKind(_ kind: MaterialKind, of id: CourseMaterial.ID) async throws
    /// Read Again after a failure (a file), or Refresh (a link).
    func readAgain(_ id: CourseMaterial.ID) async throws
}

/// Passages of a course's materials, picked on device (Search implements it as
/// `MaterialRetriever`; the app passes it to StudyPass, which gains no Search dependency): the
/// `cover` unit's candidates, the notes' and Ask's book passages.
public protocol MaterialPassages: Sendable {
    /// Hybrid (FTS + semantic) hits over the chunks of kind `material` of the course's ready file
    /// materials, best first.
    func search(_ query: MaterialPassageQuery) async throws -> [MaterialPassageHit]
}

public struct MaterialPassageQuery: Hashable, Sendable {
    /// Plain words (a topic's title and slide lines, a selection), ≤ 600 characters used.
    public var text: String
    public var courseID: Course.ID
    /// Only this material; nil = every ready file material of the course.
    public var materialID: CourseMaterial.ID?
    /// Only these PDF page ranges (a section's pages); empty = all pages.
    public var pages: [ClosedRange<Int>]
    public var limit: Int

    public init(text: String, courseID: Course.ID, materialID: CourseMaterial.ID? = nil, pages: [ClosedRange<Int>] = [], limit: Int = 20) {
        self.text = String(text.prefix(600))
        self.courseID = courseID
        self.materialID = materialID
        self.pages = pages
        self.limit = limit
    }
}

public struct MaterialPassageHit: Hashable, Sendable {
    public var materialID: CourseMaterial.ID
    public var documentID: StudyDocument.ID
    /// 1-based PDF page.
    public var page: Int
    /// The chunk's window (≤ 600 characters): untrusted material text.
    public var text: String
    /// Fused rank score (higher is better).
    public var score: Double

    public init(materialID: CourseMaterial.ID, documentID: StudyDocument.ID, page: Int, text: String, score: Double) {
        self.materialID = materialID
        self.documentID = documentID
        self.page = page
        self.text = text
        self.score = score
    }
}

// MARK: - Values of existing columns (v18)

extension AgentTaskKind {
    /// mt: write a chapter's ≤ 3-line summary (one Haiku call, run in code, one at a time, quiet):
    /// `document_id` = the material's document (a document delete cancels it), `course_id`, the
    /// section in `goal` (`MaterialSection.taskGoal`). Queued only by
    /// `MaterialRepository.queueChapterSummary`. A material's card rides on the bank's `document`
    /// task (its runner picks `MaterialCard` for a role-material document).
    public static let materialChapter: Self = "material_chapter"
}

extension AgentToolGroup {
    /// mt: search_materials, read_material: course materials, untrusted text (never with `web`).
    public static let materials: Self = "materials"
}

extension AgentChangeKind {
    /// mt: a material added from the agent panel (`add_material`); Undo deletes it.
    public static let materialAdd: Self = "material_add"
    /// mt: a material's kind set (`set_material_kind`): `before` / `after.materialKind`.
    public static let materialKind: Self = "material_kind"
    /// mt: the course's book chosen (`set_primary_material`): `before` / `after.materialID` = the
    /// primary material of the course (nil: none).
    public static let materialPrimary: Self = "material_primary"
    /// mt: a lecture's coverage of a section corrected (`set_lecture_coverage`): `before` /
    /// `after.coverage` = the student's row (`exists` false: none).
    public static let materialCoverage: Self = "material_coverage"
}

extension AgentChangeTarget {
    /// mt: a `course_material` row.
    public static let material: Self = "course_material"
    /// mt: a `material_coverage` row (the student's).
    public static let materialCoverage: Self = "material_coverage"
}
