# Recorder

The iPhone recorder (M7; PRD #3, #42, "iPhone recording"; mockup 09 left,
DESIGN 8.5): a lecture recorded with the screen locked or the app in the background, slide stamps
from the 88 pt Next slide button and from the Live Activity, and the outbox of phone captures,
shared to the Mac as capture bundles (`.lecturebundle`) that the Mac's smart import files.

| Product | Contents | Imports |
|---|---|---|
| `RecorderActivity` | `RecordingActivityState` (+ `slideText`, `detailLine`, `shortSlide`, `timerRange`), `RecordingActivityAttributes` (iOS), `RecorderCommand` (`nextSlide(from:)`, `stop`), `RecorderControl` | Foundation, ActivityKit (iOS). Linked by the app and the widget extension |
| `Recorder` | `PhoneRecorder`, `PhoneCapture`, `RecorderText` | RecorderActivity, StudyCore, Capture, Courses (ActivityKit on iOS) |
| `RecorderUI` | `RecorderScreen` (+ internal `OutboxView`, `RecorderWaveform`) | Recorder, StudyUI, Capture, CaptureUI, SwiftUI |

The Live Activity's widget is in `Widgets/SocratesWidgets.swift` (the `SocratesWidgets`
extension, RecorderActivity only); its views (`RecordingLockScreenView`, `RecordingTitle`,
`RecordingElapsed`, `RecordingButtons`, DEBUG `RecordingLockScreenParityCard`) and the two intents
(`NextSlideIntent`, `StopRecordingIntent`) are in `Widgets/Shared/`, compiled into the app (iOS)
and the extension: Live Activity buttons run their intents in the app's process, and the app's
parity screen draws the Lock Screen view.

## Entry points

```swift
// Launch (iOS), before the first scene: the Live Activity buttons find the recorder even when a
// tap launches the app in the background. Also clears an earlier run's shared bundles and
// Live Activities.
let recorder = PhoneRecorder(services: services)
recorder.activate()

// Record (the shell's round button, Today's Record): present the screen full screen. It calls
// `prepare()` itself (courses with consent, the class on now or the last course used, the
// class's deck when its file is on the phone, the outbox).
.fullScreenCover(isPresented: $recording) { RecorderScreen(recorder: recorder) }

recorder.isRecording            // starting, recording or stopping: the shell's Record shows it
recorder.liveActivityState      // what the Live Activity shows (parity: the Lock Screen view)
```

- `prepare(now:)`, `select(_:)` (the course menu; while recording it re-files the manifest and
  updates the Live Activity), `start()`, `next()`, `previous()`, `flag()`, `stop()` (the screen
  asks first; the Lock Screen's Stop Recording does not), `elapsed(at:)`, `sessionName` ("DC
  Lecture 2", without a known class "DC Tue 13 Oct"), `sessionLine` ("Lecture 2 · Tue 13 Oct").
- The outbox: `captures` (newest first; the recording in progress left out), `finished` (the
  capture Stop just finished, shown with Share until the screen opens again), `delete(_:)`,
  `reloadCaptures()`. `PhoneCapture.bundleItem` is the Share sheet's item.
- `PhoneRecorder.preview(services:stopped:startsActivity:)` (DEBUG): Data Centers Lecture 2 at
  slide 17 of 88 (the deck when its blob is in the library), 38:41 in, six stamps, level 0.55,
  built on `LiveLectureSession.openPreview` / `showPreview`; it never records. `stopped: true`:
  the screen after Stop (the capture and two earlier ones; their packages do not exist, Share and
  Delete do nothing). `startsActivity: true`: also requests its Live Activity.

## Rules as built

- **Courses**: only courses with recording consent are in the menu and can record; consent is
  checked again right before recording starts (Course Settings can withdraw it).
- **Default course**: the class on now (`CourseSchedule.session(forRecordingAt:)` over all
  courses, if its course may record), else the last course used (kept in `UserDefaults`), else
  the first. The class is then the course's session around now.
- **Deck**: the lecture filed to that class (else the course's lecture of the class's number) and
  its coarse deck span's deck, only when the deck's blob is on the phone (blobs do not sync).
  Then "Slide 17 of 88" and the slide; the count stops at its pages. Without one the session
  counts from 1 (`countsSlidesWithoutDeck`: Previous never below 1, no upper bound): "Slide 17"
  and no image. No captions on the phone.
- **Recording**: `LiveLectureSession` with `RecordingFormat.standard` into `AppPaths.phoneCaptures`
  (created on the first recording); Next = `slide`, Previous = `back`, Flag = `flag` on the audio
  clock. The manifest carries the course's name and short name, the session's number (numbered
  lectures) and name (`LectureManifest.courseName`, `courseShortName`, `sessionNumber`,
  `sessionName`). Nothing is imported into the phone's library.
- **Live Activity**: requested on start when Live Activities are enabled
  (`Activity<RecordingActivityAttributes>`, `recordingID` = the package id); updated when what it
  shows changes (a slide stamp, the course), one update after another; ended on Stop (or when a
  failure stopped the recording) with its final state (`stoppedAt`: the time freezes) and
  `.immediate` dismissal. Its buttons act only on their own recording; Stop there stops at once.
  The system may run one tap's intent twice, so every command is safe to repeat: Next Slide
  carries the slide its button was drawn for (`NextSlideIntent.slide`, `nextSlide(from:)`) and
  moves only while the recorder is still on it (otherwise it logs, does nothing and sends the
  activity the slide on screen again); a second Stop finds nothing recording. The intent
  returns only once the activity has the new slide, so a suspended app never leaves an old
  button behind. Two real taps before the activity redraws count as one.
  `activate()` ends activities of a recording the app no longer has. The elapsed time counts by
  itself (`Text(timerInterval:)`), so a locked phone does no work between stamps.
- **Waveform**: four level samples a second while recording with the screen active (nothing while
  locked); stamp lines for the slide changes in view.
- **Outbox**: the phone's packages newest first (title = the manifest's session name, else the
  course's short name and the day; day; length; stamp count). Share writes the bundle when the
  destination is picked (`CaptureBundleItem`, a temporary folder; nothing is kept). Delete… asks,
  naming the recording, and removes the package.

## The capture bundle

`DC Lecture 2.lecturebundle`, UTType `$(BUNDLE_ID_PREFIX).socrates.lecture-bundle` (declared in the
app's Info.plist, conforms to `public.data`, `public.archive`): an uncompressed Apple Archive of
exactly one `<uuid>.lecture` folder, entries in a fixed order (root, `manifest.json`,
`events.json`, `notes.json`, `audio/`, its segments), each only `TYP` / `PAT` / `DAT`. The Mac
reads the manifest from the first entries without unpacking, and unpacks it refusing links, other
entry types, absolute paths, `..`, `.`, a second root and a root that is not `<uuid>.lecture`.
Details: `Packages/Capture/README.md` ("Capture bundle"); filing: `Packages/Filing/README.md`.

## Requests for the integrator

1. **Phone wiring (iOS)**: `AppModel` owns `PhoneRecorder(services:)` on iOS for the app's life and
   calls `activate()` at launch, before the first scene (in the App's `init`, so a Live Activity
   button that launches the app finds the handler). The shell's Record button and Today's Record
   present `RecorderScreen(recorder:)` with `.fullScreenCover`; `PhoneShell(isRecording:)` gets
   `recorder.isRecording`. No `LectureProcessor` on the iPhone and no package import there.
2. **Mac: opening a capture**: `.onOpenURL` (and the document open of the `CFBundleDocumentTypes`
   for `.lecture` and `.lecturebundle`, already in project.yml) → `filingCenter.file([url])`
   (start and stop the URL's security scope; an AirDropped bundle lands in Downloads and Finder
   opens it with the app). Drop and File ▸ Import… take bundles already (`FilingTypes.importable`).
3. **Parity routes** (DEBUG, `App/iOS/PhoneParity.swift`, `-phoneParity …` with
   `SOCRATES_DATA_ROOT` on a copy of `.data/parity/m7/library`):
   - `recorder`: `RecorderScreen(recorder: try await PhoneRecorder.preview(services: services))`.
   - `recorder-after-stop`: the same with `preview(services:stopped: true)`.
   - `activity`: `RecordingLockScreenParityCard(state: preview.liveActivityState!, recordingID: UUID())`
     centred on a dark wallpaper; the real Lock Screen and the Dynamic Island from
     `preview(services:startsActivity: true)` with the app sent to the background
     (`xcrun simctl` home / lock), screenshots only (it never records, no microphone prompt).
4. **Info.plist**: nothing new beyond what the contracts landed (`UIBackgroundModes: audio`,
   `NSSupportsLiveActivities`, `NSMicrophoneUsageDescription`, the two exported types). The new
   `Widgets/Shared/RecordingActivityViews.swift` is picked up by both targets' source paths.

## Design notes for the integrator

**DESIGN 1.2** (row "iPhone recorder, Live Activity, iPhone Today", 09): "built in
`Packages/Recorder` (`RecorderScreen`, `PhoneRecorder`) and the `SocratesWidgets` extension
(Live Activity: Lock Screen, Dynamic Island); smart import files the phone's capture bundles
(`.lecturebundle`). Checked off screen in the simulator (`.data/parity/m7/`); recording on a
device, locked for 90 minutes, the Lock Screen buttons with the phone locked and AirDrop to the
Mac still need a look on a real iPhone."

**DESIGN 1.3**, new rows for 09:

| Mockup | Don't build | Build instead | Why |
|---|---|---|---|
| 09 | the recorder without a way out | a `chevron.down` (44 pt, secondary) before the course menu: Close before recording and after Stop, Hide Recorder while recording (recording goes on; the shell's Record opens it again) | the recorder is a full-screen cover; the mockup draws only the recording state |
| 09 | – | before recording: the same layout with "00:00", no dot, and one red 88 pt **Record** button (`circle.fill`) where Next slide will be; the row under it stays empty; a `tray.full` button (38 pt quiet fill) at the top right while the outbox has captures | 6.6: no copy; nothing moves when recording starts |
| 09 | – | after Stop: an inset grouped list, the finished capture first (course dot, title 17 semibold, "Tue 13 Oct · 37 stamps", SF Mono length) with a filled **Share**, then the other captures (rows with a share glyph; Delete… by swipe and context menu, asking "Delete “DC Lecture 2”?") | the one obvious next step is getting it to the Mac |
| 09 | the Live Activity's app tile and "Slide 17 of 88 · Lecture 2" | the course dot before the course name, "Slide 17 of 88 · DC Lecture 2" (the session name), [Next Slide] flexible (accent) and [Stop Recording] sized to its text (fill 2, red `stop.fill`) | PRD "iPhone recording" (course name, session name); "Stop Recording" does not fit 112 pt |
| 09 | – | Dynamic Island: expanded = the Lock Screen's content (title leading, time trailing, the two buttons below); compact = red dot + SF Mono elapsed / "S17"; minimal = the red dot; keyline red | 8.5 |

**DESIGN 6.7**: "The iPhone recorder (M7): every control at least 44 pt (the course menu and Stop
capsule keep their drawn 30–34 pt look inside a 44 pt target); the screen's background is the
system background (black in dark, as iOS screens are)."

**DESIGN 8.5** (Recorder, as built): "course menu [● Data Centers ⌄] (13 semibold course
colour on its 14 % tint) … [■ Stop] (red-soft capsule, 34 high), a leading `chevron.down`; a 76 pt
SF Mono light timer (tracking −3) with the 12 pt pulsing dot 26 pt to its left; 'Lecture 2 · Tue
13 Oct' 15 pt secondary; a 70 pt waveform (3 pt bars at a 6 pt pitch ending at the red playhead,
four samples a second, accent stamp lines with a 7 pt dot); 'Slide 17 of 88' (15 semibold + 13
secondary) over the slide (radius 10, the slide's hairline and shadow), 'Slide 17' alone without
a deck; the 88 pt Next slide (accent, radius 26, 25 pt semibold, `chevron.right`), then [‹
Previous] [Flag] (54 pt, radius 18, quiet fill, Flag's glyph red). Stop asks 'Stop recording?'
(Stop, destructive). A failed start shows Live's alert ('Microphone access is off' with Open
Settings, 'Recording is off for this course', …)."

**DESIGN 9**, strings: "Next slide", "Previous", "Flag", "Record", "Stop", "Stop recording?",
"Share", "Delete…", "Delete “DC Lecture 2”?", "37 stamps" / "1 stamp", "No Course" (the menu
without a course that may record); Live Activity "Next Slide", "Stop Recording", "Slide 17 of 88",
"Slide 17", "S17"; accessibility "Hide Recorder", "Close", "Back", "Recordings", "Course",
"Recording time", "Share".

**decisions.md**, rows to add:

| Date | Decision | Why |
|---|---|---|
| 2026-10-19 | The iPhone's outbox: the recorder's captures stay in `AppPaths.phoneCaptures` newest first (title, day, length, stamp count); after Stop the finished one shows with a filled Share; Share writes the bundle at share time into a temporary folder (cleared at the next share and at launch); Delete… asks and names the recording | the phone never imports (no transcription there); the Mac needs one file; nothing is kept twice |
| 2026-10-19 | The capture bundle is an uncompressed Apple Archive of one `<uuid>.lecture` folder, entries only type, path and bytes, the manifest and events first; unpacking refuses links, other entry types, absolute paths, `..`, `.`, a second root and a foreign root, into a hidden folder first | LPCM does not compress; the Mac reads the manifest while dragging; a file from AirDrop is untrusted |
| 2026-10-19 | A phone capture's course on the Mac: by the manifest's id when the library has it, else by the folded course name or short name (`capturedCourse`, weight 1); the session number stands in for a file number; the session by start time as before | the phone's course ids differ from the Mac's until sync |
| 2026-10-19 | Stop Recording on the Lock Screen stops at once; Stop in the app asks first | a Live Activity button cannot ask; the package is final either way |
| 2026-10-19 | Without a deck the phone counts slides from 1 (Previous never below 1, no upper bound) and stamps those numbers; with the class's deck on the phone the count stops at its pages; the Mac's deckless live screen does not count | the phone rarely has the deck before sync (blobs do not sync); Review lines the numbers up with the deck on the Mac |
| 2026-10-19 | The Live Activity updates only when what it shows changes (a slide stamp, the course), serially; its elapsed time counts by itself | battery on a 90-minute locked recording |
