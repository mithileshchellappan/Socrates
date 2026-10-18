# Notes

M6 workstream A: Apple Notes-style notes (PRD #15, #16, mockup 04, DESIGN 8.4). Text with images, sketches and slide clips inside the text flow (TextKit 2 attachments), Notes-like formatting, per slide (Review's "Your notes"), per lecture and per course on the Notes screen. Depends on StudyCore, StudyUI (navigation, chips, pins, `InkView` / `InkCanvas`) and Capture (slide pages). No automated test suite at present; verified by building and rendering (Notes and Review against mockups 04 and 03).

Workstream A also changed, outside this package: `Packages/Review` (`Package.swift`: Notes and NotesUI; `Review/SlideNotes.swift`; `ReviewUI/ReviewInspector.swift`) and `Packages/Search` (note targets and chunk text; its README).

## Status (resumable checklist)

1. [x] Notes (no SwiftUI): names, list order, All Notes grouping, list times, image import, sketch blobs, block reconcile, `NoteSession`.
2. [x] NotesUI `NoteEditor` (Mac: `NSTextView` on TextKit 2; iOS: read-only rendering).
3. [x] `NotesView` (mockup 04): list column, editor, toolbar, Slide and Quote popovers, New / Delete (Undo) / Move To.
4. [x] Review's "Your notes": rich editors (`ReviewInspector.swift`, `SlideNotes.swift`); `NoteText` removed.
5. [x] Search: notes without a slide open the Notes screen; chunk text reads chips by their labels.
6. [x] This README. Renders: `.data/parity/m6a/04-notes-{light,dark}.png`, `03-review-{light,dark}.png`.

## Entry points

| API | Module | Use |
|---|---|---|
| `NotesView(scope:selection:query:)` | NotesUI | the Notes screen for `.all` or `.course(id)`; `selection` is the window's note selection, `query` the toolbar field's text (filters the list in place) |
| `NoteEditor(session:style:startsWith:controller:professor:lectureID:trailingTime:focusRequest:startsFocused:onFocusChange:onLink:)` | NotesUI | one editable note; `.document` (Notes screen) or `.inspector` (Review) |
| `NoteEditor(note:style:professor:onLink:)` | NotesUI | one note read-only (Review's Whole lecture: the slides' notes) |
| `NoteEditorController` | NotesUI | the toolbar's and Format menu's handle on an editor: `apply(_ NoteParagraphKind)`, `toggle(_ NoteMark)`, `addLink()`, `insertImages(at:)`, `insertSketch()`, `insertSlideClip(_:)`, `insertQuote(_:)`, `focus()`; `isFocused`, `paragraphKind` |
| `NoteFormatCommands` | NotesUI | the Format menu (add to the scene's `.commands`) |
| `NoteEditorFocus.shared.editor` | NotesUI | the focused editor (what the Format menu acts on) |
| `NoteLink` (`.slide(SourceRef)`, `.time(SourceRef)`) | NotesUI | a clicked chip; `onLink` returns true when the host handled it (Review plays its own recording), else `\.openDestination` opens `.lecture(id, ReviewTarget(page:))` or `.lecture(id, ReviewTarget(time:plays: true, recordingID:))` |
| `NoteSession(note:store:)`, `NoteSession(id:store:create:)` | Notes | one open note: nothing written on open; `edited()`; saves 500 ms after the last change and on `saveNow()` / `flush()`; `discard()` before a delete |
| `NoteNames`, `NotePlace` | Notes | title, list name, preview |
| `NoteList.items(_:courses:lectures:query:)`, `.sections(_:courses:)`, `.fold(_:)`; `NoteListTime` | Notes | the list rows, All Notes' groups, folded matching; the row time |
| `NoteBlocks.block(kind:level:checked:runs:)`, `.reconcile(_:previous:)`, `.form(_:)`, `.sameContent` | Notes | the pure parts of the mapping |
| `NoteMedia` | Notes | `importImage(data:…)` / `importImage(at:…)`, `newSketch(width:)`, `storeSketch(_:blobs:)`, `drawing(of:blobs:)`, `slideClip(deck:page:lectureID:aspectRatio:)`, `slideRef`, `quote(_ segment:lectureID:)` |
| `SlideNoteEditor`, `NoteAnchor` | Notes (in Review until nl) | a slide's (or, page nil, a lecture's) notes as sessions; one new session when there are none, anchored to the playhead at the first keystroke |

## The mapping (plan §4, as built)

- One editor paragraph = one `NoteBlock`. A paragraph's format (`BlockFormat`: kind, heading level or list indent, checked, and the block it was loaded from) is an attribute on its characters and newline; after an edit every touched paragraph takes its first character's format (a merged paragraph keeps the first one's, as in Notes). Character styles are explicit attributes (bold, italic, underline, strikethrough, highlight, other marks kept as they were); the font is derived from them and the paragraph, so no font trait is ever read back.
- Runs → `NoteInline`s: text with marks, `link` (`.link` attribute; typed URLs are detected), chips (`slide_ref` "S13", `time_ref` "37:59") and inline media are attachments carrying their `NoteInline`. A professor quote, an older `.image` / `.drawing` / `.slide` block and any block kind the editor does not know (or a divider) are attachments carrying their `NoteBlock` in a paragraph of their own, written back unchanged; unknown inline kinds likewise (shown as their text, read-only).
- Media are always `NoteInline(.attachment)` inside a paragraph: images (original bytes in the BlobStore, display size = pixel size at the image's dpi, at most 680 pt wide), sketches (`InkDrawing.data()` blobs, `contentType = InkDrawing.contentType`, a new blob per change, content-addressed), slide clips (the deck's own PDF blob; the inline's `source` = deck, page and lecture; 256 pt wide).
- Lossless: a note is written only after the student changed it; a paragraph whose runs are all unstyled text keeps `inlines` nil (an M1 note re-encodes byte for byte); `text` = the runs' texts (attachments add nothing; ⇧↩ is "\n" inside `text`); a paragraph that matches the block it was loaded from (`NoteBlocks.form`) is written as that block, and the session reconciles the whole body against the stored one, so unchanged blocks keep their JSON; an unchanged body is not written. The write updates only `blocks` of the row as it is then (a Move To meanwhile is kept), through `saveOrDeleteIfBlank`; the body is read from the text only when saving (500 ms after typing stops; when the editor closes; on leaving the note). Trailing empty paragraphs are dropped on save.
- Names: the title is the first block when it is a level-1 heading; the list names a note by its title, else "DC L2 · Slide 15", else "DC L2 · " + its first line (a lecture's note), else its first line, else "New Note". The preview is the first line after what the name used. A new note on the Notes screen starts in Title, one in Review in Body.

## Style metrics

| | `.document` (Notes) | `.inspector` (Review) |
|---|---|---|
| Body | 14 pt, line 21.7 (line spacing = 21.7 − the font's line), paragraphs 9 apart | 13 pt, line 18.85, paragraphs 5 apart |
| Title / Heading / Subheading | 22 bold (−0.22 kern) / 17 semibold / 15 semibold; 4 pt above headings | 16 bold / 14 semibold / 13 semibold |
| Column | at most 680 wide, at least 52 pt from each side, centred; the stamp "18 October 2026 at 09:41" (11 pt tertiary, tabular digits, from `updatedAt`) centred 2 pt from the top, the text 27 pt down | the inspector's width; no stamp; the time chip after the last word (else on the next line) |
| Lists | 24 pt per level; bullets 5 pt (filled, hollow every other level), numbers right-aligned 6 pt before the text, checkboxes round 15 pt (1.5 pt tertiary ring; done: accent with a white check) 8 pt before the text | same |
| Attachments | radius 10, 0.5 pt separator ring, line-wide (own line), 3 pt above and below; images downsampled with ImageIO to their drawn size; sketches on the canvas surface (#f6f6f8 / #252528); slide clips with an opaque `SlideChip` 5 pt in from the top right | scaled down to the column |
| Chips | `SlideChip` / `TimeChip` (with the play glyph), one character, 3.5 pt below the baseline | same |
| List rows | name 13 semibold; time 12 medium primary (SF Mono for a clock) + preview 12 secondary; padding 7/6 in an `.inset` list; course headers dot 8 + name, subheadline semibold secondary | – |

## Keys (Format menu and the editor itself)

Title ⇧⌘T, Heading ⇧⌘H, Subheading ⇧⌘J, Body ⇧⌘B; Checklist ⇧⌘L, Bulleted List ⇧⌘7, Numbered List ⇧⌘9; Bold ⌘B, Italic ⌘I, Underline ⌘U, Strikethrough ⇧⌘X, Highlight ⇧⌘E; Add Link… ⌘K (the system link panel). ↩ continues a list (a done item's next is open) and ends it in an empty item; ↩ after a heading starts Body; Tab / ⇧Tab indent and outdent list items (else a tab); ⌫ at the start of an item outdents, then ends the list; Esc ends drawing on a sketch (never completion). The editor handles the keys itself while it has focus, so they work before the menu is added and in Review's "Your notes"; the menu's items attach their keys only while a note editor has focus (decision 161: a disabled item swallows its key, and ⇧⌘L is Mail's Flag). New Note has no key (6.8). Apple Notes' keys; none collides with menus.txt or 6.8 (Review's ⇧⌘F, ⇧⌘R, ⌘\ stay Review's).

## Requests for the integrator

Done in the M6 integration (2026-10-18): 1–7 wired in `App/` (`SidebarItem.notesRow` / `.notes(scope)`, Go ⌘4 / ⌘5, the 180 pt "Search notes" field, `.notes(scope, note:)` routing to the Notes row, `CourseNotesView` removed, `NoteFormatCommands` in the scene, `ParityMode.Launch.noteSelection` and `04-notes` on All Notes with the DC L2 note); 8: `Color.canvasBackground(_:)` and `Color.highlighter(_:)` in StudyUI (CaptureUI keeps its own canvas colour); 9: the iOS target builds. The design notes below are merged into DESIGN and decisions.

1. **Notes row** (DESIGN 6.2, 8.4): `SidebarItem.notes(NotesScope)`, a top-level row after Mail (`note.text`); while selected its children All Notes, then each course with notes (dot + name, no counts). `DetailView` shows `NotesView(scope:selection:query:)` for it and keeps it for a course's Notes screen (one screen).
2. **Go menu**: Today ⌘1, Calendar ⌘2, Mail ⌘3, Notes ⌘4, Search ⌘5 (⌘F stays Search Library).
3. **Search field** on Notes: 180 pt, prompt "Search notes", its own query passed as `query` (cleared on entering and leaving Notes, like Mail's); typing there never opens Search.
4. **Routing**: `RootView.open(.notes(.all, note:))` selects the Notes row (All Notes) with the note; `.notes(.course(id), note:)` its course child (or the course's Notes screen). Search hits of lecture and course notes now arrive as `.notes(…)`.
5. **Remove `CourseNotesView`** (CoursesUI) and 8.4's interim paragraph.
6. **Format menu**: add `NoteFormatCommands()` to the main scene's commands.
7. **Renders**: `ParityMode.Launch.noteSelection` and `04-notes` on the Notes row (All Notes) with the DC L2 note selected. Without a selection the screen opens its newest note (Apple Notes), so the shot already shows the DC L2 note.
8. **StudyUI promotions** (7.3, 7.4; I could not edit StudyUI): the canvas surface (`NoteColors.canvas` here, `liveCanvasBackground` in CaptureUI) as `Color.canvasBackground`; the highlighter (`NoteColors.highlight`, `NoteTypesetter.highlightColor`, SearchUI's `MatchInk`) as one StudyUI colour.
9. **iOS**: not built here (needs xcodebuild). The iOS paths are `NoteReadOnlyView` (read-only rendering) and the no-op controller; Review's "Your notes" are read-only on iOS.

## Design notes for the integrator

**1.2 Screen status**, Notes row: "M6: built in `Packages/Notes` (`NotesView`, `NoteEditor` on TextKit 2) and Review's "Your notes"; checked off screen against mockup 04 (`.data/parity/m6a/`); the Notes row, All Notes and the search field come with the integration; typing, paste and drop, sketch drawing and the popovers still need a look in the real window."

**1.3 Overrides** (04), add: "the Aa menu | a popover of Title, Heading, Subheading, Body in their own type, current one checked, in the first toolbar group | as Apple Notes' Aa; a toolbar Menu left the group's glass". Existing 04 rows stand (inline attachments, opaque `SlideChip`, accent done box, no table button).

**3.3** Note document: keep "text at most 680 wide, centred, 52 pt sides" (mockup 04 is drawn full width; 680 keeps 14 pt lines readable once the sidebar and the list column take their room).

**6.2** Notes (M6) row as in Requests 1.

**6.3** Notes (M6): "[New Note] | none | [Aa ⌄, checklist, image, sketch] [Slide, Quote] … [search field 180 "Search notes"]": New Note `square.and.pencil` (`.navigation`, after the course screens' ‹ ›), Aa ⌄ (popover), `checklist`, `photo` (file importer, images), `pencil` (sketch, mockup 04), then `display` "Slide" and `waveform` "Quote" with titles.

**6.6** add: "Notes: no selection → blank editor; a scope without notes → `doc.text` glyph over the whole detail (New Note stays in the toolbar); no hits → `ContentUnavailableView.search` in the list column. With nothing selected the screen opens on its newest note."

**6.8** add rows: "Format (M6; while a note editor has focus) | Title / Heading / Subheading / Body; Checklist / Bulleted List / Numbered List; Bold / Italic / Underline / Strikethrough / Highlight; Add Link… | ⇧⌘T / ⇧⌘H / ⇧⌘J / ⇧⌘B; ⇧⌘L / ⇧⌘7 / ⇧⌘9; ⌘B / ⌘I / ⌘U / ⇧⌘X / ⇧⌘E; ⌘K". In notes: ↩ continues or ends a list, Tab / ⇧Tab indent, ⌫ at an item's start outdents, Esc ends sketch drawing. In the Notes list: ⌫ deletes the note (Undo).

**7.1** (when promoted) `Color.canvasBackground`, the highlighter colour.

**7.2** add rows:
| `NotesView`, `NoteEditor`, `NoteEditorController`, `NoteFormatCommands`, `NoteLink`, `NoteEditorStyle`, `NoteParagraphKind`, `NoteMark` | NotesUI | public | the Notes screen, the rich editor (Notes, Review), its toolbar and Format menu handle |
| `NoteTextView`, `NoteEditorCoordinator`, `NoteDocumentBuilder` / `NoteDocumentReader`, `BlockFormat`, `NoteTextAttachment` + `ChipAttachment` / `MediaAttachment` / `QuoteAttachment` / `KeptAttachment`, `NoteListFragment`, `NoteSlidePicker`, `NoteQuotePicker`, `NoteStylePicker`, `NoteListRow` | NotesUI | internal | TextKit 2 editor, blocks ⇄ text, attachments with view providers, list markers, the popovers, list rows |
| `NoteSession`, `NoteNames`, `NoteList`, `NoteListTime`, `NoteBlocks`, `NoteMedia` | Notes | public | one open note and its saving; names; the list; the mapping's pure parts; media |
And 7.3: strike "Inline note attachments | 8.4 | `NoteFlowLayout` (chips only)" (built in NotesUI).

**8.1 Review**: "Inspector "This slide": Your notes are rich notes (`NoteEditor(.inspector)`): every note of the slide, or one empty editor that becomes a note on its first keystroke (audio time = the playhead then); the time chip after the last word; a chip of this lecture moves the review (slide or playback), another lecture's opens it. "Whole lecture": the lecture's own notes (page nil, editable), then each slide's notes read-only after a `SlideChip`." (replaces "at rest notes read as prose with inline checkboxes and time chips").

**8.4** (as built): Navigation and list as written. "Layout: list column 236 | `Divider` | editor (content background). List: All Notes groups under course headers (dot + name, subheadline semibold secondary, no counts), notes without a course last without a header; rows name 13 semibold, time 12 medium primary (SF Mono clock today, "Yesterday", the weekday within a week, else the day) + preview 12 secondary; system selection; context menu Move To ▸ course ▸ (the course itself, lectures) and Delete; ⌫ deletes with Undo. Document: as written; text at most 680 wide. Aa ⌄ opens a popover of the four paragraph styles. Slide: a popover of the note's lecture's slides (a course note: its course's lectures, newest first, under "L2 · Title") as thumbnails; a click inserts the slide clip at the caret. Quote: a popover with a filter field over the lecture's transcript lines (mono time + 12.5 pt line; "L2 · " before the time when several lectures show); a click inserts the professor quote as its own paragraph. New Note: an empty note in Title at the top of the list, the caret in it; the row exists from the first keystroke, in the scope's course (All Notes: the selected note's course, else none). A sketch: a click draws on it in place (`InkCanvas` with a pen / highlighter / eraser strip in glass at its bottom right, an accent ring while drawing); Esc or a click in the text ends it. Paste and drop: images (files or image data) become inline images; note text keeps its chips and media; other text pastes plain in the paragraph's format." Remove "AI suggestion at the caret" from M6 (plan §8) or mark it Later.

**decisions.md rows** (2026-10-18):
| Notes editor: `NSTextView` on TextKit 2 (Mac); one paragraph = one `NoteBlock`; the paragraph format is an attribute (`BlockFormat`) and character styles explicit attributes, the font derived; iOS renders notes read-only | Apple Notes behaviour with system text editing (undo, find, input methods, services); no font-trait guessing; M6 is Mac-only |
| Everything in a note that is not text is a TextKit 2 attachment with a view provider (chips, images, sketches, slide clips, quotes, unknown kinds kept); media are line-wide so they take their own line in the paragraph | they move, select, delete, copy and undo like characters; DESIGN 1.3 forbids floats; unknown content round-trips |
| Note titles: the first block when it is a level-1 heading; list names title, else "DC L2 · Slide 15", else "DC L2 · " + first line, else first line, else "New Note" | plan §4; one rule for the list and Search |
| A note is written only after the student changed it, 500 ms after typing stops and when its editor closes; the body is read from the text only then; unchanged blocks are written as they were (editor-equivalent form), an unchanged body not at all; only `blocks` of the current row is updated | lossless for the real library's notes; no per-keystroke encoding; a Move To during typing is kept |
| Format keys are Apple Notes' (⇧⌘T/H/J/B, ⇧⌘L/7/9, ⌘B/I/U, ⇧⌘X, ⇧⌘E, ⌘K); the editor handles them itself and the Format menu attaches them only while a note editor has focus; New Note has no key | 6.8 had none; decision 161 (disabled items swallow keys); ⇧⌘L is Mail's Flag |
| Search: a note on a slide opens Review at its slide and moment; any other note opens the Notes screen with it selected (`.notes(.course(id) or .all, note:)`); notes without a course are indexed too | lecture and course notes have no slide to open; All Notes can show any note |
| The Notes screen opens its newest note when nothing is selected | Apple Notes; mockup 04 shows the newest note open |
