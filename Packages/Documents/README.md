# Documents

Milestone md, the document bank ([docs/plan-docs.md](../../docs/plan-docs.md); PRD "Document bank"). Two products: `Documents` (logic, workstream A: this part) and `DocumentsUI` (the screen, workstream B). No tests: verification is that it builds; the integrator's one live check is plan §7.4.

## Documents (logic, workstream A)

Depends on StudyCore and ClaudeKit. No SwiftUI. PDFKit, Vision and (Mac only, Word/RTF) AppKit are `internal import`s, so none of them is in the module's interface (as Capture's `DeckText`); nothing here draws.

### Checklist (resumable after a usage limit)

- [x] 1. `DocumentExtractor`, `DocumentBank`, `DocumentSummarizer` (commit "md A step 1").
- [x] 2. Search: document chunks, the semantic unit, the engine's Documents group (Packages/Search, "md A step 2").
- [x] 3. AppAgent: catalog, tools, context, attachments, the queue's runner (Packages/AppAgent, "md A step 3").
- [x] 4. This README and AppAgent's "md" section ("md A step 4").
- [x] Built: `taskpolicy -b swift build -j 4` of Documents, Search and AppAgent; the `Documents` scheme for `generic/platform=iOS Simulator`.

### Entry points

```swift
public actor DocumentBank {
    public init(services: StudyServices, now: @escaping @Sendable () -> Date = { Date() })
    public static let summaryModel, summaryEffort             // claude-haiku-5-5, low (agent_task.model / .effort)
    public static let resumeDelay: Duration = .seconds(20), cleanupDelay: Duration = .seconds(60)
    public func start()                                       // returns at once (see "Launch")
    public func stop()                                        // the app quits (optional)
    public func add(_ urls: [URL], by: Author = .user) async throws -> [DocumentAddition]   // drop, Import…
    public func add(attachment: AgentAttachment, by: Author = .agent) async throws -> DocumentAddition   // keep_document
    public func delete(_ id: StudyDocument.ID) async throws -> DocumentDeletion?
    public func restore(_ deletion: DocumentDeletion) async throws                          // Undo
    public func retry(_ id: StudyDocument.ID) async                                         // Read Again
}
public enum DocumentExtractor {
    public static func extract(fileAt: URL, type: UTType) async throws -> ExtractedDocument   // throws DocumentReadError
    public static func leadingText(ofPDFAt: URL, characters: Int) async -> (text: String, pageCount: Int)?   // the panel's long PDFs
}
public struct DocumentSummarizer {                            // run by AppAgent's queue for a `document` task
    public init(services: StudyServices, client: ClaudeClient, now: …)
    public func run(documentID: StudyDocument.ID) async -> Outcome   // .done(title:) / .waiting(until:) / .failed(sentence)
    public static let purpose = "documents.summary", promptVersion = 1, model = .haiku55, effort = .low,
                      maxTokens = 4_000, inputCharacters = 40_000
}
public struct DocumentReadError { public var sentence: String }   // one readable sentence (DESIGN 9 strings below)
public enum DocumentXML { public static func escape(_:) -> String }
```

### States of a document

| `text_state` | `summary_state` | What runs | The screen / the catalog |
|---|---|---|---|
| pending | pending | the bank's reader (serial, `.utility`); a quit leaves it, `start()` resumes it | skeleton / "· reading" |
| done | pending | the `document` task (`queueSummary` → AppAgent's queue, one at a time, only with Claude Code; paused on a usage limit) | skeleton / "· reading" |
| done | done | nothing (`summary_hash` = text SHA-256 + prompt version: never summarised twice) | summary, facts, dates |
| failed | skipped | nothing; Read Again (`retry`) reads it again | the reason (`error`) / "· unreadable" |
| done | failed | nothing; Read Again queues the summary again | the reason / "· not summarised" |

### Rules in code (plan §4)

- **Adding**: only `StudyDocument.acceptedTypes`, ≤ 200 MB; security-scoped access for dropped and imported URLs; the file is copied (never moved) into the BlobStore off the actor; a Pages package (a folder) is kept as the single-file Pages format (a zip of its contents, `ditto`). `DocumentRepository.add` checks the hash and inserts in one write transaction (`isNew` false: the document already kept, nothing added). Title = the file name without its extension until the summary names it; `created_by` user (drop, Import…) or agent (keep_document). Reading starts at once.
- **Text** (`DocumentExtractor`, a detached task at `.utility`, one page in memory at a time): PDF text per page (PDFKit); a page with fewer than 40 letters is rendered grey at ≤ 2,000 px (its `/Rotate` applied) and read by Vision (`RecognizeTextRequest`, accurate, de-DE + en-US, language correction; lines top to bottom); the PDF outline (≤ 300 entries, levels 1–4). Word .docx/.doc, ODT, RTF (Mac): `NSAttributedString` document types, cut into parts of ≤ 4,000 characters at paragraph ends (sentence ends for a longer paragraph); a short paragraph set ≥ 14 pt or bold is a heading. Pages (Mac): `QuickLook/Preview.pdf` in the package or the zip (`/usr/bin/unzip`), else "This Pages file has no preview to read. Export it as PDF in Pages and add that." Text and Markdown: UTF-8, else Latin-1; `#` lines are headings. Images: Vision OCR, one page (≤ 2,000 px). A page's heading: its outline entry, else "§ 7 …", "4.2 Prüfungen", a Markdown heading or a short line before a blank line. Language: `NLLanguageRecognizer` on the first 6,000 characters. No text at all: "No text found in this file." The iPhone refuses Word/RTF/Pages ("Word, RTF and Pages files are read on the Mac."). Errors from PDFKit, Vision or AppKit go to the log privately; the row gets the sentence.
- **Summary** (`DocumentSummarizer`, one document per call): the courses as tokens (c1…), then `<document file= type= pages=>` with `<outline>` and `<page n=>` (all escaped). Over 40,000 characters: the outline (≤ 5,000), pages 1–6, then the pages with the most date mentions × 2 + rule words (§, LP, ECTS, credits, Prüfung, exam), each ≤ 6,000, in page order, with `excerpt="…"` on the element. Checks: unknown kind → other; unknown course tokens dropped; pages outside the document dropped (a fact keeps its text); a date is kept only when its page mentions that day (numeric "1.2.", "01.02.2027", "1. Februar", "February 1", "1. bis 12. Februar", ISO), else the first page that does becomes its page, else it is dropped; an end date only after the day and mentioned; times only HH:MM; facts with an e-mail address or a run of ≥ 7 digits dropped; lengths clipped (title 60, summary 400, fact 160, what 100, ≤ 8 facts, ≤ 12 dates, ≤ 24 sections only when the PDF had no outline). Skips the call when `summary_hash` matches. A usage limit or Claude Code trouble → `waiting(until:)`; a failed call, an answer cut at `maxTokens` or JSON not of the schema → `setSummaryFailed("The summary could not be written.")`; a document gone → done without a call; a run cancelled meanwhile (`Task.isCancelled`: the task's row cancelled, the app quitting) writes nothing.
- **Deleting**: `delete` cancels the open `document` tasks through `AgentTaskRepository.cancel` (AppAgent's queue then stops a running summary: `stopCancelled`), then `DocumentRepository.delete` (pages and chunks cascade), then puts the file on the pending list (`<library>/DocumentBank/pending-removals.json`, hash + path + time of the delete). `restore` writes the rows back, takes the file off the list, reads a text still pending and calls `queueSummary`. `retry` cancels an open task, `resetSummary`, then reads again (text failed) or `queueSummary`.
- **Launch**: `start()` returns at once. After `resumeDelay` (`.utility`): `waitingForText` into the reader, `queueSummary` for `waitingForSummary`. After `cleanupDelay` (`.background`): the listed files deleted before this launch whose hash `BlobUsage.isUsed` finds in no row are removed; files of documents deleted in this session stay listed (Undo). The list's read-modify-writes hold one process-wide lock (the agent's Undo of keep_document uses a bank of its own).
- **Logs**: never a document's text, title or file name at `.public` (counts, kinds and durations only).

### Requests for the integrator (plan §7.2)

- `project.yml`: package `Packages/Documents`; the Mac app links `Documents` and `DocumentsUI`. AppAgent now depends on Documents (its Package.swift), so the iOS app gets `Documents` through AppAgent's graph only if it links AppAgent; `Documents` compiles for iOS.
- `AppModel` (Mac only): one `let bank = DocumentBank(services: services)`, `await bank.start()` after the database opens (it returns at once; nothing runs for 20 s), `bank.stop()` at quit (optional). Pass it to `AppAgent.specs(…, documents: bank)` and `AppAgent(…, documents: bank)`.
- `\.documentActions` from the bank: `add: { try await bank.add($0).map(\.document.id) }`, `delete: { try await bank.delete($0) }`, `restore: { try await bank.restore($0) }`, `retry: { await bank.retry($0) }`, `isEditable: true`.
- `FilingCenter.documents` (B's `DocumentDropHandler`): `add` = `bank.add(urls)` keeping only `isNew` ids; `undo` = `bank.delete` for each.
- `api_call.purpose = documents.summary` (`DocumentSummarizer.purpose`) is new: add it wherever purposes are listed (usage screen, docs/modules.md).
- The live check (plan §7.4): `DocumentSummarizer(services:client:).run(documentID:)` once on the seeded letter (`Pruefungsamt_Hinweis_Anmeldung.pdf` in `.data/parity/docs/library`); its date line, a range written out in German, passes the date check as one range.
- Sync: nothing to do (`Schema.macOnlyTableNames`). `agent_task` rows of kind `document` do sync (their title has the file name); the phone never runs them (AppAgent is Mac only).

### Design notes for the integrator (decisions rows, DESIGN 9 strings)

- decisions: "The document bank keeps the student's files in the BlobStore and their text per page (`document_page`): a PDF's pages, an image's one page, flowing text (Word, RTF, text) in parts of ≤ 4,000 characters at paragraph ends."
- decisions: "Pages files are read through their QuickLook preview PDF; without one the document fails with a sentence asking for a PDF export (no iWork parser)."
- decisions: "Word, ODT and RTF are read with AppKit's `NSAttributedString` document types inside Documents (an `internal import AppKit`, Mac only): a logic package's one AppKit use, for reading, never drawing."
- decisions: "One Haiku call (effort low, ≤ 4,000 output tokens) per document, never a batch, ≤ 40,000 characters of its text picked by code; one `document` task at a time, only with Claude Code; `summary_hash` keeps a text from being summarised twice."
- decisions: "Document text never sits beside web tools (the read tools read untrusted content; `material` never includes documents; a task never gets `documents` with `web`)."
- decisions: "A deleted document's file is removed at a later launch (after 60 s, background) when `BlobUsage` finds no row using it; Undo within the session always finds it."
- DESIGN 9 strings (logic): "No text found in this file.", "This file could not be read.", "The file is no longer there.", "This file is larger than 200 MB.", "This kind of file can’t be kept in Documents.", "This PDF is locked with a password. Remove the password and add it again.", "This Pages file has no preview to read. Export it as PDF in Pages and add that.", "Word, RTF and Pages files are read on the Mac.", "The summary could not be written.", "Added to Documents" (keep_document's change).
