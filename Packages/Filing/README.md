# Filing

Smart import (PRD #2, workstream B): slide PDFs,
audio/video files and captured `.lecture` packages dropped anywhere on the window are filed to
their course and lecture on their own, with one `filing` row per file (evidence, runner-ups,
whether it created the lecture), Undo and Change.

No automated test suite at present; verified by building and rendering.

## Entry points (what the app wires)

```swift
let service = FilingService(services: services,
                            afterImport: { await processor.wake() },
                            cancelJobs: { try? await processor.cancel(recordingID: $0) })   // optional
let center = FilingCenter(service: service)          // @MainActor @Observable, one per main window

RootView().smartImport(center)                       // drop anywhere + HUD + toasts + change sheet + File ▸ Import… panel
CourseRow(…).filingDropTarget(.course(id), center: center)      // sidebar rows: dropped files go exactly there
LectureRow(…).filingDropTarget(.lecture(id), center: center)    // (a course: smart import picks the lecture); the
SessionRow(…).filingDropTarget(.session(id), center: center)    // whole row, lit (list row background) under the
                                                                 // cursor and while the HUD predicts it; reads \.isFilingTarget
SidebarList(…).filingDropZone(center)                            // the sidebar as one drop area: no HUD over it
.commands { ImportCommands(center: center) }          // File ▸ Import… ⇧⌘I
ChangeFilingSheet(filingID: id, center: center)       // also reachable: center.presentChange(id)
```

`FilingService` (actor):
- `predict(_:) -> [FilingPrediction]`: what the HUD shows while dragging; writes nothing.
- `file(_:to:) -> [FilingOutcome]`: decks first, then captures, then recordings by start time;
  `afterImport` after every filing that wrote something.
- `undo(_:) -> Filing?` (the filing when it stays: an un-filed capture), `change(_:to:) -> Filing`,
  `changeToNewLecture(_:courseID:)`.
- At launch: `unfiledCaptures(in:excluding:)` (capture packages that never reached a filing; the
  app files them with `file(_:)`), `repairDeckTitles()` (decks stored under their file name get
  their title slide's heading).
- For screens: `place(of:)`, `places(courseID:)`, `courses()`, `filing(_:)`, `size(of:)`.
- `Filing.needsReview` (auto, and below 0.75, unfiled, or with a runner-up within 0.1) and
  `Filing.reusedExistingFile` (the content was in the library before; Undo keeps it).

## How a file is matched

Evidence (`FileEvidence.read`, no import):
- **Decks** (`DeckProbe`, PDFKit, the first 3 pages plus an even spread, 12 in all): footer = lines
  at the ends of the page text repeated on ≥ 40 % of the sampled pages, page numbers stripped
  ("Data Centers by Ada Example | Bo Sample"); the title slide's lines, its numbered
  heading ("2 Virtualization Basics", "I: Overview", also a numbered footer) and date
  ("13-Oct-26", "13. Oktober 2026", "13.10.2026", ISO, "October 13, 2026"); PDF title/author.
- **File names**: "02_…" → 2, "Slides I_ …" → 1 (Roman), "Lecture 4", "VL_05", "L03".
- **Recordings**: start = the container's creation date (`AVURLAsset.creationDate`), else the
  file's creation date; duration from `AVAudioFile`. A stamp the audio would end after the file was
  last written (or after now, + 2 min) is when the file was written, not when it began (Voice
  Memos' Share writes the export time: a recording stamped 16:20:05 and in
  Downloads at 16:20:19): the start is that stamp minus the duration (`StartSource.writtenAt`).
- **Captures**: course, lecture id and start from the manifest. **Capture bundles** (M7: the
  iPhone's `.lecturebundle`, Share / AirDrop; `FilingTypes.importable` lists the type) are read
  without unpacking (`CaptureBundle.summary`: the manifest and events are the first entries); the
  manifest's course name, short name and session number come along (an id this library does not
  have is the phone's, before sync), and the session number stands in for a file number.

Course score = 1 − Π(1 − wᵢ): course name in the footer 0.6, lecturer surname in the footer 0.45,
course name on the title slide 0.5, surname there 0.3, surname as PDF author 0.5, course name in
the PDF title 0.4, in the file name 0.4 (short name as a word 0.3), the course's slides folder
0.7, a footer like a deck already filed to the course 0.6 (word Jaccard ≥ 0.6), ≥ 2 glossary
terms up to 0.3; recordings: a session of the course holding ≥ 50 % of the recording (sessions
widened by 15 min) 0.6 + 0.35 × share, else a lecture of the course dated that day without a
recording or session 0.6; captures: the captured course 1.0 (by id; when the id is none of this
library's, by its folded name or short name, `FilingMatcher.names`).

A bundle whose recording is in the library already is `known` (nothing is unpacked). Otherwise it
is unpacked into the library's Recordings folder (`FilingService.unpack(bundle:recordingID:into:)`,
off the actor; links, paths outside the package and a second root are refused; a package left
there by an attempt that did not finish is used, one already imported is replaced) and filed as a
capture through the same path as the Mac's own: its audio goes into the BlobStore, the package is
marked imported, transcription is queued. The bundle file itself is never changed.

Lecture fit in a course: a recording's session 1.0 (0.9 if that lecture already has a recording);
the session (else lecture) with the file's number 1.0, or a new numbered lecture 0.95; the session
or lecture on the title-slide date 1.0 (0.85 when a number points elsewhere); else the next
lecture session without slides (from two days ago on) 0.85; else a new lecture 0.8. Agreeing
clues merge (+0.05). Confidence = score × fit.

One class meeting, one lecture (2026-10-21): decks are numbered against lecture sessions only, so
a recording or deck that falls in an exercise, tutorial or seminar of a course with lectures goes
into the lecture that session adjoins (≤ 30 min between them, `SessionLectures.meeting`: a
recitation Tue 16–18 right after the lecture Tue 14–16 is lecture 2's), never into a second
lecture of that day. Such a session gets a lecture of its own only when it stands alone (another
day, the evening), and that lecture takes no number (`SessionLectures.numbersLectures`: an
exercise's own count is not a lecture number, so no second "L2"). A title-slide date picks among
the day's class meetings. Two lectures on one day stay two.

Verdict: no course ≥ 0.45 → **needs course** (stored unfiled: a deck without course, a recording
without lecture and without transcription job; the toast offers Change…); the two best within 0.1
→ **ask** (the HUD shows both and stops following the cursor so you can drop on one; a plain drop
files the best one for review and the toast offers the runner-up in one click); best ≥ 0.75 →
**filed**; otherwise **review** (filed to the best guess). A re-dropped file (same SHA-256, or a
capture's recording id) resolves to its filing (`known`) and creates nothing; content imported
before filings existed gets a describing row (`known_file` signal).

Several recordings in one drop that would each be filed by their day alone to the same lecture
are all asked instead (until weekly slots exist, two Thursday recordings cannot be told apart).

## Second look by what was said (integration)

A recording smart import cannot file is stored unfiled and transcribed at once (no lecture, en/de
detection). Once a transcript exists (`FilingService.fileBySpokenContent(recordingID:)`, called by
the app when a transcription finishes; `fileUnsureRecordingsBySpokenContent()` at launch and after
new slides arrive), `SpokenContent` compares its words with every deck's words (TF-IDF cosine,
IDF over the decks, only words that are on some slide). One course's best deck must reach 0.35
(0.5 when no other course has slides) and 1.8× every other course, with at least 60 slide words
spoken. Then:
- unfiled → the lecture with that deck that has no recording yet (nearest in date), else where
  the matcher puts it in that course;
- filed on its own for review to another course → moved there the same way;
- already where the slides are → confirmed (confidence combined, runner-ups dropped).

The filing stays `auto` with one `spoken_content` signal (the deck's file name, weight 0.75–0.95).
User filings, captures and recordings filed with confidence are never touched; each recording gets
one look. `FilingCenter.refresh(_:)` updates a toast that is still up. A lecture without a session
that is undated or dated only by day takes the start of a recording moved into it.

## Undo and Change

- Undo removes exactly what the filing created, in one transaction: a dropped recording with its
  segments, transcript, slide events, timed spans and jobs (its own running job is cancelled first,
  the lecture's other recordings go on); the deck unless another lecture, a capture's stamps or
  another filing uses it, or it was in the library before (then only the link this filing made);
  the lecture when `createdLecture` and nothing else uses it. A lecture the filing dated gets its
  earlier date back and a reused deck it moved goes back to its course (signals `prior_held_at`,
  `prior_deck_course`, weight 0), unless edited since. Audio and PDF files nothing refers to any
  more are deleted from the BlobStore.
- A capture is never deleted (its audio left the live package on import): Undo un-files it. The
  recording, transcript, stamps, notes (also ones typed later in review) and flags leave the lecture
  and course and the filing stays without a lecture; Change… files it again. Capture toasts offer
  Change… only.
- Change moves everything that hangs off the file in one transaction: recording, transcript, slide
  events, notes, annotations, jobs, a capture's deck link; timed spans move when the new lecture
  aligns against the same deck, otherwise they are dropped and `align` is queued (`transcribe` for
  a recording that had no course). A deck moves its coarse span and `deck.course_id`, and both
  lectures re-align. The lecture the filing created is removed once empty, and the one it leaves
  gets back the date this filing gave it. The filing becomes `manual`; the move works on the filing
  as it is inside the transaction, and the second look by spoken content gives way to any change
  made since it read the filing. `.course` re-runs the matcher inside that course on what the library knows (stored
  slide text, recording start).

## Lectures filed twice (2026-10-21)

Before the rule above, a recording made in the recitation right after a lecture became a lecture
of its own numbered with the exercise's count ("L2 · Wed 21 Oct" twice). `FilingService
.mergeDuplicateLectures(courseID:quote:…)` (`FilingService+Merge.swift`) merges, in one
transaction with one `agent_change` row (`lecture_merge`, target `lecture`; `before.deletion` holds
`LectureMerges`), every pair of lectures of a course that are one class meeting (the same meeting
session, an unlinked lecture by where it was held; or, when one has no session, the same number
on the same day). Only what the student, filing or a capture put in a lecture decides
(`Holdings`): two lectures that both have recordings, or that each show other slides (deck and
range), stay apart (the student moves a recording with Change… on its filing), as does a pair
whose recording is being processed (`busy`) or whose merge the student undid. What the app
generated never keeps a pair apart (second pass, the same day: continuation detection had linked
the recording's lecture to the slides lecture's deck, so the first rule, "one holds only slides,
the other only recordings or notes", left the student's two L2s): Claude's notes versions, the
study pass's units and AI rows, transcript extraction and continuation detection's `auto` deck
links. Every pair of one class meeting left apart gets one public log line with the reason
(counts only); merges get one with the counts; a pass that finds nothing says so.

The lecture filed to a lecture session keeps the meeting (else the one with any session, else the
older) and takes the other's title or number when it has none. The other's recordings move with
`moveRecording` (an open slides-only notes version of the survivor is cancelled: its study pass
writes the notes from the recording, once, `queueAfterStudyPass`), its slides with `moveDeck` (a
deck the survivor shows already keeps the survivor's range; the survivor's own current slides stay
current; recordings aligned against another range of the same deck align again). Detected links
give way to slides: the other's stay with it when the survivor has slides, the survivor's are set
aside when the other brings slides (`LectureMerges.Pair.superseded`). Its notes, own flags, item
sources, tutor conversations, practice questions, kept answers and filings are re-pointed; its
study pass and then the lecture itself are deleted through `DeletedRows` (kept for Undo, generated
notes, detected links and jobs included). `undoMerge(_:)` (the change log's Undo) restores each
lecture that went, moves back what is still with the survivor, puts the survivor's detected links
back (its recordings align again) and marks the row, in one transaction (`changedSince` when a
survivor is gone).

The app runs it at launch, before the processor starts (`FilingService.mergeDuplicateLecturesOnce`,
UserDefaults `Socrates.mergedDuplicateLectures.v2`: the second pass runs once more on every
library; an Undo is never redone). The agent merges two lectures the student names
(`merge_lectures`, a registered action, student-only, AppAgent `LectureMergeTool.swift` →
`ChangeLog.mergeLectures` → `FilingService.mergeLectures(_:_:keep:bothRecorded:quote:…)`): keys
from list_lectures or the course and the number the two share, one course, not both recorded
unless the student's words say so (`LectureMergeRefusal`), the same merge, row and Undo.

## Shared decks (mr, workstream B)

A PDF belongs whole to its course; a lecture names a deck and a page range (`LectureSlides`).
Nothing is copied or cut.

- **Filing a known deck again** (same SHA-256) with a destination other than where it is (a drop on
  another lecture or session of the deck's course, or File ▸ Import into one) **links it there too**
  (`LectureImporter.linkDeck` → `LectureSlides.link`: whole deck, `manual`; the session's lecture is
  created when there is none). It gets its own `filing` row (`known_file` signal, `manual`,
  confidence 1, status filed): its Undo removes only that link (and the lecture when the link
  created it); the lectures that had the deck keep it. A drop where it already is, on a course, or
  on another course's lecture stays "known" (decks are never shared across courses). A deck no
  lecture uses keeps the old path.
- **Change… of a deck filing** moves only that filing's lecture link; other lectures keep their
  ranges. A deck other lectures use never changes course: Change… to another course is refused
  (`FilingError.sharedDeck`, "Other lectures of the course use these slides."), and Undo never puts
  such a deck back into a prior course.
- **Deletes**: deleting a lecture keeps every deck another lecture links (`deletionPlan`); Undo of a
  filing never deletes a deck another lecture links (`deckIsUsedElsewhere`). **Delete Slides…** deletes
  the deck; for a deck several lectures use, the confirmation names them first:
  "DC Lecture 2 and DC Lecture 3 lose these slides." (`FilingService.lectureNames(usingDeck:)`,
  `FilingCenter.PendingDeletion.lectures`).

**Design notes for the integrator (mr):** decisions rows: "Filing a known deck to another lecture
links it there too (whole deck, its own filing row whose Undo removes only that link); a drop where it
is, or on a course, stays known" (why: one PDF per course, several lectures; Undo stays exact);
"Change… of a shared deck moves only that filing's link and never changes the deck's course"
(why: the other lectures keep their slides). DESIGN 9 strings: "DC Lecture 2 and DC Lecture 3 lose
these slides." (Delete Slides… on a shared deck), "Other lectures of the course use these slides."
(a refused Change…).

## UI (mockup 10)

- Cards (`FilingGlass`): Liquid Glass under a frost (white 85 %; dark rgb(58,58,62) at 62 %), a
  0.5 pt hairline lit along the top, and a pop shadow drawn only outside the card. The content sits
  above the glass, so text and fills keep their colours (no vibrancy).
- HUD: 236 pt, next to the cursor: course dot + name (14 pt semibold), "Lecture 3 · Mon 19 Oct",
  "58 slides" or the duration in SF Mono, Change… (dropping on Change… files and opens the
  sheet). Unsure: one row per destination (one course header when they share a course), each a drop
  target; no course: the courses. While the HUD shows, the sidebar row of its first place (or of the
  HUD row under the cursor) is lit too (`FilingCenter.predictedPlace`, shown by its destination's
  row, by its lecture's row once that exists, else by its session's row: `FilingPlace.isShown(byRowOf:)`)
  when that row shows; nothing opens for it. Over the sidebar (`filingDropZone`) the window's drag
  ends: the HUD hides, the predicted row goes dark and only the `filingDropTarget` row under the
  cursor is lit (its area is the whole row, up to half the gap to the next); a drop between rows is
  filed as on the window. Lit: accent 12 % (24 % dark) with a 1.5 pt accent ring, the selection's
  size, as a list row background.
- Toasts: bottom right, stacked, glass, hugging their text up to 444 pt: file tile (window colour,
  a document glyph with a waveform or "PDF" in the course colour), course (semibold),
  "Lecture 1 · Tue 13 Oct" (the day as every screen writes it, `DayText`), "file · 44:34",
  Undo + Change… at the top right (captures: Change… only). Filed toasts go after 8 s and stay while hovered; review
  and needs-course toasts stay until handled (close button on hover). They stay above the bottom
  space a screen reserves (`reservesBottomOverlaySpace`, the review player).
- Change sheet: course menu, the course's lectures and sessions (past and upcoming, SF Mono times)
  plus New Lecture; the list has focus, ↑/↓, ⏎ moves (one filled button, enabled once the choice
  differs), ⎋ cancels.
- No copy explains the matching.

Measured: HUD prediction 38 ms for an 88-page lecture deck and 85 ms for a synthetic 88-page
deck (cold library read), from drag-enter (Debug build, Apple silicon).

## Lecture files (no weekly slots)

Checked once on lecture files (named here by placeholders, times invented) with the three courses
and no slots:
- `02_Virtualization_Basics_v1.pdf` → DC, new Lecture 2 dated Tue 13 Oct (footer, "02_",
  "13-Oct-26"), titled by its title slide; `01_Overview_v1.pdf` → DC Lecture 1, Mon 12 Oct;
  `Slides I_ Overview.pdf` → CL Lecture 1 (footer, Roman I, author "Bo Sample"), undated.
- `Recording 3.m4a` starts **Tue 13 Oct 16:16:08** (QuickTime creation date; the file's creation
  date 18:05:42 is when Voice Memos exported it, see docs/decisions.md) → DC Lecture 2, the deck's
  lecture, via the same day, confidence 0.6 → filed for review. The lecture's date becomes
  16:16:08.
- `Recording 2.m4a` (Tue 13 Oct 14:58:10, 39:51): DC's lecture that day already has its recording
  and CL Lecture 1 has no date, so **no course fits: it asks** (stored unfiled, toast with
  Change…). It never goes to DC. Dropping both recordings at once asks for both.
- Once transcribed, the second look files both: Recording 3 → DC Lecture 2 (0.53 vs 0.20),
  Recording 2 → CL Lecture 1 (0.48 vs 0.22), both sure.

## Requests for the integrator

Handled in the M1 integration: ⇧⌘I is smart import's alone (M0's Import Lecture… is gone); live
captures are filed through `FilingCenter.file`; the shared glass switch stays a FilingUI-internal
flag (the app's snapshot mode cannot draw glass either). The list as written:


- `ImportCommands` uses ⇧⌘I, which the M0 "Import Lecture…" command also uses: retire that one
  (plan §7.7).
- Live captures are filed by `AppModel.fileCapture` straight through `LectureImporter`, so they get
  no `filing` row and no session match. Routing `LiveLectureSession.onFinalized` through
  `FilingService.file([package.url])` gives them both (the course comes from the manifest).
- Off-screen rendering cannot draw Liquid Glass; FilingUI has an internal environment flag that
  draws the cards opaque. A shared switch in StudyUI (or an on-screen capture) would let every
  workstream check glass the same way.
