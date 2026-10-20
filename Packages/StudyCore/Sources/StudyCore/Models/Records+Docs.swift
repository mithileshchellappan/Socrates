import CryptoKit
import Foundation
import SQLiteData
import UniformTypeIdentifiers

// Record types and values added in schema v14 (md: the document bank). docs/plan-docs.md §3–4,
// docs/schema.md.

// MARK: - Values

/// What a kept document is (`document.kind`), as the Haiku summary decides it (`other` until then).
public struct DocumentKind: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The student's CV.
    public static let cv: Self = "cv"
    /// A module or semester handbook (Modulhandbuch).
    public static let handbook: Self = "handbook"
    /// Exam or study regulations (Prüfungsordnung, Studienordnung).
    public static let regulations: Self = "regulations"
    /// A transcript of records, a grade sheet.
    public static let transcript: Self = "transcript"
    /// A certificate: enrolment, language, a degree.
    public static let certificate: Self = "certificate"
    /// A letter or notice (the examination office, the university).
    public static let letter: Self = "letter"
    public static let other: Self = "other"

    /// The kinds the summary may answer with, in this order (its JSON schema's enum).
    public static let all: [Self] = [.cv, .handbook, .regulations, .transcript, .certificate, .letter, .other]
}

/// How far reading a document's text got (`document.text_state`). Device work on the Mac.
public enum DocumentTextState: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// Added; its text is being read (or a quit interrupted reading it: resumed at launch).
    case pending
    /// Its pages are in `document_page`.
    case done
    /// It could not be read (`error` says why in one readable sentence).
    case failed
}

/// Where a document's summary is (`document.summary_state`): the Haiku task of kind `document`.
public enum DocumentSummaryState: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// Waits for its text, for Claude Code or for its turn in the task queue.
    case pending
    case done
    /// The summary could not be written (`error`); Read Again queues it again.
    case failed
    /// Nothing to summarise: the text could not be read.
    case skipped
}

/// One fact worth looking up later ("Data Centers: 6 LP, written exam, 90 minutes"), written by
/// the summary (AI text), with the page it was read on.
public struct DocumentFact: Hashable, Sendable, Codable {
    /// ≤ 160 characters.
    public var text: String
    /// The 1-based page (`document_page.page_number`); nil when not known.
    public var page: Int?

    public init(text: String, page: Int? = nil) {
        self.text = text
        self.page = page
    }
}

/// A date the document states ("Exam registration online, 14 Dec – 8 Jan"), kept only when its page
/// mentions that day (checked in code).
public struct DocumentDate: Hashable, Sendable, Codable {
    public var day: CalendarDay
    /// The last day of a range.
    public var endDay: CalendarDay?
    /// "10:15" when the document states a time.
    public var time: String?
    /// ≤ 100 characters.
    public var what: String
    public var page: Int?

    public init(day: CalendarDay, endDay: CalendarDay? = nil, time: String? = nil, what: String, page: Int? = nil) {
        self.day = day
        self.endDay = endDay
        self.time = time
        self.what = what
        self.page = page
    }
}

/// One entry of a document's outline: the PDF's own outline, else the sections the summary found.
public struct DocumentSection: Hashable, Sendable, Codable {
    public var title: String
    /// The page it starts on.
    public var page: Int
    /// 1 = top level.
    public var level: Int

    public init(title: String, page: Int, level: Int = 1) {
        self.title = title
        self.page = page
        self.level = level
    }
}

// MARK: - Records

/// A document the student keeps for the agent (PRD "Document bank"): a CV, a module handbook, exam
/// regulations, a transcript, a certificate, a letter. The original file is in the BlobStore and
/// never changed; its text is in `document_page`; the summary, kind, related courses, key facts
/// and dates are written by the background Haiku task (AI text: grey with one sparkle on screen).
/// Its text is untrusted data for every model call (it may carry instructions) and holds personal
/// data: it never sits beside web tools.
@Table("document")
public struct StudyDocument: StudyRecord {
    public let id: UUID
    /// The summary's title ("Modulhandbuch M.Sc. Informatik"); the file name without its extension
    /// until then.
    public var title: String
    /// The name the student's file had ("Modulhandbuch_Inf_MSc.pdf").
    @Column("file_name") public var fileName: String
    /// The uniform type identifier of the original ("com.adobe.pdf").
    @Column("file_type") public var fileType: String
    public var kind: DocumentKind
    @Column("blob_sha256") public var blobSHA256: String
    /// Path relative to the BlobStore root.
    @Column("blob_path") public var blobPath: String
    @Column("byte_count") public var byteCount: Int
    /// `document_page` rows: a PDF's pages, an image's one page, parts of flowing text.
    @Column("page_count") public var pageCount: Int
    /// BCP 47 of the text ("de", "en"), "" until read.
    public var language: String
    @Column("text_state") public var textState: DocumentTextState
    /// SHA-256 (hex) of the pages' text joined with "\n\n"; nil until read.
    @Column("text_sha256") public var textSHA256: String?
    @Column("summary_state") public var summaryState: DocumentSummaryState
    /// 1–3 sentences, ≤ 400 characters (AI).
    public var summary: String
    @Column("key_facts", as: [DocumentFact].JSONRepresentation.self) public var keyFacts: [DocumentFact]
    @Column(as: [DocumentDate].JSONRepresentation.self) public var dates: [DocumentDate]
    /// The student's courses it concerns (no foreign key: JSON; unknown ids are ignored).
    @Column("course_ids", as: [Course.ID].JSONRepresentation.self) public var courseIDs: [Course.ID]
    @Column(as: [DocumentSection].JSONRepresentation.self) public var outline: [DocumentSection]
    /// SHA-256 of `text_sha256` + the summary's prompt version it was written from: the same text
    /// is never summarised twice.
    @Column("summary_hash") public var summaryHash: String?
    /// The model that wrote the summary.
    public var model: String?
    @Column("api_call_id") public var apiCallID: APICall.ID?
    @Column("summarized_at") public var summarizedAt: Date?
    /// Why reading or summarising failed: one readable sentence.
    public var error: String?
    /// `user` (a drop, Import…) or `agent` (keep_document on the panel).
    @Column("created_by") public var createdBy: Author
    @Column("added_at") public var addedAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        fileName: String,
        fileType: String,
        kind: DocumentKind = .other,
        blobSHA256: String = "",
        blobPath: String = "",
        byteCount: Int = 0,
        pageCount: Int = 0,
        language: String = "",
        textState: DocumentTextState = .pending,
        textSHA256: String? = nil,
        summaryState: DocumentSummaryState = .pending,
        summary: String = "",
        keyFacts: [DocumentFact] = [],
        dates: [DocumentDate] = [],
        courseIDs: [Course.ID] = [],
        outline: [DocumentSection] = [],
        summaryHash: String? = nil,
        model: String? = nil,
        apiCallID: APICall.ID? = nil,
        summarizedAt: Date? = nil,
        error: String? = nil,
        createdBy: Author = .user,
        addedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.fileName = fileName
        self.fileType = fileType
        self.kind = kind
        self.blobSHA256 = blobSHA256
        self.blobPath = blobPath
        self.byteCount = byteCount
        self.pageCount = pageCount
        self.language = language
        self.textState = textState
        self.textSHA256 = textSHA256
        self.summaryState = summaryState
        self.summary = summary
        self.keyFacts = keyFacts
        self.dates = dates
        self.courseIDs = courseIDs
        self.outline = outline
        self.summaryHash = summaryHash
        self.model = model
        self.apiCallID = apiCallID
        self.summarizedAt = summarizedAt
        self.error = error
        self.createdBy = createdBy
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }

    /// The original file.
    public var blob: BlobRef? {
        blobSHA256.isEmpty ? nil : BlobRef(sha256: blobSHA256, relativePath: blobPath, byteCount: Int64(byteCount))
    }

    /// What kind of file the original is.
    public var fileKind: FileKind? { UTType(fileType).flatMap(Self.fileKind(for:)) }

    /// The key the agent and its citations use: the first 8 hex of the id (`ChatCitation.key`).
    public var key: String { ChatCitation.key(id) }

    /// `text_sha256`: SHA-256 (lowercase hex) of the pages' text joined with "\n\n".
    public static func textSHA256(of pages: [String]) -> String {
        SHA256.hash(data: Data(pages.joined(separator: "\n\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `summary_hash`: SHA-256 (lowercase hex) of "<text_sha256>:<prompt version>"
    /// (`DocumentSummarizer.promptVersion`): the same text is never summarised twice.
    public static func summaryHash(textSHA256: String, promptVersion: Int) -> String {
        SHA256.hash(data: Data("\(textSHA256):\(promptVersion)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Accepted files

    /// The kinds of file the bank reads (docs/plan-docs.md §4 "Text").
    public enum FileKind: String, Hashable, Sendable, CaseIterable {
        case pdf
        /// Word .docx / .doc, OpenDocument text (`NSAttributedString` on the Mac).
        case word
        /// RTF.
        case richText
        /// Pages: its preview PDF when the file has one.
        case pages
        /// Plain text and Markdown.
        case text
        /// A photo or scan of a document (Vision OCR).
        case image
    }

    /// The largest file the bank takes.
    public static let maximumBytes = 200 * 1_024 * 1_024

    /// Word, OpenDocument and Pages types (declared by the system; nil ones are skipped).
    static let wordTypes: [UTType] = [
        UTType("org.openxmlformats.wordprocessingml.document"), UTType("com.microsoft.word.doc"),
        UTType("org.oasis-open.opendocument.text"),
    ].compactMap(\.self)
    static let pagesTypes: [UTType] = [
        UTType("com.apple.iwork.pages.sffpages"), UTType("com.apple.iwork.pages.pages"),
    ].compactMap(\.self)
    static let imageTypes: [UTType] = [.png, .jpeg, .heic, .tiff, .gif, .webP]

    /// The file kind of `type`, or nil when the bank does not take it (audio, video, archives,
    /// Keynote, spreadsheets, …).
    public static func fileKind(for type: UTType) -> FileKind? {
        if type.conforms(to: .pdf) { return .pdf }
        if wordTypes.contains(where: { type.conforms(to: $0) }) { return .word }
        if pagesTypes.contains(where: { type.conforms(to: $0) }) { return .pages }
        if type.conforms(to: .rtf) { return .richText }
        if imageTypes.contains(where: { type.conforms(to: $0) }) { return .image }
        if type.conforms(to: .plainText) || type.identifier == "net.daringfireball.markdown" { return .text }
        return nil
    }

    /// The file kind of a file name or URL (by its extension).
    public static func fileKind(forFileName name: String) -> FileKind? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return nil }
        return fileKind(for: type)
    }

    /// The types the Documents screen's drop and Import… accept.
    public static var acceptedTypes: [UTType] {
        [.pdf] + wordTypes + pagesTypes + [.rtf, .plainText] + [UTType("net.daringfireball.markdown")].compactMap(\.self) + imageTypes
    }
}

/// The text of one page of a document: a PDF page, an image, or a part of ≤ 4,000 characters of
/// flowing text (Word, RTF, text), numbered from 1.
@Table("document_page")
public struct StudyDocumentPage: StudyRecord {
    public let id: UUID
    /// CASCADE: the pages go with their document.
    @Column("document_id") public var documentID: StudyDocument.ID
    /// 1-based.
    @Column("page_number") public var pageNumber: Int
    /// The PDF page label when it differs from the number ("iv", "12").
    public var label: String
    /// The section heading that starts on this page, when one was found.
    public var heading: String?
    public var text: String
    /// The text came from Vision OCR (a scanned page, an image).
    @Column("is_ocr") public var isOCR: Bool
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        documentID: StudyDocument.ID,
        pageNumber: Int,
        label: String = "",
        heading: String? = nil,
        text: String,
        isOCR: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.documentID = documentID
        self.pageNumber = pageNumber
        self.label = label
        self.heading = heading
        self.text = text
        self.isOCR = isOCR
        self.updatedAt = updatedAt
    }
}

/// What the summary task writes into a document in one go (`DocumentRepository.setSummary`).
public struct DocumentSummary: Hashable, Sendable {
    public var title: String
    public var kind: DocumentKind
    public var summary: String
    public var keyFacts: [DocumentFact]
    public var dates: [DocumentDate]
    public var courseIDs: [Course.ID]
    /// Replaces the outline only when the document had none (sections the summary found).
    public var outline: [DocumentSection]
    public var summaryHash: String
    public var model: String
    public var apiCallID: APICall.ID?

    public init(
        title: String, kind: DocumentKind, summary: String, keyFacts: [DocumentFact], dates: [DocumentDate],
        courseIDs: [Course.ID], outline: [DocumentSection] = [], summaryHash: String, model: String, apiCallID: APICall.ID? = nil
    ) {
        self.title = title
        self.kind = kind
        self.summary = summary
        self.keyFacts = keyFacts
        self.dates = dates
        self.courseIDs = courseIDs
        self.outline = outline
        self.summaryHash = summaryHash
        self.model = model
        self.apiCallID = apiCallID
    }
}

/// What adding a file did (`DocumentRepository.add`, `DocumentBank.add`): the document, and
/// whether it is new (false: the same file was kept already, nothing was added; a toast's Undo
/// deletes only new ones).
public struct DocumentAddition: Hashable, Sendable {
    public let document: StudyDocument
    public let isNew: Bool

    public init(document: StudyDocument, isNew: Bool) {
        self.document = document
        self.isNew = isNew
    }
}

/// A deleted document as Undo needs it: the row and its pages (the chunks are rebuilt by Search;
/// the file stays in the BlobStore until the next launch).
public struct DocumentDeletion: Hashable, Sendable {
    public let document: StudyDocument
    public let pages: [StudyDocumentPage]

    public init(document: StudyDocument, pages: [StudyDocumentPage]) {
        self.document = document
        self.pages = pages
    }
}

// MARK: - Values of existing columns (v14)

extension SearchChunkKind {
    /// A window of a kept document's page (`document_id`, `page_number`). Never a `course_id`: a
    /// course delete must not cascade a document's chunks, nor a re-cut fail on a course that is
    /// gone (the document's courses are `document.course_ids`).
    public static let document: Self = "document"
}

extension AgentTaskKind {
    /// Read a kept document: one Haiku call writes its summary, kind, courses, key facts and dates
    /// (`DocumentSummarizer`, run in code by the task queue, one at a time; `agent_task.document_id`;
    /// queued by `DocumentRepository.queueSummary`).
    public static let document: Self = "document"
}

extension AgentToolGroup {
    /// search_documents, read_document: the student's documents, untrusted text (never with `web`).
    public static let documents: Self = "documents"
}

extension AgentChangeKind {
    /// A document kept from the agent panel ("keep this"); Undo deletes it.
    public static let documentAdd: Self = "document_add"
}

extension AgentChangeTarget {
    public static let document: Self = "document"
}

extension AgentContext.Screen {
    /// The Documents screen (`documentID`: the selected document).
    public static let documents: Self = "documents"
}
