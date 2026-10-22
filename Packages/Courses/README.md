# Courses

Milestone 1, workstream A: course setup (#1), weekly slots → lecture sessions → the app-owned "Socrates" calendar (#36), and a light Today (mockup 01).

No automated test suite at present; verified by building and rendering.

## Products

### `Courses` (pure logic, StudyCore only)
- `SessionPlanner().plan(slots:semester:existing:now:filed:) -> SessionPlan` (`inserted`, `updated`, `deleted`, `isEmpty`); `days(for:in:)`.
  - Days with the slot's weekday in `[max(lectureStart, validFrom), min(lectureEnd, validUntil)]` that are lecture days, with the `weekInterval` parity counted from the first slot weekday on or after `validFrom` (else the lecture start). Wall-clock times in the slot's time zone.
  - Generated sessions are matched by (slot, day) and updated in place. A leftover generated session moves in place onto a free planned day of the same course and kind in its week (weekday corrections keep ids, lecture links and events). Edited sessions are never changed (except `number`) and hold the nearest free planned day of their slot (≤ 21 days), so a cancelled or moved session is not planned again. Unplanned generated sessions are deleted only when in the future and no lecture or filing points to them.
  - `number`: per course and kind, non-cancelled sessions in start order are 1…n; cancelled ones nil.
- `CourseSchedule(services:)`: `replan(courseID:now:)`, `replanAll(now:)`, `save(_ slot:)`, `save(_ slots:)` (an .ics import), `deleteSlot(_:)`, `deleteSlots(_:)` (its Undo), `saveAdoptingSessions(_:)` (a slot made from one-off sessions takes them over instead of doubling their days), `save(_ semester:)`, and session edits `cancel`, `restore`, `move(_:startsAt:endsAt:room:)`, `addSession(courseID:kind:startsAt:endsAt:room:)` (each sets `editedAt`). Every call is one transaction (edit + reconcile + renumber). A replan with no changes writes nothing. `session(forRecordingAt:courseID:)`.
- `CourseLibrary(services:)`: `create(_ CourseDraft)` (the path the New Course sheet uses; also writes the course's default `mail_rule`s, `CourseDraft.mailRules(for:semester:)`: "Sender is" each lecturer without titles and, when the university profile names a learning platform, "<platform> course is" "<name> (<semester>)"), `save(_ course:)` (replans when the semester changed), `setRecordingConsent(_:courseID:)`.
- `CourseDraft` (name, lecturers, language, adminLanguage, colorHex, semesterID, records, rules; `palette`, `languages`, `names(from:)`, `shortName(for:)`).
- `GlossarySuggestions.vocabulary(_:)` → `GlossaryVocabulary` (`suggestions(excluding:dismissed:limit:)`, `completion(for:excluding:)`): offline, no model. Corrections first (transcript segments with `revision > 0`: words the student typed that the transcriber did not write, with the replaced words, lecture and time), then slide terms a transcribed lecture showed but its transcript never contains: acronyms (QEMU), inner capitals (VirtualBox, OS-level), and words on two pages or more without a dictionary entry (`Lexicon.knownWords`, NaturalLanguage lemmas, English and German), ranked by the seconds the lecture stayed on their slides. Title slides, running footers (> ⅓ of a deck's pages), links, stopwords and plurals of other terms are left out. Completions: every slide word, words the transcriber never wrote first.
- `ICSSlotImporter.slots(from:courseID:existing:timeZone:)`: weekly and fortnightly VEVENTs (`RRULE FREQ=WEEKLY[;INTERVAL=2][;BYDAY=…][;UNTIL=…]`, TZID/UTC/floating, DTEND or DURATION, escaped and folded LOCATION) → one `WeeklySlot` per weekday; kind from the title (Übung/Exercise, Tutorium, Seminar, else lecture); slots the course has are skipped.
- Timetable import (`Timetable.swift`, `TimetableImporter.swift`; a campus management system's `.ics`, one file per course unit): `TimetableParser.events(in:file:)` (UID, LV number, title, kind from CATEGORIES, short room = the LOCATION's first parenthesis, weekly series with interval, UNTIL/COUNT and EXDATE days, DESCRIPTION roles: "Klausurtermin N" exam N, "Klausureinsicht" review). `TimetableImporter(services:)`: `prepare(_ files:courseID:)` → `TimetableImport` (events deduped by UID; units grouped into courses: an existing course's name inside either side of a bilingual title, a unit whose title contains a grouped one's, else LV number + 1, else a new course named by the English side; weekly slots, one-off sessions, exam items merged per date and start; weeks every series skips (≥ 2 series) widen the semester's breaks; what the library has is left out), `apply(_:including:record:)` (one transaction: semester, new courses via `CourseLibrary`, slots, one-off sessions, replans, cancelled sessions for other skipped days, exam drafts through the app's recorder with the source relabelled `timetable` + file name).
- `SlotGuess.slot(courseID:sessions:timeZone:)`: the weekly slot a course's one-off sessions suggest (most common kind, weekday, start, length).
- `SessionMatch.session(forRecordingAt:in:)`: the non-cancelled session whose start is within ±30 min of the recording start, or that was running then; nearest start wins.
- `SessionText`: event titles ("Data Centers · Exercise"), list titles ("Data Centers Lecture 3", "Data Centers exercise"), 24-hour wall-clock times, "Mon 19 Oct". `Semester.current(among:on:)`.

### `CalendarSync` (EventKit, no AppKit/UIKit)
- `CalendarStore` protocol (`access`, `requestFullAccess`, `sources`, `defaultSourceID`, `calendars`, `createCalendar`, `event(id:calendarID:)`, `events(calendarID:from:to:)`, `save`, `removeEvent`); `EventKitCalendarStore` (an actor around one `EKEventStore`).
- `actor CalendarMirror(services:store:calendarTitle:defaults:)`: `requestAccess()`, `sync(full: Bool = false) -> CalendarSyncReport`, `hasCalendarWork(_:)` (M2). Since M2 it also mirrors tracked items that want an event (`TrackedItem.wantsCalendarEvent`): `url = socrates://item/<uuid>` (`url(forItem:)`, `itemID(from:)`), the item title at its due time (an hour for exams and events, all-day without a time: `CalendarEvent.isAllDay`), the exact quote as notes; the event goes when the item no longer wants one. `CourseSchedule.setRoom(_:room:now:)` applies a confirmed room change.
  - Calendar: the identifier remembered in `UserDefaults`, else an existing writable calendar with the title (iCloud first), else a new one in iCloud (then the default calendar's account, then local).
  - One event per session of a course with `showsInCalendar` that is not cancelled: title = course name (+ " · Exercise"/" · Tutorial"/" · Seminar"), location = room, `url = socrates://session/<uuid>`, no notes; `calendar_event_id` = `calendarItemExternalIdentifier`.
  - Removes events of cancelled sessions, hidden courses and orphans (only events with our URL prefix, only in our calendar). Marks sessions synced. With nothing changed (no dirty session, same set of session ↔ event ids) it makes no calendar calls. Without full access it does nothing and throws nothing. `full: true` re-reads every event (use at launch: repairs events deleted in Calendar).
  - A library relocated with `SOCRATES_DATA_ROOT` uses its own calendar "Socrates (<folder>)" and its own defaults keys.

### `CoursesUI`
`CourseSettingsView(courseID:changeDeck:importFiles:newCourse:)` (mockup 08: one scroll view, two 18 pt-spaced columns from 850 pt (one below 822), `SettingsGroup`s; glossary token field with slide completions and Suggested; Slides always shown; weekly slots with Import .ics (+ Undo) and a ghost row when empty; the Exam form row until one exists; mail rules on `mail_rule`; toolbar Import + More menu; M5 `showsChat:` adds ChatUI's Show Chat after that group, for the tutor inspector the app attaches with `showsToolbarItem: false`), `NewCourseView(onCreated:)`, `TimetableImportSheet(proposal:onImport:)` (the timetable drop's confirm sheet; `\.importTimetable` routes Course Settings' Import .ics to it), `SemesterSettingsView()`, `TodayView(now:record:)`, `CourseCommands(newCourse:)` (File ▸ New Course… ⌥⌘N), `EnvironmentValues.calendarMirror`. Screens write through `\.studyServices` and call `calendarMirror?.sync()` after changing sessions; they open lectures through `\.openDestination`.

#### Today (`TodayView`, `TodayData`, `TodayPlan`, `TodayComingUp`; mockup 01, docs/DESIGN.md §8.1; M3)
- **Data:** `TodayRequest` (one `FetchKeyRequest`, one transaction, follows every table it reads): courses; sessions from the day before through 8 days on; the review candidate and its course's next lectures; open items due from the start of the day through 21 days on, open items tied to the listed window's sessions, and later events with the course and title of an event in the window; their trails (`TrackedItemRepository.trails(itemIDs:in:)`); whether a `mail_account` exists and `MailRepository.unreadCounts(in:)`.
- **Plan (`TodayPlan`, pure):** the hero as before (review, else the next class; Record from 30 min before a consented class). **Coming up** is one list of `ComingUpEntry`s, soonest first (sessions before items at the same minute):
  - sessions that end after now and start within 8 days, other than weekly lectures (cancelled ones stay, struck through) and the hero's session or aside;
  - due items (`TrackedItemKind.isDue`: deadline, exercise, exam) with a `DueRing`, always their own row (tied to a session or not), timed ones until their time passes, all-day ones through their day;
  - events (and dated announcements) not tied to a session with the course bar; the same course and title on several days is one row, the first day over "and Fri 13 Nov" ("and N more" for several), their sources shown once;
  - **folding:** an event or announcement tied to a listed session is that session's row: the event names it ("First CL tutorial"), the gloss is the event's details, else an announcement's details, else its title; their sources join the row's glyph. Tied to a session that is not listed (a weekly lecture, the hero's, beyond 8 days): not shown. Room changes and cancellations (proposals) are Calendar's. Undated items other than folded ones are not shown;
  - a row's gloss is its item's details (one line); the amber `star` precedes it when an item is required for exam admission ("Exam admission" when there are no details); `undoSourceID` is the newest active source of the row's items that added one on its own (`calendar_added`) or changed it (`previous`); `inCalendar` when an item is in the calendar.
  - The **mail line** (`MailLine`) only with a mail account and unread inbox mail: the total, per course with unread mail its count in course order, and newsletters; University and unrouted mail count only in the total.
- **View:** three zones in the 600 pt column, 30 pt apart; rows are StudyUI `CourseBarRow`s (bar or ring, title 13 medium, gloss 12 grey, day 13 over SF Mono 11.5 time — a session's range, an item's due time, nothing all-day) with a `SourceTrailButton` after the last line (accent while the row is hovered; the popover's footer has the green check and Undo → `deadlineActions.undo`). Hover: `.fill.quaternary`, radius 9, the `Hairline`s beside it hidden. Context menus: sessions Cancel Session / Restore Session (`ScheduleActions`); items Mark as Done (`complete`), Add to Calendar (dated items not in the calendar, `addToCalendar`), Delete (`remove`), applied to every item of the row. The mail line: `envelope`, "**5 unread**", "·", 7 pt course dots with counts, "· 1 newsletter", trailing plain accent "Open Mail" → `openDestination(.mail(.inbox, message: nil))`; 42 pt over a hairline, 8 pt closer to Coming up. Nothing at all (no hero, no rows, no mail line): the `sun.max` glyph. No sparkle on Today in M3 (the hero's AI line is M4).
- **Effects:** every item effect goes through `\.deadlineActions` (the app wires them to the deadline memory); session effects through `ScheduleActions`; navigation through `\.openDestination`. Without the app's actions (previews, snapshots) the menus do nothing.
- Known gap: an event or announcement tied to the hero's own session (the next class when nothing is to review) is not shown on Today (the hero has no gloss line).

## Requests for the integrator (M3, Today)

Handled in the M3 integration: 1 (`\.deadlineActions` over every screen), 2 (DESIGN §7.1/§7.3); 3 stands (an off-screen render of a sample library shows the items). The list as written:

1. **Wire `\.deadlineActions` above `TodayView`** (plan §6.4), the same value Calendar gets; Today calls `undo`, `complete`, `addToCalendar` and `remove`. Sessions keep using `\.calendarMirror` through `ScheduleActions`.
2. **DESIGN.md §7.1/§7.3:** `DueRing` and `CourseBarRow` now exist in StudyUI (`DueRing.swift`, `CourseBarRow.swift`): list them in §7.1 and strike them in §7.3 (left out of this branch so it does not conflict with C's `ProposalCard` row there). §7.2 and §8.1 Today are updated here.
3. **App parity render:** the parity library holds no mail or tracked items, so its `01-today` render shows only sessions; a sample library with mail is the check for items and the mail line.

## Requests for the integrator

Handled in the M1 integration: one `CalendarMirror` on the Mac (`sync(full: true)` at launch, access asked once a course shown in the calendar has a session); the app's Today placeholder is gone; Course Settings is the course's page with `changeDeck` → `ChangeFilingSheet`; New Course is a sheet and `CourseCommands` is installed; `SemesterSettingsView` is in Settings; `CalendarMirror.calendarTitle(for:)` is public (the end-to-end tool reads the calendar). Not done: 5 (⌘N stays New Window), 6–8 (optional). The list as written:

1. **Wire the mirror (macOS only for now).** In `AppModel`, create one `CalendarMirror(services:)` and install it with `.environment(\.calendarMirror, mirror)`. At launch: `try await mirror.requestAccess()` once there is at least one weekly slot (or from a first-run moment of your choosing), then `try await mirror.sync(full: true)`; after imports `sync()`. Install it on **one device only** until the library syncs (M7): an iPad library has other session ids, and each device's orphan cleanup would delete the other's events.
2. **Replace placeholders.** Delete `App/Shared/DetailView.swift`'s `TodayView` (it shadows `CoursesUI.TodayView`) and show `TodayView(record: record)` with the RootView's `record()`. Show `CourseSettingsView(courseID:changeDeck:)` as the course's "Course Settings" item; `changeDeck` should open workstream B's `ChangeFilingSheet` for `FilingRepository.latest(deckID:)`.
3. **New course.** Present `NewCourseView { course in selection = .course(course.id) }` as a sheet and add `CourseCommands(newCourse:)` to `.commands`. The capture/import sheets can create courses through `CourseLibrary.create(CourseDraft(...))`; the app's own `CourseDraft` shadows `Courses.CourseDraft` until it is removed.
4. **Settings.** Add `SemesterSettingsView()` to the Settings window (it needs `\.studyServices` and `\.calendarMirror` in its environment).
5. **⌘N for "Add Slot"** (plan §3) is not bound: ⌘N is File ▸ New Window. If wanted, add a focused-value command; "Add Slot" is reachable with Tab/Space.
6. ~~StudyUI `TimeChip` with a lecture prefix~~: done; `LectureTimeChip` is gone.
7. **StudyCore:** a conditional `SessionRepository.markCalendarSynced(_:eventID:ifUpdatedAt:)`. `CalendarMirror` writes the same thing in its own transaction so an edit that lands while an event is written stays dirty instead of being marked synced.
8. Optional: handle `socrates://session/<uuid>` (and `studyportal://`, on events written before the rename) (`CalendarMirror.sessionID(from:)`) with `.onOpenURL` to open the session's lecture or course from Calendar.
9. ~~"Import .ics"~~: done (Course Settings ▸ Weekly slots).

## Requests for the integrator (UI parity, mockup 08)

Handled in the parity integration: 1; 2 (the "Course Settings" row shows under its course while
its settings are open, docs/decisions.md); 3. Not done: 4. The list as written:

1. **DetailView:** pass `importFiles: { model.filingCenter?.importFiles(to: .course(id)) }` (and `newCourse:`) to `CourseSettingsView` and drop DetailView's own Import toolbar item: the view then puts Import and its More menu (Import .ics…, Add Slot, Add Exam Rule, Add Mail Rule, New Course…) in one glass group, and an empty Slides group offers Import.
2. **Sidebar:** a "Course Settings" child row (gearshape) under each expanded course, selected on this screen (`SidebarItem.courseSettings`), parity route `course/<name>/settings` → that item; accent-tinted row icons; footer "+ New Course" left, semester right, below a separator.
3. **Toolbar:** back/forward chevrons (selection history, ⌘[ / ⌘]); no search field on course screens (mockup 08 has none).
4. **Mail rules of existing libraries:** courses created before `CourseLibrary.create` wrote default rules have none; `CourseDraft.mailRules(for:semester:)` gives them if wanted.

## Panes: the lecture notes page (Mac)

`LectureNotesPage` offers Your notes as a side pane, `.pane(.yourNotes, identity: lectureID)`,
drawn by the app's pane host beside the page (docs/DESIGN.md 6.4, 8.9). Gone: its `.inspector`,
Show Inspector, the per-window visibility (`YourNotesVisibility` and
`\.yourNotesVisibilityOverride` are no longer read; renders open the pane through the kind's
layout), the automatic open and close at 1160 / 1120 pt, the 1 pt strip above the scroll view
and the scroll offset kept across the expanded agent panel.

- **`LectureNotesPageState`** (`@Observable`, the page's `@State`) is what the pane reads: the
  current version's `sections`, the `readingSection` the notes report, `typingInColumn`, and
  Continue in Chat's `chatPassage`. The pane's content reads nothing else of the page.
- **Keys.** ↩ (Open in Review) stands down while a note in Your notes or the search field has the
  keyboard (`typingInColumn`, `\.isSearchFieldFocused`); the notes' ⌘K and ⇧⌘E are published only
  while the notes themselves have it.
- **Live resize.** While `\.isLiveResizing` is on, `NotesPageLayout` keeps the page width it had
  (the latest measure waits in the state, unobserved) and takes the new one once, when the drag
  ends.
