# Documents UI (md, workstream B)

The screens of the document bank (docs/plan-docs.md §5.2, §6; PRD "Document bank", "Empty screens invite the next action"): the Documents screen (`DocumentsUI`), Search's Documents group (`SearchUI`), the agent panel's Documents prompts and `[[doc …]]` chips (`ChatUI`), and window drops of documents with their toast (`FilingUI`). No mockup exists: plan §6 is the spec. The bank itself (reading, the summary task, search chunks, the agent's tools) is workstream A's (`Documents`, `Search`, `AppAgent`).

## Entry points

```swift
// DocumentsUI
public struct DocumentsView: View {
    public init(selection: Binding<StudyDocument.ID?>, page: Int? = nil, launch: DocumentsLaunch = DocumentsLaunch())
}
public struct DocumentActions: Sendable                      // \.documentActions (landed): isEditable, add, delete, restore, retry; .readOnly default
public struct DocumentsLaunch: Hashable, Sendable            // renders: now (added days, dates' years), isDropTargeted (the ring)
public struct DocumentsImportAction                          // FocusedValues.documentsImport: File ▸ Import… while Documents shows
// FilingUI
@MainActor @Observable public final class DocumentDropHandler {
    public init(add: @escaping @MainActor @Sendable ([URL]) async throws -> [StudyDocument.ID],   // only the NEW ids (isNew)
                undo: @escaping @MainActor @Sendable ([StudyDocument.ID]) async -> Void)
    public nonisolated static func takes(_ url: URL) -> Bool   // Word, ODT, RTF, Pages, text, Markdown, images (never PDF, .ics)
    public func preview(fileNames: [String], failure: String? = nil)  // renders: a toast without adding
}
public final class FilingCenter { public var documents: DocumentDropHandler? }  // set by the app
```

## What it draws (plan §6, as built)

- **Layout**: list column 260 | `Divider` | the reader on the content background. Toolbar: `.screenTitle("Documents")` (no subtitle) and [Import…] (`square.and.arrow.down`, help "Import…") in its own glass at the trailing end, only while editable (the Mac). No search field.
- **List** (`.inset`, system selection, newest first by `added_at`, no separators, rows padded 7/6 like Notes): line 1 the title 13 semibold (one line) … the added day trailing in SF Mono 11.5 tertiary ("19 Oct"; another year "19 Oct 2025"); line 2 the kind 12 medium primary ("Handbook", "Regulations", "CV", "Transcript", "Certificate", "Letter", "Document") then ONE sparkle and the summary 12 secondary (one line). Summary pending (or the text still being read): the kind and a redacted line (skeleton, no shimmer). Reading or the summary failed: the kind and a secondary `exclamationmark.triangle` with the reason as `.help`. Context menu: Quick Look, Read Again (only after a failure), Delete. ⌫ deletes, Space toggles Quick Look. With nothing selected (or a selected document that is gone) the newest opens.
- **Reader** (at most 680 wide, centred, 52 from each side, 26 from the top; Notes' measures): the title `.title.bold()` (22, primary: a name, selectable); the facts line 12 secondary with the digits in SF Mono ("Handbook · PDF · 6 pages · Added Mon 19 Oct"; no pages for an image; "Added Sun 19 Oct 2025" from another year); the related courses (dot 8 + short name, 12 secondary, one line; absent when none; in the sidebar's course order). Then the file as one tile (card surface, radius 10, 0.5 separator ring, padding 8): the first page's thumbnail 64 high (`QLThumbnailGenerator`, radius 6 + hairline; a quiet-fill page with the file's glyph until or without one), the file name 13 medium (middle-truncated) over "PDF · 2.4 MB" 12 secondary (binary units); a click opens Quick Look (help "Quick Look"). Then the AI blocks, 18 apart, each a section label (subheadline semibold secondary) with ONE sparkle at its first line and grey 13 pt text: **Summary**; **Key facts** (rows; "p. 12" trailing in tertiary SF Mono 11; a click opens Quick Look); **Dates** (rows: the day in SF Mono 12 secondary, "Mon 1 Feb", a range "14 Dec – 8 Jan" / "28 Dec–8 Jan", ", 10:15" when the document states a time, the year only outside the half year behind and the year ahead; then what; then "p. 3"). A block without content is absent. Pending: Summary as a 3-line skeleton, no other blocks. Failed: one secondary line, the triangle and the reason, then [Read Again] (bordered, small; only while editable).
- **The page** a search hit or chip names (`DocumentsView(page:)`): the key facts and dates on that page sit on the quiet fill (neutral, like a selected search hit) while that document is the one it opened with. Quick Look opens at the file's start (jumping to a page is not in md, plan §8).
- **Quick Look**: `.quickLookPreview` on a symbolic link named as the student's file (so the panel's title is "Modulhandbuch_Inf_MSc_WS2627.pdf", not the blob's hash) in a temporary folder of its own, removed when the panel closes; the blob is never touched.
- **Drop and Import…**: the whole screen (list and reader) is a drop target for `StudyDocument.acceptedTypes` (PDFs too: on this screen a PDF is a document); the reader shows the accent ring (accent soft + 1.5 pt accent, radius 12, 12 in: `EmptyDropPrompt`'s) only while such files hover; a drag with none of them is refused, so the window's smart import keeps it. Mixed drops: the documents go to the bank, the rest to smart import. Import… opens a multiple-file importer on the same types. The first new (or already kept) document is selected at once; new rows appear at the top. A failure to add (e.g. "This file is larger than 200 MB.") shows the app's one alert "Couldn’t finish" with the bank's sentence.
- **Delete**: no confirmation (as Notes); the next document is selected; Edit ▸ Undo "Delete Document" restores it (the bank re-reads and re-queues what the delete stopped) and selects it; Redo deletes it again.
- **Empty**: `EmptyDropPrompt` (`doc.on.doc`, "Drop your documents here.", the filled Import…) over the whole detail; its Import… and drops are routed to the bank by overriding `\.importFiles` around it (files that are not documents still go to the window's smart import). It rings only while a document is among the dragged files (`EmptyDropPrompt(…, accepts: DocumentFileTypes.isAccepted)`); only accepted files are added. The toolbar's Import… shows only once the list has a document (one Import… on the empty screen).
- **Agent**: `.agentContext(AgentContext(screen: .documents, documentID: <the selected document>))`. ChatUI's prompt: "Ask about this document" / "Ask about your documents".
- **iOS**: compiles read-only (`DocumentActions.readOnly`: no Import…, no drop, no Delete or Read Again); the phone never shows it.

**Search** (SearchUI): a Documents group (header `doc.on.doc` + "Documents"; collapsed it shows its best hit's label like Notes and Mail); rows use the hit row with a secondary `doc.on.doc` glyph (12), the top line "Modulhandbuch M.Sc. Informatik · p. 3", the highlighted snippet; ↩, a double click and Open go to `.documents(id, page:)` (`SearchHit.destination`, landed); no Play. Documents are never agent sources (`chatSource` nil, and the default selection skips them like mail). The engine decides the group's place (A: after "Your notes", before Web).

**Chat** (ChatUI): `[[doc 3f2a9c1e p12]]` / `[[doc 3f2a9c1e]]` become chips only after `DocumentCitations.check`: the key names exactly one `document` row and the page is within its `page_count` (else dropped and logged: `document_unknown`, `document_ambiguous`, `document_page_outside`). The chip is web's shape with `doc.on.doc` for the globe, secondary on the quiet fill: "p. 12", or without a page the title clipped to 24 ("Modulhandbuch M.Sc. Inf…"); its help is the title (set on the run of text that holds it: a chip is a run of one `Text`); a click opens `.documents(id, page:)` (link `studyportal-cite://doc/<id>/<page|->`). Copy writes the label. The paperclip offers Word, ODT, RTF and Pages too (`.document` attachments; their tiles `doc.richtext` + size, as landed). On the iPhone documents never sync, so every document marker is dropped there.

**Window drops** (FilingUI): `FilingCenter.dropped(urls:)` hands Word, ODT, RTF, Pages, plain text, Markdown and image files to `documents?.take(_:)` (PDFs and `.ics` stay with smart import; so do they when `documents` is nil); the rest is filed as before. One toast per drop in the window's toast stack, above the filed toasts, in a filed toast's shape: the 38 pt tile with `doc.on.doc`, "Added to Documents" (body semibold) over the file names (callout secondary, middle-truncated), [↶ Undo] (`FilingSmallButtonStyle`; only when the drop added something new: Undo deletes only those, never a file kept before); it leaves after 8 s, not while hovered. A drop the bank refused: the triangle, the file names over the bank's sentence, × on hover. Smart import predicts nothing for these files (no evidence kind), so while only they are dragged the HUD stays away; no change to the HUD was needed.

## Checklist (md B; resume from the first open box)

- [x] 1. DocumentsUI: `DocumentsView.swift` (screen, list, toolbar, drop, importer, Quick Look, Delete with Undo, empty state, agent context, `DocumentsLaunch`, `DocumentsImportAction`), `DocumentRow.swift`, `DocumentReader.swift` (reader, file tile, blocks), `DocumentDropTarget.swift`, `DocumentFiles.swift` (thumbnails, Quick Look links), `DocumentText.swift` (kinds, types, days, ranges, mono digits).
- [x] 2. SearchUI: the Documents group header, document rows and labels, documents out of the default selection and the agent's sources.
- [x] 3. ChatUI: `DocumentCitations.swift`; `ChatCitations.swift` checks `.document` through it (rows, case, label, style, link, destination, renderer); the prompts; the chip's help (`AnswerMarkdown.swift`, one line); the paperclip's types.
- [x] 4. FilingUI: `DocumentDrop.swift` (`DocumentDropHandler`, its toasts); `FilingCenter.documents` + the branch in `dropped(urls:)`; one line in `FilingToastStack`.
- [x] 5. Courses: skipped in md (plan §5.2).
- [x] 6. This README.
- [x] Builds: `taskpolicy -b swift build -j 4 --package-path Packages/Documents` (macOS); Search (`Search`, `SearchUI`), ChatUI and Filing (`Filing`, `FilingUI`) in one `taskpolicy -b swift build -j 4` of a git-ignored scratch package depending on all three (`.build/md-b-check`, so the shared dependencies compiled once); `DocumentsUI` with `xcodebuild -scheme DocumentsUI -destination 'generic/platform=iOS Simulator' … -jobs 4 ARCHS=arm64` (BUILD SUCCEEDED). No warnings in the changed targets. Not rendered: the app routes are the integrator's (request 7).

## Requests for the integrator

1. **Sidebar**: `SidebarItem.documents` after `.notesRow` in `destinations` (Go: Notes ⌘4, Documents ⌘5, Study ⌘6, Search ⌘7, Search keeps ⌘F); its row in `SidebarView` with `SidebarRowLabel("Documents", systemImage: "doc.on.doc")`, no children, no badge (keep the fix agent's course expansion behaviour, e07dc97). Not on the iPhone.
2. **Routing**: `DetailView` → `DocumentsView(selection: $documentSelection, page: documentPage)` (Mac); `RootView.open(.documents(id, page:))` selects the row and sets `documentSelection = id` (nil: keep the screen's own; it opens the newest) and `documentPage = page` (set it back to nil when another destination opens). PhoneRootView keeps ignoring `.documents`.
3. **`\.documentActions`** on the main window (Mac), over A's bank:
   ```swift
   DocumentActions(
       isEditable: true,
       add: { urls in try await bank.add(urls, by: .user).map(\.document.id) },    // every file's document, a kept one's too
       delete: { id in try await bank.delete(id) },
       restore: { deletion in try await bank.restore(deletion) },
       retry: { id in await bank.retry(id) }
   )
   ```
4. **Window drops**: `filingCenter.documents = DocumentDropHandler(add: { urls in try await bank.add(urls, by: .user).filter(\.isNew).map(\.document.id) }, undo: { ids in for id in ids { _ = try? await bank.delete(id) } })`. (Undo of a toast deletes without its own Edit ▸ Undo entry, as a filed toast's Undo.)
5. **File ▸ Import… while Documents shows**: FilingUI's `ImportCommands` cannot see DocumentsUI. Either give the app its own Import command that prefers the focused value, e.g.
   ```swift
   struct AppImportCommands: Commands {
       let center: FilingCenter
       @FocusedValue(\.documentsImport) private var documentsImport
       var body: some Commands {
           CommandGroup(after: .newItem) {
               Button("Import…") { if let documentsImport { documentsImport() } else { center.importFiles() } }
                   .keyboardShortcut("i", modifiers: [.command, .shift])
           }
       }
   }
   ```
   in place of `ImportCommands(center:)`, or tell me to add a generic hook to `ImportCommands`. Today's ⋯ ▸ Import… stays smart import.
6. **Agent context**: the app's guess for the Documents screen is `AgentContext(screen: .documents)`; the screen's publication (`documentID`) is merged over it. The exchange's faint context line (A): "Documents" with `doc.on.doc`.
7. **ParityMode** (`ParityMode.Launch`): `documentSelection: StudyDocument.ID?` (by title, e.g. "Modulhandbuch M.Sc. Informatik", "Curriculum Vitae", "Pruefungsamt_Hinweis_Anmeldung"), `documentPage: Int?`, and `DocumentsLaunch(now: <--now>)`; routes `md-documents` (Modulhandbuch), `md-documents-cv`, `md-documents-pending` (the letter), `md-documents-empty` (a library without documents), `md-search` (`search?q=Prüfung`), light and dark, `--now 2026-10-19T10:40`, on a copy of `.data/parity/docs/library`. Optional: `md-documents-drop` (`DocumentsLaunch(isDropTargeted: true)`) and a window toast via `filingCenter.documents?.preview(fileNames: ["CV_Alex_Example.docx"])`.
8. **Done (audit fixes)**: `EmptyDropPrompt` and `importDropTarget` take `accepts: (@Sendable (URL) -> Bool)?` (StudyUI; the ring shows only while an accepted file is dragged, drops still go whole to `\.importFiles`); the empty Documents screen passes `DocumentFileTypes.isAccepted`.

## Design notes for the integrator (DESIGN rows, as built)

- **1.2 Screen status**: add "Documents (md) | – (plan-docs §6) | built in `Packages/Documents` (`DocumentsUI`, 8.8) and wired to the `DocumentBank` (Mac only; documents never sync, the iPhone has no Documents); Search's Documents group; the agent panel's `[[doc …]]` chips; window drops of Word, RTF, Pages, text and images with the "Added to Documents" toast. Checked off screen (`md-documents*`, `md-search`, `.data/parity/docs/`); Quick Look, drop, ⌫ and Undo, Read Again and the toast's Undo still need a look in the real window."
- **6.2 Sidebar**: base order "Today, Calendar, Mail, Notes, Documents, Study, Search" (Documents `doc.on.doc` since md; no children, no badge; Mac only).
- **6.3 Toolbar** row: "Documents (md) | – | "Documents" | [Import…] (`square.and.arrow.down`) in its own glass; no search field".
- **6.6 Empty** row: "Documents `doc.on.doc` "Drop your documents here." + Import… (the drop and Import… go to the bank; other files to smart import)". Loading row: a document whose summary is pending is a skeleton (the list's second line, the reader's 3-line Summary). Failed row: the list's secondary triangle with the reason as help; the reader's line with [Read Again].
- **6.8 Keys**: Go ▸ Documents ⌘5 (Study ⌘6, Search ⌘7; Search keeps ⌘F); in the Documents list ⌫ deletes, Space toggles Quick Look; Edit ▸ Undo Delete Document; File ▸ Import… (⇧⌘I) opens the Documents importer while Documents shows.
- **3.5 Icons**: "Documents (md) | `doc.on.doc` (the sidebar row, Search's group and hit glyph, the `[[doc …]]` chip, the empty state, the toast's tile); Import… `square.and.arrow.down`; a Word, RTF or Pages attachment tile `doc.richtext`. Never notes' `doc.text`."
- **8.8 Documents** (new; from plan §6 and "What it draws" above): Navigation, Layout, List, Reader, the page, Quick Look, Drop and Import…, Delete, Empty, Agent, iOS, Search and chips, window drops.
- **8.6 The agent panel**: prompts "Ask about this document" / "Ask about your documents"; checked chips add a kept document (`doc.on.doc` + "p. 12", or the title clipped to 24; help the title; opens Documents at the page).
- **9 Strings (md)**: "Documents", "Import…", "Drop your documents here.", "Quick Look", "Read Again", "Delete", "Delete Document" (Edit ▸ Undo), "Added to Documents", "Summary", "Key facts", "Dates", "Added Mon 19 Oct", "6 pages" / "1 page", "p. 12", "PDF · 2.4 MB", the kinds "Handbook", "Regulations", "CV", "Transcript", "Certificate", "Letter", "Document", the file types "PDF", "Word", "OpenDocument", "RTF", "Pages", "Markdown", "Text", "PNG", "Ask about this document", "Ask about your documents", the fallback "This file could not be read." (a failed row without the bank's sentence) and "This file could not be added." (an add without one), and the bank's readable failures (plan §4).
- **decisions rows**: "The Documents screen writes only through `DocumentActions` (the app's closures over `DocumentBank`); its rows come from `@FetchAll`." / "On the Documents screen a PDF is a document; on any other screen a dropped PDF is slides (smart import). Word, RTF, Pages, text and images dropped on the window go to the bank with an 'Added to Documents' toast whose Undo deletes only what the drop added." / "Deleting a document asks nothing; Edit ▸ Undo restores it (as Notes)." / "A `[[doc …]]` chip shows only when its key names exactly one kept document and its page is one of that document's pages; its help is the title." / "Documents are never the agent's sources from Search (like mail): the agent reads them with its own tools, as untrusted data." / "Quick Look opens a document through a temporary link named as the student's file, removed when the panel closes."
