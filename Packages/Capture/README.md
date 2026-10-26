# Capture

In-class capture (PRD #4, M0): the slide deck on screen, the recording, slide stamps on the
audio clock, flags, quick notes and provisional captions. Mac first; compiles for iOS/iPadOS.

Two products:

| Product | Contents | Imports |
|---|---|---|
| `Capture` | lecture packages, segmented recording, stamps, deck rendering, captions, import into StudyCore | StudyCore, AVFAudio, CoreGraphics/ImageIO, PDFKit, Speech. No SwiftUI/AppKit/UIKit |
| `CaptureUI` | `LiveLectureView`, `SlideImageView`, `LiveLectureCommands` | Capture, SwiftUI |

No automated test suite at present; verified by building and rendering.

## Lecture package

A recording lives on disk first, independent of the database, so a crash never loses more
than the audio not yet flushed (about 60 ms; tested by reading an unclosed segment).

```
Recordings/<uuid>.lecture/
  manifest.json   LectureManifest: version, id (= Recording.id), courseID?, lectureID?,
                  deck {sha256, pageCount, deckID?}, startedAt (wall clock at sample 0),
                  hostTimeAtStart, endedAt (nil after a crash), sampleRate, channelCount,
                  fileFormat, device {name, uid, nativeSampleRate}, platform, captionLocale,
                  segments [{id, sequence, file, startSample, frameCount?, hostTime?, startReason, device?}],
                  importedAt; M7 (optional, additive): courseName, courseShortName,
                  sessionNumber, sessionName (the iPhone's words for a library whose ids differ)
  events.json     {version, events: [LectureEvent]}: start, stop, slide (→/Space), back (←),
                  jump (filmstrip), flag (F, optional text), pause and resume (iPhone). Each
                  has page (1-based, after the event), fromPage, sampleTime (frames on the
                  recording clock), hostTime (mach_absolute_time), wallClock.
  notes.json      {version, notes: [QuickNote]}: one plain-text note per page.
  audio/seg-0001.caf, seg-0002.caf, …   48 kHz mono 16-bit LPCM, 5 minutes each.
```

JSON is pretty-printed with sorted keys; dates are ISO 8601 with milliseconds. Kinds are
strings, so files written by newer builds still decode.

### Capture bundle (M7)

`CaptureBundle` puts one package into one file for Share / AirDrop from the iPhone:
`DC Lecture 2.lecturebundle` (UTType `$(BUNDLE_ID_PREFIX).socrates.lecture-bundle`, declared by
the app), an **uncompressed Apple Archive** of exactly one `<uuid>.lecture` folder. Entries are
written in a fixed order (the root, `manifest.json`, `events.json`, `notes.json`, other files,
then `audio/` and its segments) with only `TYP` (folder or regular file), `PAT` (relative path)
and `DAT` (bytes): no owners, modes, links or extended attributes.

- `write(package:to:)` reads the package (a link in it is refused) and writes the file through a
  hidden partial file next to it.
- `summary(of:)` reads the manifest and events from the first entries without unpacking (smart
  import's evidence while dragging).
- `unpack(_:into:)` refuses links and every other entry type, absolute paths, `..` and `.`, a
  second root and a root that is not `<uuid>.lecture`, and a package already in the folder; it
  writes into a hidden `.unpack-<uuid>` folder first and moves the package into place at the
  end, so nothing is left behind on failure. The bundle itself is never changed.
- `CaptureBundleItem(package:title:)` is the Share sheet's `Transferable`: the bundle is written
  when the destination is picked, into its own folder under `CaptureBundle.temporaryDirectory`;
  `removeTemporaryBundles(olderThan:)` clears old ones (at each share and at launch).

### Counting slides without a deck (M7)

`Configuration.countsSlidesWithoutDeck` (the iPhone sets it): without a deck, Next and Previous
count from `initialPage` (Previous never below 1, no upper bound) and every stamp carries the
number. The Mac leaves it off: its deckless live screen does not count. `reassign(courseID:
lectureID:assignment:)` changes the course and class the manifest names, also while recording
(the phone's course menu); `Configuration.assignment` gives the names the first manifest carries.

### The recording clock

- Sample 0 is the first recorded frame. Within one engine run segments are contiguous to the
  frame (`seg-0002.startSample == seg-0001.startSample + seg-0001.frameCount`).
- When the input is reconfigured (device switched, interruption), the engine is rebuilt and a
  new segment starts where real time had got to (`startReason: discontinuity`), so there is a
  gap on the clock. Players and transcribers must place each segment at `startSample` and treat
  gaps as silence.
- Input at another rate (AirPods, USB interfaces) is converted to the recording rate, so one
  recording has one sample rate.
- A stamp is taken the moment the key press arrives (`mach_absolute_time()`), then mapped onto
  the clock through the latest "frame N was captured at host time H" anchor the writer set.

### Pause and resume (iPhone)

`LiveLectureSession.pause()` / `releaseInput()` / `resume()` over `AudioCaptureSource.pause()` /
`releaseInput()` / `resume()` (`MicrophoneCapture`; other sources refuse). The Mac never pauses.

- **Pause**: the clock is read the moment Pause stops the engine (host time, and
  `ContinuousClock` for the gap). A barrier through the writer's own queue (private to the
  capture: the tap sends audio there and to the fan-out; meters and captions never see it) makes
  sure everything captured is written, awaited for at most 1 s; the open segment closes; then the
  `pause` event (`sampleTime` = where the clock stood when Pause stopped the input: never before
  the end of the audio written, and after it when the input had been lost before the pause, an
  interruption iOS never ended, because the clock counts that time as recorded like any
  interruption; `page` = the slide on screen; `wallClock` = when Pause was pressed) and the
  manifest are written, awaited. `releaseInput()` then ends the audio session (the microphone
  indicator goes out). Nothing is stamped while paused: slide moves and flags do nothing,
  interruptions and route changes are ignored. A write that failed (storage full), also one
  reported while paused, stops the recording.
- **Resume**: the audio session and a new engine run start; the recording clock is placed at
  the pause's place plus the time paused, measured with `ContinuousClock` (the host clock stops
  while the phone sleeps, which would place everything after the pause too early). The next
  audio opens a new segment there, never before it (`SegmentedAudioWriter.nextSegmentFloor`, so a
  first buffer without a host time cannot pull the gap shut; `startReason: discontinuity`, as
  after an interruption), and the `resume` event carries that position. A resume that fails
  throws and stays paused: `CaptureError.inputBusy` for a call or another app holding the input
  (AVAudioSession's busy, priority, interrupt and cannot-record errors), `writeFailed` after a
  failed write. Pause and resume throw when a failure stopped the recording meanwhile.
- **On the clock** a closed pause is a gap without audio, like an interruption: players and
  transcribers treat it as silence, filing sees the recording's real span, and the stamps after
  it keep their real times. `LecturePackageContents.duration` includes it;
  `recordedDuration` (and the phone's timer and its outbox) leave out the part of each closed
  pause that lies inside the audio. `RecordingPauses` reads the pauses from the events
  (`contents.pauses`, `session.pauses`).
- **Stopped while paused**: the `stop` event sits at the pause; no trailing gap.
- **Killed while paused**: the segments are closed, the last event is `pause` and `endedAt` is
  nil, so the package imports like any unfinished one. The iPhone takes such a recording up again
  at launch when its Live Activity is still up (`LiveLectureSession.reopen(paused:)` over
  `AudioCaptureSource.reopen(_:)` with a `PausedRecording`: the writer continues the segment
  list, the pause's gap is measured from its wall clock since the process is gone; then
  `resume()` and `stop()` as after any pause), and otherwise finishes it where it paused
  (`LecturePackageWriter.finishLeftPaused`: a `stop` event at the pause, `endedAt` = the pause's
  wall clock, the segments as found). A segment the manifest lost (killed right after a resume)
  is placed at the first `resume` at or after the previous segment's end, not right after it.
- No format change: the manifest keeps version 1 and its segment reasons (an older Mac decodes a
  new package and ignores the two event kinds). The importer makes no rows for them.

### Closed segments (the recording link)

`LiveLectureSession.segments` is the capture's segment list as last reported, kept in memory and
set before each manifest write (the manifest on disk lags behind, and a crash can leave it
without the newest segment). `closedThrough` is the highest segment whose file is closed, so it
can be copied while recording (a closed file never changes; the next segment is a new file,
opened only after the one before it closed): paused, finished or failed, every segment; otherwise
the newest once its frame count is known, else the one before it. A missing frame count alone
never means "still open" (a crash and a failed write both leave one). The iPhone recorder
publishes it as `RecorderSnapshot.closedSegments`.

## Using it from the app

```swift
import Capture
import CaptureUI

// 1. Make a session (deck optional). Own it in the app model: it must outlive the view.
let session = try await LiveLectureSession.open(
    configuration: .init(
        directory: services.paths.recordings,
        courseID: course.id, lectureID: lecture?.id, deckID: deck?.id,
        captionLocale: Locale(identifier: course.language)   // nil hides captions
    ),
    deckURL: deck.flatMap { $0.blob }.map(services.blobs.url(for:)),
    deckSHA256: deck?.blobSHA256,
    cacheDirectory: services.paths.caches.appending(path: "Slides"),
    pageTexts: pages.map(\.text)                              // optional; else PDFKit
)

// 2. File the package once it is final (after Stop, or after a recording failure stopped it).
//    The owner sets this, not the view: it fires whether or not the live screen is open.
session.onFinalized = { package in Task { try await LecturePackageImporter(services: services).importPackage(package) } }

// 3. Show it. Notes and flag text are editable until Stop.
LiveLectureView(
    session: session,
    context: LiveLectureContext(title: "Data Centers · Lecture 2 · …", color: courseColor, onChange: { … })
)

// 4. Menu commands (→ next, ← previous, F flag, ⇧⌘R record/stop; ⌃⌘I inspector). Space is
//    handled by the view. `leading` items go before Next Slide, `trailing` ones after Record
//    (the iPhone's recording on the Mac; they bring their own divider).
WindowGroup { … }.commands { LiveLectureCommands(); InspectorCommands() }

// 5. At launch, before any recording starts: import packages left behind by a crash.
_ = await LecturePackageImporter(services: services).importPending(in: services.paths.recordings)
```

`DeckImporter(services:).importDeck(at:courseID:)` puts a PDF into the BlobStore and writes
`Deck` + `DeckPage` rows (text and labels via PDFKit); re-importing the same file returns the
existing deck.

### What import writes

| Package | Rows |
|---|---|
| manifest | `Recording` (id = package id, source mac/ipad/iphone from platform, state finished, duration) |
| audio segments | `RecordingSegment` (sequence 0-based, startSample, frameCount, blob sha/path, "caf") |
| start / slide / back / jump | `SlideEvent` kind `show` with page, deck, sampleTime, hostTime |
| flag | `SlideEvent` kind `flag` (no page); with text also an `Annotation` (layer user, kind `flag`, startTime, page) |
| quick notes | `Note` (page, audioTime, `blocks` = `[{"type":"paragraph","text":…}]` per line) |

One transaction; ids come from the package, so re-import updates instead of duplicating. Course,
lecture and deck ids that do not exist are dropped rather than failing the foreign keys. By
default the package's audio files are deleted once committed (the blobs are APFS clones) and the
manifest is marked `importedAt`; `removeAudioAfterImport: false, markImported: false` leaves a
package the user picked elsewhere untouched. The manifest is untrusted: segment paths always come
from the files found in `audio/`, and only regular files (no links) there are copied or deleted.

## Pieces

- `MicrophoneCapture` (actor): `AVAudioEngine` input tap → `AudioChunk` (Sendable copy, mono)
  → `AudioBroadcaster` fan-out → writer task. Rebuilds the engine on
  `AVAudioEngineConfigurationChange` (and iOS interruptions). Holds a `ProcessInfo` activity
  (user initiated, idle system sleep disabled) while recording. Asks for the microphone with
  `AVAudioApplication`.
- `SegmentedAudioWriter`: the file side, unit-tested with synthetic PCM.
- `RecordingClock` / `HostClock`: host time ↔ recording frames; `HostClock` is injectable.
- `LiveLectureSession` (`@MainActor @Observable`): phases ready → starting → recording →
  stopping → finished / failed; `next`, `previous`, `jump(to:)`, `flag(_:)`, `setFlagText`,
  `setNote(_:forPage:)`. Takes any `AudioCaptureSource`.
- `SlideDeck` (actor): `CGPDFDocument` rendering at `SlideWidth.thumbnail` (320 px) and
  `SlideWidth.display` (2048 px) into an in-memory LRU (128 MB) and PNGs keyed by
  `SlideRenderKey` (deck SHA-256, page, width, renderer version), loaded with ImageIO.
  88-slide deck: open 6 ms, first display render 67 ms, full prerender 5.6 s (background),
  reload from disk 16 ms.
- `DeckText`: PDFKit page text, labels and short stamp titles.
- `LiveCaptioner`: optional `SpeechTranscriber` captions (installs assets on first use);
  `CaptionTranscript` holds final lines plus one volatile line.
