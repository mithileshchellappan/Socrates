# Review

The lecture review screen (PRD #14, mockup 03) with one playback clock, per-slide notes (#15) and
manual "slide starts here" anchors (#9). Milestone 1, workstream C.

| Product | Contents | Imports |
|---|---|---|
| `Review` | `LecturePlayer`, `LectureComposition`, `SlideTimeline`, `ReviewSession` (follow + navigation), `SlideNoteEditor` (on Notes' `NoteSession` since M6; moved to `Notes` in nl), `AnchorEditor`, `ReviewProgressTracker` / `ReviewStateKeeper`; M4: `StudyItems`, `StudyEdits`, `SlideTextLocator`, `ScrubberMoments`; M6: `SlideInkEditor`, `StudyEdits.addFlag` / `deleteFlag` | StudyCore, Capture, Notes (M6), AVFoundation, PDFKit (internal). No SwiftUI |
| `ReviewUI` | `LectureReviewView`, `ReviewCommands`, `ReviewActions` (focused value); M5: `ReviewInspectorTab`, `\.reviewInspectorTab`; M6: the ink layer, the toolbar's ink group and its keys (no new public API besides `ReviewActions`' ink fields) | Review, StudyUI, Capture + CaptureUI, ChatUI (M5: the Tutor tab), SwiftUI; AppKit/UIKit only for the large slide's backing-store view |

No automated test suite at present; verified by building and rendering.

## Wiring (app)

```swift
LectureReviewView(lectureID: id, target: target) { lectureID, recordingID in
    try await Realigner(services: services).realign(lectureID: lectureID, recordingID: recordingID)
}
.environment(\.studyServices, services)   // writes, blobs, slide cache folder

WindowGroup { … }.commands { ReviewCommands() }
```

The screen reads with SQLiteData fetches on `services.database` (and the lecture's recordings and
deck link on the default database, which the app already points at the same database).

## How it works

- **One clock.** `LectureComposition` puts every `RecordingSegment` file on one
  `AVMutableComposition` audio track at `startSample / sampleRate`; gaps (input switches,
  interruptions) are empty edits and play as silence. `LecturePlayer` (`@MainActor @Observable`)
  plays it with `AVPlayer`, seeks with zero tolerance, steps ±15 s, plays at 1 / 1.25 / 1.5 / 2×
  (time-domain pitch). While playing a 100 ms task publishes `time`; `currentSegmentID` and
  `currentPage` are assigned only when they change, so only the time label and scrubber redraw ten
  times a second. On iOS it activates the `.playback` / `.spokenAudio` session on play.
- **Timeline.** `SlideTimeline` is the recording's timed `lecture_deck_span` rows: page at a time
  (the span starting at or before it), `displayPage` (an off-slide stretch keeps the slide before
  it on screen), first visit and all visits of a page, off-slide stretches, scrubber ticks where
  the slide changes, and transcript sections by line midpoint (as `LectureOutline`).
- **Follow.** `ReviewSession.shownPage` is the player's page while following, else the page picked
  by hand. ←/→, the toolbar, a thumbnail or the scrubber turn Follow off and pause (a thumbnail
  also seeks to the slide's first visit); a transcript line or time chip plays from there with
  Follow on; turning Follow on re-syncs. On the Mac ← / → and Page Up / Page Down reach the slides
  through the screen's own key monitor (`ReviewSlideKeys`, `ReviewKeys.swift`): it reads the
  window's first responder as each key comes and leaves the keys to editable text (a note, the
  agent panel's composer, the search field); a click on the slide, rail, transcript or player ends
  typing there (`endsTypingOnClick`), and a note editor that goes away with the caret clears
  `isEditingText`. Opening: the target time wins for the player and the
  target page for the slide; else `reviewPosition`; else the start.
- **Notes.** `SlideNoteEditor` edits every note anchored to the slide (live quick notes included)
  or one empty draft that becomes a note on its first keystroke, with `recordingID` and
  `audioTime` = the playhead at that keystroke. `- [ ] ` / `- [x] ` lines are checklist blocks,
  other lines paragraphs; unchanged lines keep their block and edited lines keep the block's other
  fields. Notes with rich runs, attachments or other block types are shown, never rewritten.
  Saves go through `NoteRepository.saveOrDeleteIfBlank` 0.5 s after typing stops, one write at a
  time, and on leaving the slide. Without a deck, notes anchor to the lecture (`page` nil).
- **Anchors.** "Slide N Starts Here" / "Not on Slides From Here" (line context menu, or ⌘\ at the
  playhead with the slide on screen) call `RecordingRepository.setManualAnchor`, then `realign`;
  "Remove Marker" deletes the line's manual `slide_event` rows, then `realign`. The spans come back
  through observation; a section starting at a manual marker shows a tick on its divider.
- **Review state.** `ReviewStateKeeper` saves `reviewPosition` every 10 s while playing and when the
  screen closes, and sets `reviewedAt` once playback passes 90 % of the recording or reaches the
  last discussed slide (once per opening, never after Mark as Reviewed was toggled by hand).
- **Screen.** Rail of 320 px thumbnails (CaptureUI `SlideImageView`, pencil when the slide has
  notes), the 2048 px slide (`SlideBitmapView`, prefetching ±2), the transcript in a lazy list with
  `Slide 16 36:57–38:28` dividers, a floating glass player, and the inspector (This slide | Whole
  lecture). No deck: no rail and no slide, notes on the lecture. No recording: no player and no
  transcript. No transcript yet: the transcription job's determinate progress.
- **Window layout (mockup 03).** The toolbar title is the screen's own item (title 3 semibold over
  the course and day; `.toolbar(removing: .title)`, the navigation title stays for the Window
  menu). macOS 26 lays the toolbar out as one row with no section over the inspector, so the
  inspector's header (segmented This slide | Whole lecture on a glass track, Hide Inspector) is one
  toolbar item as wide as the inspector column, declared only while the inspector is shown (a
  hidden inspector's content stays alive, and its item would stay in the toolbar); Show Inspector
  appears in the main toolbar only while it is hidden. This needs the window's toolbar search field to be absent on this screen
  (the app shell attaches it on Today and Search only); with it, the header sits beside the
  stepper. The rail and transcript end 8 pt above the floating player (nothing scrolls under or
  below it) and fade out over their last 14 pt; the transcript is clipped to its frame, 6 pt under
  the slide.
- **Student's layout** (`ReviewLayout`, `ReviewContent`, `PaneDivider`). The 6 pt under the slide
  is a divider (row-resize pointer) that resizes the transcript and collapses it when dragged past
  half its 120 pt minimum; the 10 pt after the rail is its edge, which collapses the rail. A
  double-click toggles either; View ▸ Hide Thumbnails (⌥⌘1) and Hide Transcript (⌥⌘2) too. One
  `@AppStorage("review.layout")` string ("0.5,0,0": slide share, transcript, rail) for every
  lecture; a drag writes it once, at the end. A collapsed transcript stays in the hierarchy at no
  height, so its cues and scroll position survive; the player stays. A collapsed pane's edge
  draws a small grabber (36 × 4 pt tertiary capsule) so it can be found and dragged back.

## The study pass on this screen (M4)

As in mockup 03. Review only reads and writes
StudyCore rows; the pass itself is `Packages/StudyPass`.

- **Reading.** Every surface reads the lecture's `annotation` rows that are not hidden
  (`FetchAll.studyItems(of:)`, `hidden_at IS NULL`) through `StudyItems` (Review): slide and lecture
  summaries, exam hints, professor items (exam hints + highlights), said in class (by
  `SaidInClassCategory.displayOrder`), further reading, the student's pins. Patches come with the
  transcript lines. Blocks appear when their rows land: no skeleton, no copy while the pass waits.
- **Inspector.** This slide: Summary (sparkle, grey 12.5 with one `TimeChip`), Your notes, Further
  reading (≤ 2 `FurtherReadingRow`s; a click opens the URL), a hairline, then the lecture-wide Exam
  hints (amber star; 16 pt professor pin + “quote” + chip) and Only said in class, 3 rows each in
  time order, then "Show N more". Whole lecture: the lecture's summary, every exam hint, said in
  class under Admin / Deadlines / Questions / Examples / Explanations, every further reading with a
  `SlideChip`, notes by slide. Rows have Hide in their context menu.
- **Pins** (`SlidePins`, StudyUI `AnnotationPin` + `PinCard`): an overlay in the slide's frame
  over the bitmap (never re-rendered). A professor pin sits 8 pt after the end of the line its
  `anchor_text` ends on (`SlideTextLocator`: PDFKit on the deck's PDF, whitespace, case, quotes,
  dashes and ligatures folded, cached per page and text), else in the top-right stack under the
  one AI pin (when the slide has further reading); at most 3 professor pins; the student's own
  always, at `anchor_x/y`. None below 320 pt of slide width; none on the rail. Context menus: Hide
  (professor, AI), Delete Pin (yours), Add Pin on the slide at the pointer (its card opens for
  typing; an empty pin is deleted when the card closes).
- **Transcript.** Lines are drawn from `TranscriptPatch.runs` over `original_text`: ~~old~~
  (tertiary, red strike) + new on green soft (radius 3, `CorrectionRenderer`); corrected words have
  no doubt dots. A line without patches reads its `text` as before. Revert Correction (line menu)
  sets `reverted_at` on the line's active patches and saves with `withPatches`. A line a professor
  item is quoted from ends with the 16 pt pin and the same card (its words flow in
  `NoteFlowLayout` so the pin follows the last word).
- **Scrubber.** Exam hints amber, said in class purple (replacing the grey off-slide marks once the
  lecture has them), flags red; marks of a kind closer than 0.5 % of the width merge
  (`ScrubberMoments`).
- **Writes** (`StudyEdits`, one DSL statement each): hide (`hidden_at`), revert, add pin (layer
  user, kind comment, lecture, deck, page, anchor x/y), pin text, delete pin (the student's own
  only).

## The Tutor tab (M5)

ReviewUI depends on ChatUI.

- **Segments**: "This slide | Whole lecture | Tutor" (`ReviewInspectorTab`, public; `ReviewModel.InspectorTab` is its alias). Tutor only while `\.chatActions.isAvailable` (Claude Code); without a deck "This slide" is left out. Should the chat become unavailable on the Tutor tab, the notes show (This slide, or Whole lecture without a deck).
- **The tab** is ChatUI's `ChatPanel(context: .lecture(id, page: nil, time: nil), sendContext: …)`, outside the notes' scroll view (it has its own scroll view and composer): the newest tutor conversation of the lecture. A message carries the slide on screen and the playhead (only on the lecture's first recording; else no time) as they are at ↩, read then, so the panel does not redraw with the playhead. On this tab the header gets the chat's ⋯ (`ChatMoreMenu`: New Chat, Memory…) before Hide Inspector.
- **Keys**: ⌘J (View ▸ Show Chat / Hide Chat, ChatUI's `ChatCommands`) is published by the review (`ReviewChatCommand`, `.chatCommand`): Show Chat opens the inspector on the Tutor tab, Hide Chat hides the inspector. While the tutor's composer has focus (`ReviewModel.isComposingChat`) the review's plain keys detach, as for its note editors.
- **`\.reviewInspectorTab`** (public now): the tab a newly opened review starts on; `.tutor` opens it on the Tutor tab.

## Ink on slides and flags (M6)

Workstream B, mockup 03. Drawing is Mac
only (mouse and trackpad; no PencilKit, no iPad work); ink shows on every platform.

**Entry points**

| Piece | Where | What |
|---|---|---|
| `SlideInkEditor` | `Review/SlideInkEditor.swift` (public) | one deck page's ink: `init(deckID:page:aspectRatio:store:debounce:)`, `load()`, `drawing`, `isLoaded`, `flush()` |
| `StudyEdits.addFlag(_:)`, `deleteFlag(_:)` | `Review/StudyEdits.swift` (public) | the student's flag row (`slide_event` kind `flag`) and its undo |
| `SlideInkLayer` | `ReviewUI/SlideInk.swift` | the page's `InkCanvas` over the bitmap, owning its `SlideInkEditor` |
| `InkToolButtons`, `SnapshotInkTools` | same (Mac) | the toolbar group, in the window and in snapshot chrome |
| `DrawingFollowGuard` | same | Follow coming back on ends drawing |
| `ReviewModel.inkTool`, `toggleInkTool(_:)`, `stopDrawing()`, `inkPages`, `setPage(_:hasInk:)`, `canDraw`, `canFlag`, `flag(undoManager:)` | `ReviewUI/ReviewModel.swift` | the tool state, the rail's ink pages, Flag (additions only: the existing API A's inspector reads is unchanged) |
| `ReviewActions.canDraw`, `inkTool`, `canFlag`, `toggleInkTool`, `stopDrawing`, `flag` | `ReviewUI/ReviewCommands.swift` (public) | the Review menu's new items (init parameters with defaults) |
| `InkView`, `InkCanvas` internals | `StudyUI/Ink.swift` | crosshair pointer, eraser ring and sweep, stroke thinning; the public API is the M6 contract, unchanged |

**How it works**

- **Storage.** Ink is per deck page (`slide_ink`, one row per deck + page): the same drawing shows
  on that slide in every lecture that shows it. Units are `InkDrawing.slide(aspectRatio:)` of the
  page's crop box with rotation (`SlideDeck.aspectRatio(page:)`): 1000 across, the page's height
  down, origin top left, so ink lines up at any size. Never written into the PDF. `SlideInkEditor`
  reads the page once (`SlideInkRepository.drawing`), and only then can the student draw (a stroke
  before that would replace the page's ink); it writes 500 ms after the last change (stroke, erase,
  undo, redo) and at once when the page changes or the screen closes (`flush()` from the layer's
  `onDisappear`), one write after another; an empty drawing deletes the row.
- **Stage.** `SlideStage` overlays the bitmap with `SlidePins { SlideInkLayer }`: the overlay's
  empty base, the ink canvas, then the pins, all in the bitmap's frame (the bitmap is never
  re-rendered for ink). The layer has `.id(deck + page)`: a page change replaces the editor and the
  canvas, and the canvas drops its undo steps. With no tool the canvas only draws and clicks pass
  through; with a tool it takes left clicks and drags. Add Pin and the pointer tracking sit on the
  whole overlay, so they work over the canvas; the pins stay above the ink with their hover cards
  and menus.
- **Rail.** The pencil marks slides with notes or ink: the lecture's notes as before plus
  `ReviewModel.inkPages` (`SlideInkRepository.pages` at load, then kept by the layer as ink is drawn
  or erased). Thumbnails never show ink.
- **Tools.** Pen and Highlighter are toggles, one at a time; clicking the one that is on, Esc, or
  Follow coming back on (the Follow button, ⇧⌘F, a transcript line, a time chip) ends drawing.
  While one is on, Eraser joins the group after Highlighter; it removes whole strokes it passes
  (a 7 pt ring under the pointer; the drag is swept, not sampled), and toggling it off returns to
  the pen or highlighter. A tool turns Follow off, so the slide stays put while audio plays.
  Strokes: slide pen 3, highlighter 22 units, blue `#0a5bd6` / yellow at 45 % multiplied over the
  slide's white paper in both appearances (`InkSurface.slide`). A finished stroke is thinned
  (Ramer–Douglas–Peucker, 0.3 pt) and drawn through its points' midpoints; the stroke in progress
  is its own layer, so the finished strokes are not redrawn while it grows.
- **Flag.** `SlideEvent(kind: .flag)` on the recording on screen at the playhead (`sample_time` =
  playhead × `sample_rate`), with the slide on screen as `page_number` and the deck. The red
  scrubber mark comes through `PlayerBar`'s observation. No text, no dialog. The aligner ignores
  flags.
- **Undo.** Every stroke and every erase gesture is one step on the window's `UndoManager` (Edit ▸
  Undo / Redo, ⌘Z / ⇧⌘Z), registered by the canvas and dropped when its page leaves the screen. A
  flag is one step too (undo deletes the row, redo writes it again), dropped when the review
  closes. Flag writes run one after another, so a quick undo never races its insert.
- **Keys** (Review menu, Mac): Flag F, Pen P, Highlighter H, Eraser E (while drawing), Stop Drawing
  Esc (while drawing). Plain keys attach only while the review is focused, no text field has
  focus (notes, a pin card, the tutor's composer, the search field) and the item works (a disabled
  item would swallow its key; decisions: "Menu key equivalents are attached only while their
  screen can use them", DESIGN 6.8).
- **iOS** compiles: the toolbar group, its snapshot copy and the keys are `#if os(macOS)`; the ink
  layer (display only, no tool) is everywhere.

## Measurements (Apple silicon, debug build)

- Paging through all 88 slides of DC L2 with the screen on: peak physical footprint **192 MB**
  the first time (every slide rendered from the PDF), **201 MB** the second time in the same
  process (bitmaps from the disk cache); slowest slide 65 ms cold, under 1 ms warm. The resident
  size reads higher (437 MB) because it also counts freed large allocations the system may reclaim
  (`MALLOC_LARGE` reclaimable) and clean mapped cache files. Measured in a process of its own;
  run beside off-screen renders it read 330 MB and a 1.2 s first slide.
- Before the large slide was drawn into its own backing store it was shown as a SwiftUI `Image`
  (Core Animation layer contents): the same run peaked at **410 MB**, with about 25 decoded
  2048 px slides kept alive by Core Animation (`heap`: 25 × 9.2 MB malloc blocks).
- Seek on a 68-minute recording: the player and the audio land within 0.2 s of the 37:04
  line (the seek takes under 500 ms); crossing the 18 → 19 boundary changes the published page
  exactly once.
- Manual anchor + re-alignment of the synthetic 4-minute lecture: well under 500 ms (the real
  aligner, ≈ 10 ms for 90 minutes per docs/decisions.md).

## Off-screen rendering

Off-screen rendering cannot draw window chrome or Liquid Glass, so off-screen renders use
`reviewChrome = .snapshot`: the same title, toolbar items and inspector laid out inline, glass drawn
as material. A render runs the main run loop while the view settles, so lazy stacks lay out after a
programmatic scroll.

## Requests for the integrator

M6 (workstream B; integrated 2026-10-18: nothing to wire, the iOS target builds, the design notes below are merged into DESIGN and decisions):

- **Nothing to wire.** `LectureReviewView(lectureID:target:realign:)`, `ReviewCommands()` and
  `ReviewInspector(model:)` keep their API; the toolbar group and the Review menu's new items come
  with the package. StudyUI `Ink.swift`'s public API is unchanged (A's sketches get the internals).
- **`tools/ParityRender`**: Review gained `SlideInkEditor.swift` and ReviewUI `SlideInk.swift`; an
  existing build dir needs `tools/ParityRender/.build/debug.yaml` and
  `.build/arm64-apple-macosx/debug/description.json` deleted once (the known stale description).
- **`menus.txt`**: snapshot mode has no focused review, so the new items do not show there; with a
  review focused, Review ▸ Flag F, Pen P, Highlighter H, Eraser E and Stop Drawing Esc must not
  share a key with anything attached at the same time (Lecture ▸ Flag F lives in the live window
  and attaches only while it is focused; Edit's "Emoji & Symbols E" is the fn/globe key).
- **Look in the real window** (off-screen renders cannot show these): the highlighter's multiply
  over the slide's backing-store `NSView` (SwiftUI `blendMode(.multiply)` across a platform view;
  if it reads as plain 45 % yellow over the words, the fallback is a CALayer `compositingFilter`
  on the ink layer); the system's toggled look of Pen / Highlighter / Eraser in the glass group;
  ⌘Z / ⇧⌘Z reaching the window's undo manager after drawing (focus on the slide); Esc ending
  drawing; the crosshair and the eraser ring; Add Pin and pin cards with a tool on.
- **iOS build** (`generic/platform=iOS Simulator`): not built here; the Mac-only parts are
  `#if os(macOS)`.
- **DESIGN and decisions**: the text is under "Design notes for the integrator" below.

M5 (workstream B):

- Nothing to wire beyond `\.chatActions` (already in the main window's environment): the Tutor tab appears with Claude Code. For the `03-review-chat` render, set `.environment(\.reviewInspectorTab, .tutor)` on `LectureReviewView` while the window's `showsChat` is on (DetailView's `.lecture` case). Check `menus.txt`: ⌘J appears once (View ▸ Show Chat).
- `tools/ParityRender` links ReviewUI, which now needs ChatUI (already in its package list).
- Design notes (DESIGN 1.3 for mockup 03's third segment, 6.4, 6.8, 8.1 Review) are in Tutor's README.

M4 (workstream B):

- **DESIGN §9 strings** to add: "Show N more" (plain accent text under a block's first 3 rows),
  menu items "Hide", "Add Pin", "Delete Pin", "Revert Correction"; the category subheadlines
  "Admin", "Deadlines", "Questions", "Examples", "Explanations"; inspector labels "Summary",
  "Further reading", "Exam hints", "Only said in class"; Today's hero line "5 highlights, 3 not on
  the slides" ("1 highlight"; a zero part left out).
- **DESIGN §7.1**: StudyUI `AnnotationPin` (+ `AnnotationPinMark`, `AnnotationPinStyle`),
  `PinCard`, `PinCardQuote`, `FurtherReadingRow` (`StudyUI/AnnotationPin.swift`, `PinCard.swift`).
  §8.1: Review's and Today's "Later" M4 items are built; the scrubber's off-slide marks turn purple
  once a lecture has said-in-class items.
- No API change for `App/` or `tools/ParityRender`: `LectureReviewView` and `TodayView` are as
  before.

Handled in the M1 integration: `LectureReviewView` is the lecture's page (with `Realigner` and a Retry toolbar item while processing failed); `ReviewCommands` is installed, and its keys (like the Lecture menu's) are attached only while their screen is focused and no text field has focus, because a disabled menu item still takes its key (docs/decisions.md); the transcript scrolls to the opening line after layout; the search indexer does not re-chunk on `review_position` saves (it compares transcript, span, deck and note versions only). The list as written:

- Wire `LectureReviewView(lectureID:target:realign:)` with `Realigner(services:).realign` and add
  `ReviewCommands()` (menu "Review"). Shortcut collisions: live mode's Lecture menu also uses ←, →
  and Space without modifiers; both menus disable themselves unless their screen is focused, but
  check on device that AppKit picks the enabled item when two items share a key equivalent.
- `ReviewActions.isEditingText` covers the review's own note editors and `\.isSearching` of a
  `.searchable` above the review. Plain-key menu shortcuts (Space, ←, →) win over text fields, so
  if the toolbar search field is not reported by `isSearching` while focused, publish its focus
  (`searchFocused`) and fold it in.
- Retry for a failed transcription is not on this screen (no access to the processor); the failed
  state shows the job's error. The app's existing Retry can stay in the toolbar or Lecture menu.
- `CaptureUI.SlideImageView` shows slides as SwiftUI `Image`s; Core Animation keeps the decoded
  2048 px bitmaps of recently shown slides alive (see Measurements). The live screen pages through
  a whole deck too: consider drawing the large slide into a backing store there as well
  (`ReviewUI/SlideBitmapView.swift`).
- `@FetchAll var rows: [Row]` declared without an initial value is first default-initialized as a
  fetch of the whole table on the default database before `init` replaces it (M0's
  `LectureDetailView` does this for all transcript segments). ReviewUI stores `FetchAll` values set in
  `init` instead.
- Saving `reviewPosition` every 10 s while playing rewrites the `lecture` row; the search indexer
  (workstream D) should not re-chunk a lecture when only `review_position` / `reviewed_at` changed.

## Design notes for the integrator (M6, workstream B)

Text to merge into `docs/DESIGN.md` and `docs/decisions.md` (builders do not edit them).

**DESIGN 1.3, a row for mockup 03:**

| Mockup | Don't build | Build instead | Why |
|---|---|---|---|
| 03 | only [pen, highlighter, flag] while drawing | an Eraser (`eraser`) toggle that joins the group after Highlighter while Pen or Highlighter is on (toggling it off returns to that tool) | ink needs a way out without ⌘Z; shown only while drawing, so the group at rest stays as drawn |

**DESIGN 3.5, Ink and media (M6):** the toolbar's Pen is `pencil.tip` (mockup `i-pencil`), the
Highlighter `highlighter` (`i-marker`), the Eraser `eraser`, Flag `flag`; the rail's `pencil`
marks a slide with notes or ink.

**DESIGN 6.3, the Review row's trailing column:** "[recording picker, only with 2+] [‹ 16 / 88 ›]
[Pen, Highlighter, (Eraser), Flag] (M6, Mac: only with a deck, Flag only with a recording; Pen and
Highlighter are toggles, one at a time, accent soft with an accent glyph when on; the Eraser joins
while one is on); inspector segmented + hide at the inspector column".

**DESIGN 6.8, rows:**

| Menu | Command | Key |
|---|---|---|
| Review (M6, Mac) | Flag (the student's flag at the playhead; Edit ▸ Undo removes it) | F |
| Review (M6, Mac) | Pen; Highlighter; Eraser (only while drawing); Stop Drawing (only while drawing) | P; H; E; Esc |
| Edit | Undo / Redo also step through ink strokes, erases and flags on a review | ⌘Z / ⇧⌘Z |

The plain keys follow the command pattern: attached only while the review is focused, nothing is
typed, and the item works.

**DESIGN 7.1, a row:**

| Component | File | Use for |
|---|---|---|
| `InkView(drawing:surface:)`, `InkCanvas(drawing:tool:surface:)`, `InkSurface`, `InkTool` (M6) | `StudyUI/Ink.swift` | the student's ink as vectors, aspect fit: on a slide (`.slide`: white paper, highlighter multiplied, pen 3 / highlighter 22 of 1000 units) or in a note's sketch (`.sketch`: light/dark ink, 1.8 / 14 pt). `InkCanvas` draws with the mouse or trackpad (crosshair pointer; a click is a dot), erases whole strokes (7 pt ring), and puts each stroke or erase on the window's undo manager; tool nil passes clicks through. Give it an `.id` per drawing |

**DESIGN 8.1, Review:** replace "Later: pen, highlighter, ink (M6). Not even as placeholders." with:

- Ink (M6, Mac; mouse and trackpad): the toolbar's [Pen, Highlighter, Flag] glass group after the
  stepper (6.3). Pen and Highlighter are toggles, one at a time; clicking the one that is on, Esc
  or turning Follow back on ends drawing; while one is on an Eraser joins after Highlighter (1.3)
  and removes whole strokes. A tool turns Follow off: the slide stays put, the audio plays on.
  Clicks and drags on the slide draw; the pins stay above the ink with their cards and menus (Add
  Pin works). The student's ink is blue (#0a5bd6), the highlighter yellow at 45 % multiplied over
  the slide's white paper in both appearances; it is drawn as vectors over the bitmap in its frame
  (never into it, never into the PDF, never on the rail). Ink belongs to the deck page: the same on
  that slide in every lecture. The rail's pencil marks slides with notes or ink. ⌘Z / ⇧⌘Z step
  through strokes and erases of the slide on screen.
- Flag (M6, F): the student's red flag at the playhead with the slide on screen; the scrubber's
  red mark appears; Edit ▸ Undo removes it. No text, no dialog.

**decisions.md rows:**

| Date | Decision | Why |
|---|---|---|
| 2026-10-18 | Slide ink is per deck page (`slide_ink`, one row per deck + page), not per lecture | the same slide shown in two lectures (or two recordings) carries the student's marks once; matches how the student thinks of notes on a slide |
| 2026-10-18 | Slide ink units: `InkDrawing.slide(aspectRatio:)`, 1000 across and the page's height (crop box with rotation), origin top left; widths in the same units | resolution-independent; lines up with the bitmap at any slide size; no PDF coordinates leak into the model |
| 2026-10-18 | The eraser removes whole strokes (a 7 pt ring, swept between pointer events) and shows only while Pen or Highlighter is on | stroke erasing is predictable with a mouse and keeps every stroke whole for undo and storage; partial erasing would split strokes |
| 2026-10-18 | Drawing turns Follow off; Follow coming back on ends drawing | a slide that pages under the pen loses the stroke; the student can still play, scrub and page by hand |
| 2026-10-18 | Review's Flag (F) writes a `slide_event` flag at the playhead with the slide on screen; Edit ▸ Undo removes it; no text, no dialog | the live lecture's F, after class; the red scrubber mark is the whole UI |
| 2026-10-18 | Ink and flag undo live on the window's `UndoManager`; ink steps are dropped when their page leaves the screen, flag steps when the review closes | ⌘Z never edits a slide or recording that is not on screen |

**Render check (workstream B):** the maintainer's render tool (not included), on a library seeded
with the M6 sample, shows DC L2
at 37:27 on slide 16 with the seeded highlighter under "Performance", the pen ring around
"inter-VM collaboration" and the You pin over the ink, the rail's pencil on 17 and 18, and the
[Pen, Highlighter, Flag] glass group after the stepper, light and dark, as mockup 03.

## Shared decks (mr, workstream B)

A lecture's slides are a page range of a deck (`LectureSlides.current`):
one deck may serve several lectures, each with its own range. Review shows only the lecture's range:

- `ReviewModel` loads `range` (the lecture's current range; else a timed span's deck, whole: a
  capture's stamped deck without a link) and opens `ReviewSession(…, pages: range.pages)`.
- `ReviewSession.pages`: the slide on screen is clamped into it; ← / →, the toolbar's ‹ › and
  Previous / Next Slide stop at its ends; `pageCount` stays the deck's, so the stepper reads
  "50 / 88" (deck numbers kept: S50 stays S50 in every lecture that shows it).
- The rail shows only the range's thumbnails (deck numbers under them); prefetch stays inside it.
- The title's meta: "Data Centers · Mon 19 Oct · slides 38–88 of 88" when the range is not the
  whole deck (DESIGN 9 "Range"); unchanged for a whole deck.
- A slide chip of this lecture outside its range does not move the review.
- The screen reloads when the range changes (the agent's link_deck_pages, continuation
  detection): the load key holds the current link's deck and pages.
- Ink stays per deck page (the same marks on that slide in every lecture); pins and notes stay per
  lecture.

**Requests for the integrator (mr):** parity Review routes on a `cp -c -R` copy of
`.data/parity/mr/library`: `mr-review-l3` (DC Lecture 3, slides 38–88 of 88, no recording: the rail
starts at 38, the stepper "38 / 88", ‹ disabled) and `mr-review-l2` (DC Lecture 2, slides 1–37 of 88:
the rail ends at 41, › disabled on 41), light and dark, against mockup 03.

**Design notes for the integrator (mr):** DESIGN 8.x Review: "The rail, the stepper and ← / → show
only the lecture's range of its deck, with the deck's page numbers ("50 / 88"); the subtitle adds
" · slides 38–88 of 88" when the range is not the whole deck." DESIGN 9 "Range": the Review
subtitle is a use of "slides 38–88 of 88".
