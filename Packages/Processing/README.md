# Processing

Lecture import and the background pipeline that turns a recording into language-tagged transcript
segments and slide spans (M0 "processing v0"; PRD features 2, 8, 9). The app and
`tools/ProcessLecture` both go through this package.

## mr workstream B checklist (shared decks & continuation detection)

Resume from the last ticked step (each step is its own commit "mr B step N: …").

- [x] 1. Processing: `Realigner` reads `LectureSlides` (pages and anchors only inside the range),
      `ContinuationDetector`, the `align` stage runs it for a lecture without slides, transcribe
      queues `align` whenever there is a lecture, `queueContinuationChecks()`,
      `LectureImporter.linkDeck` (a known deck linked to one more lecture)
- [x] 2. Review: only the lecture's range (rail, stepper, ← / →), deck numbers, meta "slides 38–88 of 88"
- [x] 3. StudyPass `LectureMaterial`, Search (slide hits and lecture scope by range), Coach, Today,
      GlossarySuggestions, Notes' slide pickers
- [x] 4. Filing: a known deck filed to another lecture is linked there too; Change… of a shared
      deck; deletes keep decks other lectures link; Delete Slides… names the lectures
- [x] 5. Throwaway check of detection on a parity copy (positive and negative), constants calibrated
- [x] 6. READMEs, requests and design notes for the integrator; one build per touched package
      (2026-10-20, `taskpolicy -b swift build -j 4`, one at a time: Filing, Processing, Review,
      Notes, Search, StudyPass, Coach, Courses all succeed; their Package.resolved now pin
      swift-issue-reporting as StudyCore does)

## Import

```swift
let importer = LectureImporter(services: services)

// A live capture (Capture's `<uuid>.lecture` package). Keeps the manifest's lecture id.
let imported = try await importer.importCapture(at: package.url, courseID: course.id)

// An existing recording plus slides: Voice Memos .qta/.m4a, .wav, .caf — anything AVAudioFile reads.
let imported = try await importer.importRecording(audio: audioURL, deck: pdfURL, courseID: course.id)

// Packages a crash left behind: the app files them through smart import
// (`FilingService.unfiledCaptures` + `file`); `importPendingCaptures` is for tools.
_ = await importer.importPendingCaptures(in: services.paths.recordings)
```

Smart import (Packages/Filing) chooses the lecture:

```swift
// Into an existing lecture, or a session's lecture: resolved inside the write transaction (two
// imports for one session make one lecture); a lecture held in the session before it existed is
// adopted and linked (`SessionLectures`); created and linked when there is none.
try await importer.importRecording(audio: url, courseID: id, startedAt: start, into: .session(sessionID)) { db, imported in
    try Filing.upsert { … }.execute(db)        // companion rows, same transaction
}
try await importer.importCapture(at: package.url, into: .lecture(lectureID))
// A deck on its own: coarse span over the whole deck, deck.course_id, and `align` queued for the
// lecture's recordings that already have a transcript.
let attached = try await importer.attachDeck(deck, to: .newLecture(number: 3), courseID: id, title: "Storage Systems")
// A recording no course fits yet: stored without lecture, course or job.
let recording = try await importer.storeRecording(audio: url, startedAt: start)
```

`ImportedLecture.createdLecture` says whether the import made the lecture. An existing lecture
without a session that is dated only by day takes the recording's start.

Only packages in the library's Recordings folder lose their audio and get marked imported
(Capture's `LecturePackageReader.libraryOwns`, the rule filing uses too); a `.lecture` picked
anywhere else is copied but never changed (importing it again finds its recording by id).

Each import writes `Lecture` (course language, deck title), `Recording` + `RecordingSegment`s
(audio in the BlobStore), the `Deck` + pages if new, a coarse untimed `LectureDeckSpan` that links
the deck to the lecture (stamped page range for captures, whole deck for imports), and a queued
`transcribe` job. Captures also bring their slide stamps, flags and quick notes (via Capture's
`LecturePackageImporter`). Importing the same audio again returns the existing lecture.

## Jobs

```swift
let processor = LectureProcessor(services: services, engine: WhisperKitEngine(store: try .shared()),
                                  onIdle: { await engine.decoder.unload() })
try await processor.recover()   // once at launch: re-queue jobs left running (fail them after 3
                                // interrupted attempts), queue skipped alignments and transcriptions
await processor.wake()          // after every import; returns immediately
await processor.runUntilIdle()  // tools
try await processor.retry(lectureID:)   // re-queue a failed/cancelled stage (transcription when the
                                        // recording has no transcript)
try await processor.cancel(recordingID:)   // one recording's running + queued jobs (Undo)
try await processor.cancel(lectureID:)
```

| Stage | Reads | Writes (one transaction) |
|---|---|---|
| `transcribe` | recording segments (placed by `startSample`), course languages + glossary | `transcript_segment` rows (lang, words, confidence), job succeeded, `align` job queued whenever the recording has a lecture (mr: with or without slides) |
| `align` | the lecture's pages (mr: its `LectureSlides` range; else the stamps' deck, whole), transcript, `slide_event` show stamps + `manual` anchors on those pages, glossary | timed `lecture_deck_span` rows for the recording (OFF spans have no pages; the coarse span is never touched), job succeeded. A lecture without slides and a recording without stamps: continuation detection first (below) |

Progress goes to the `job` row about twice a second (decoding 0–0.9, repairs 0.9, done 1); while
the model downloads or loads, `job.phase` says so and `progress` is that phase's fraction. The UI
observes it with `@FetchAll`. One job runs at a time; `onIdle` runs before the queue loop ends, so a
job woken meanwhile waits for the unload. A transcription interrupted by a quit or crash restarts
from the beginning on the next launch; finished stages are never redone. A transcription that comes
back empty although the recording has ≥ 30 s of speech fails instead of saving nothing.

## Other pieces

- `AlignmentMapping`: StudyCore ↔ Alignment (slides, transcript lines, anchors, spans).
- `LectureOutline`: transcript segments grouped by the span holding each segment's midpoint, with
  slide titles; one untitled section before alignment.
- `LecturePackageBuilder`: writes a `.lecture` package from an audio file and a list of slide
  stamps, exactly as live capture would (used by the end-to-end tool).

## Shared decks (mr)

A PDF belongs whole to its course; a lecture names a deck and a page range (StudyCore
`LectureSlides`). Nothing here copies or cuts a PDF.

- `Realigner.slides(lectureID:recordingID:in:)`: what a recording is aligned against: the
  lecture's current range (`LectureSlides.current`), else the deck its stamps were taken on, whole.
  `plan` gives the aligner only those pages (deck numbers kept) and keeps only stamps and markers
  on them; `deckID` (and `LectureProcessor.deckID`, `recover()`'s orphan rule) follow it.
  Realignment replaces only that recording's timed spans, never the coarse span.
- `LectureImporter.linkDeck(_:to:then:)`: a deck already in the library linked to one more lecture
  (whole deck, `manual`, through `LectureSlides.link`; the session's lecture created when needed),
  for smart import's "filed again to another lecture" (Filing). `AttachedDeck.linkedNow` is false
  when the link was already there.

## Continuation detection (mr)

A lecture that carries on with an earlier lecture's slides and was only recorded: a transcribed
recording whose lecture has no slides (and that has no slide stamps) gets them from the course's
recent decks, on device (`ContinuationDetector`, the `SlideAligner`; no model).

- **When**: transcription queues `align` whenever the recording has a lecture. The `align` stage
  sees no slides (`Realigner.slides` nil) and runs the detector first.
- **Candidates**: the decks of the course's latest lectures other than this one (newest `held_at`
  first, undated after dated; a lecture's current deck first), distinct, at most 3; then at most 2
  more of the course's decks that arrived later (`laterDeckLimit`, newest `imported_at` first):
  decks no lecture uses and decks imported since the day before the lecture (filed to the course
  only, or to an older lecture beyond the newest three); minus the decks the student turned down
  for this lecture (`LectureSlides.declinedDeckIDs`: unlinked, or a link undone). Each: the aligner
  over every page, no anchors, the course glossary.
- **Measures** (`ContinuationDetector.Measure`): coverage = the share of the speech time (transcript
  lines) inside slide spans; confidence = the slide spans' confidence weighted by duration; the
  window = the contiguous pages between the 1st and the 99th percentile of on-slide time (pages in
  deck order).
- **Accept** the best coverage × confidence with coverage ≥ 0.6, confidence ≥ 0.5 and a window of
  ≥ 3 pages; within 0.05 of the best, the first candidate wins (the newest lecture's deck; the
  lectures' decks before the later ones) (`Thresholds`, one place).
- **Write** (one transaction): `LectureSlides.link(source: .auto, confidence:)` of the window, its
  `deck_link` change row (`DeckLinkResult.change`: source `transcript`, quote = the original text of
  the line on a window slide sharing the most terms with that slide, ≤ 300 characters, `time` = its
  start, `recording_id`, model ""), the recording's alignment against the window, the job succeeded.
  Slides that arrived meanwhile win: the job ends and `align` is queued again. Nothing found: the job
  just succeeds. Undo is the change log's (AppAgent `ChangeLog` → `LectureSlides.undo`); an undone
  link is a declined deck, never linked again by detection.
- **Slides that arrive later** (2026-10-21): a phone recording of a course is filed to the day's
  lecture by its timetable slot and checked right after transcription, often before the slides
  exist (the professor uploads them after class) or against an earlier lecture's deck it reuses;
  slides filed after that send it back to a check. One rule, StudyCore
  `LectureSlides.queueContinuationChecks(courseID:)` (inside the caller's write): `align` jobs for the course's transcribed recordings whose lecture
  has no slides (no coarse span: a link by filing, a capture, the student, the agent or an earlier
  detection is never replaced) and no queued or running job (one per recording at a time), newest
  lecture first (stamps 1 ms apart, the queue runs the oldest first): never checked → always;
  checked before → again when the course got slides after that check began (`deck.imported_at`, a
  coarse span's `updated_at` that is not detection's own `auto`), only for lectures of the last 21
  days (`continuationRecheckAge`). Callers: smart import after a deck or capture filing and after
  a move (Filing `checkForContinuations`), the agent's `link_deck_pages` (AppAgent
  `ChangeLog.applyDeck`, its jobs wake the processor), and the launch backfill. One public log
  line per call with counts only: "Continuation checks (slides filed): 1 first, 2 again, 3 up to
  date, 0 older than 21 days".
- **Backfill**: `queueContinuationChecks()` (one write transaction, every course): the same rule;
  catches recordings transcribed before detection existed, a quit between a filing and its
  checks, and slides filed on another device. The `align` job row is the marker (its start
  against the course's newest slides). Off the main actor, never on the launch path.
- **Notes**: a lecture whose finished notes were written before its slides arrived (filed or
  detected later) gets them written again once its study pass has run with the slides
  (StudyCore `LectureNotesRepository.queueAfterStudyPass`: the newest coarse span is newer than
  the version; the same Write Again sentence; the queue's one-at-a-time `lecture_notes` slot).
- **Cost**: ≤ 5 aligner runs per check (about 0.2 s each), no model.

**Calibration (once, 2026-10-20, a throwaway CLI on a copy of a parity library,
deleted after):** DC Lecture 2's slides moved to DC Lecture 1 (L2 unlinked, L1 linked to the whole
88-page deck "Virtualization & IaaS"; DC L3 keeps 38–88), detection run for L2's recording (612
lines, 68 min; seeded range 1–37):

| Candidate | Coverage | Confidence | Score | Window | Verdict |
|---|---|---|---|---|---|
| DC deck ae4abf08 (88 pages; L3's and L1's, one candidate) | 0.947 | 0.766 | 0.725 | 2–35 (34 pages) | linked |
| CL deck ea42ad59 (36 pages) alone | 0.110 | 0.883 | 0.097 | 12–12 (1 page) | nothing |

- On-slide time of the DC alignment: pages 2–35 (slide 1, the title, and 36–37 never on screen);
  the 5th / 95th percentiles gave 2–33 and cut the discussed slides 34 (24 s) and 35 (45 s), so the
  window is the **1st–99th percentile** (`windowStart` 0.01, `windowEnd` 0.99): 2–35.
- Coverage separates the two by far (0.95 vs 0.11); confidence does not (a wrong deck's few spans
  are confident), so the thresholds stay coverage ≥ 0.6 (the deciding one), confidence ≥ 0.5,
  window ≥ 3 pages, newest within 0.05.
- End to end on the copy: `queueContinuationChecks()` queued 1 (L2's recording, its old `align`
  jobs removed), `runUntilIdle()` linked "DC Lecture 2 · Uses DC L1’s slides 2–35" (`auto` 0.77,
  source transcript, model "", quote the line at 27:14), 32 timed spans on pages 2–35; L1 and L3
  kept theirs. Aligner time per candidate: 0.21 s (88 pages) and 0.13 s (36 pages), Debug.

## Courses and Notes (mr, workstream B notes)

- `CoursesUI/TodayData`: the review hero's "slides 1–37 of 88" reads the lecture's range: the pages
  its aligned visits showed inside the range, else the range ("slides 38–88 of 88" for a lecture
  without a recording); the deck count is the range's deck.
- `Courses/GlossarySuggestions`: a timed visit counts a page as shown only inside its lecture's range
  of that deck (a span without seconds); the field's spans (`GlossaryField`, not edited: the parallel
  fix branch's file) already pass both.
- `NotesUI/NotePickers`: the Slide picker shows the lecture's range (`LectureSlides.current`), deck
  numbers kept. `NotesView`'s Move keeps a slide note's anchor only in a lecture whose range shows
  that page of that deck.
- Course Settings' deck rows (`CourseSettingsView`, the parallel fix branch's file) were not touched.

## Requests for the integrator (mr)

- `App/Shared/AppModel.swift` `start()`, in the background part of the launch after
  `processor.recover()`: `let queued = try await processor.queueContinuationChecks()` (log the
  count), then the existing `processor.wake()`. Nothing on the launch path before the first window.
  A recording of a lecture without slides (transcribed before mr) gets its V01
  slides this way on the next launch, logged as a `deck_link` change with Undo.
- Parity Review routes `mr-review-l3` and `mr-review-l2` (Review README, "Shared decks (mr)").
- No StudyCore change was needed.

## Design notes for the integrator (mr)

- DESIGN 8.x Review and 9 "Range": see the Review README ("Shared decks (mr)"); Today's hero meta
  keeps "slides 1–37 of 88" from the lecture's range.
- decisions rows: "A lecture's slides are a page range of a course's deck (`LectureSlides`); every
  reader (Review, alignment, the study pass, search, the coach, Today, Notes) uses the range, deck
  numbers kept" (why: one PDF per course, no copies, S21 stays S21); "Filing a known deck to another
  lecture links it there too" (Filing README); "Continuation detection: the aligner against the
  course's 3 newest decks, coverage ≥ 0.6, confidence ≥ 0.5, window ≥ 3 pages (1st–99th percentile
  of on-slide time), the newest within 0.05; on device, once per transcription, a launch backfill"
  (why: the student records only some lectures of a deck); "Detection never links a deck the
  student unlinked from that lecture or whose link they undid (`declinedDeckIDs`)" (why: Undo sticks).

## End-to-end check (real model)

```
swift build -c release --package-path tools/ProcessLecture
B=tools/ProcessLecture/.build/release/process-lecture
PDF="<path to the lecture's slide deck>.pdf"
F=.data/fixtures/<lecture>     # audio16k.wav, and truth.json for --truth (git-ignored)
$B run --audio $F/audio16k.wav --deck "$PDF" --library .data/e2e/run --truth $F
$B capture --audio $F/audio16k.wav --deck "$PDF" --library .data/e2e/capture \
    --start-page 3 --stamps "2:10=4,5:40=6,12:05=9,20:30=12" --truth $F
```

Libraries and reports contain lecture text: keep them under `.data/`.
