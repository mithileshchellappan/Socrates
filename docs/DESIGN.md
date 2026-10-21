# Socrates design guide

This is the design reference for every agent that builds or changes UI in Socrates. Read it before you touch a view. It turns product feedback, the approved mockups, `docs/PRD.md` (UI rules, trust rules) and `docs/decisions.md` into rules you can follow without asking.

The HTML mockups it cites by number or file (01–33, the agent panel, the study coach, `lecture-notes-mockups.html` and the other per-feature mockups), the maintainer's working plans (every `docs/plan-*.md`: plan-m1 … plan-docs, plan-translation, plan-lecture-notes, plan-learn-more), evals (`docs/eval/`) and research notes (`docs/research/`), the Python prototypes (`tools/prototype/`), and the parity render scripts that seed and compare them are not part of the public repository; references to them anywhere in the code and docs point at these unpublished files. `.data/` paths are local, git-ignored folders. The rules here stand on their own.

---

## 1. How to use this document

### 1.1 Precedence

1. An explicit decision of the maintainer.
2. The approved mockup of the screen, **except for the overrides listed for that mockup in 1.3**.
3. The rest of this document.
4. `docs/PRD.md`, `docs/decisions.md`, package READMEs.

All mockups are approved (PRD). Every deliberate deviation from one is listed in 1.3 with its reason. Anything not listed there is built exactly as the fragment draws it. When you settle something new, add a row to `docs/decisions.md` and update this file in the same change.

**Citing decisions.** `decisions.md` has no IDs and grows by insertion, so line numbers break. This file cites a row by its opening words, e.g. (decisions: "Found rows: In Calendar + Undo"). Find it with `grep -n`.

### 1.2 Screen status (main after the M7 integration)

| Screen | Mockup | Status |
|---|---|---|
| Today | 01 | built; parity approved on 2026-10-17; M3 adds deadlines and events in Coming up (the digest folded in), source popovers with Undo and the mail line (8.1); M3.5 adds open tasks and "Reply to …" rows to Coming up (its chat inspector gave way to the agent panel in ma, 8.6); M4 adds the hero's AI line "5 highlights, 3 not on the slides" (8.1) |
| Live lecture | 02 | built; approved |
| Lecture review | 03 | built; approved; M4 adds the study pass (8.1): Summary, Further reading, Exam hints and Only said in class in the inspector (and their Whole lecture lists), You / Professor / AI pins with their cards, struck-through corrections with Revert Correction, amber and purple scrub marks; checked off screen against mockup 03 (`.data/parity/m4/`: the live pass's summary, further reading, AI pin and corrections; `.data/parity/m4-b/`: mockup 03's rows for exam hints, said in class, professor pins and scrub marks); hover cards, Add Pin at the pointer and the inspector's vibrant greys still need a look in the real window; M5's third segment, Tutor, is gone again (ma: the agent panel, 8.6; the inspector is "This slide | Whole lecture"); M6 adds ink on slides (the toolbar's [Pen, Highlighter, (Eraser), Flag] group, P / H / E / F / Esc), the student's Flag, the rail's pencil for ink and rich "Your notes" (8.1); checked off screen against mockup 03 (`.data/parity/m6/`: slide 16's highlighter band, pen ring and You pin, the rail's pencils, the group); the highlighter's multiply over the slide's view, the toggled tools in the glass, ⌘Z after drawing, Esc, the crosshair and the eraser ring, Add Pin and pin cards with a tool on still need a look in the real window; mr: a lecture shows only its page range of a shared course deck (rail, stepper, ← / →, deck numbers "50 / 88", the meta "slides 38–88 of 88"; 8.1), checked off screen against mockup 03 (`.data/parity/mr/`: `mr-review-l3` DC L3 on 38 of 38–88 without a recording, ‹ off; `mr-review-l2` DC L2 on 16 of 1–37 at 37:27), light and dark |
| Search | 07 | built; approved; Mail segment added in M2; M5 adds "Also searched", the Web segment and group and multi-selection (8.1; the selected hits are the agent panel's context since ma, which removed the Tutor toggle and inspector); checked off screen with `--m5-sample` (`.data/parity/m5/`) |
| Course Settings | 08 | built; approved; ma: no chat of its own (the agent panel knows the course and its screen) |
| Import (drop, HUD, toasts) | 10 | built; approved |
| Course Lectures, Slides | – | built |
| Mail | 05 | built in `Packages/MailUI` and wired (M2); the remaining work is the deviations in 8.2; M3.5 adds the needs-reply marker (8.2); ma: the open message is the agent panel's context, and a session change the agent applied reads "In Calendar" with Undo |
| Agent panel (ma; replaces M3.5's chat inspectors and M5's tutor) | agent-panel-mockups.html | built in `Packages/ChatUI` (8.6) and wired to `AppAgent` (only with Claude Code): compact (movable) and expanded (the full-height right sidebar), the launcher in the sidebar footer, ⌘J / ⌥⌘J; Review, Calendar and Today publish their context, the app the rest; the chat inspectors, Review's Tutor tab, Search's Tutor toggle and Calendar's composer are gone. Checked off screen against the mockup's §1–4 (the parity render's M3.5 and ma samples); dragging the compact panel, resizing the column, drop and ⌘V, the expanded header over a real toolbar and streaming still need a look in the real window. M7: the iPhone sheet (`AgentSheet`, two heights) is built and relays to the Mac (`agent_request`), hidden until iCloud sync runs (a build with `SOCRATES_ICLOUD = YES`); checked in the simulator against §7 (`.data/parity/m7/sheet-*`, shown as available for the shot) |
| Settings ▸ Accounts | – | M3.5: the Claude API key section is gone; one quiet "Claude Code" row with the subscription or its state (9); M7: in a build that syncs, a quiet "iCloud" row under it ("Up to date", "Syncing", "12,480 to upload" with the count in SF Mono, "3 not uploaded", or why sync is off; counted every 5 s while it shows; nothing in a build without sync); then the uni mail account (Mac) |
| Calendar and deadlines | 06 | built in `Packages/CalendarUI` and wired (M3); checked off screen against mockup 06 (`.data/parity/m3/`); the inspector's vibrant colours, the hover popovers and keyboard focus still need a look in the real window. A click on a grid item opens its detail popover; exam reviews draw as blocks (8.3). ma: the "New deadline" composer is gone ([+] opens the agent panel); time changes and extra sessions in the detail popover |
| Notes | 04 | M6: built in `Packages/Notes` (`NotesView`, `NoteEditor` on TextKit 2) and wired: the Notes row after Mail with All Notes and each course with notes, a course's Notes screen (the same screen), Review's "Your notes" as rich notes, Search's note hits (8.4); checked off screen against mockup 04 (`.data/parity/m6/`); typing, input methods, paste and drop, sketch drawing, the Aa / Slide / Quote popovers, Delete with Undo and Move To still need a look in the real window |
| Study coach (mc): Today's plan hero, Study, a course's Progress, practice round, practice exam (sheet, exam, results) | study-coach-mockups.html 11–15, 17–19 | built in `Packages/Coach` (`CoachUI`, 8.7) and wired to the `CoachEngine` (Mac only): the Study row after Notes (Go ⌘6, Search ⌘7 since md; ⌘5 is Documents), a course's Progress row, full-window rounds and exams, results pushed on Progress. Checked off screen against mockups 11–15 and 17–19, light and dark (the parity render on the coach's seeded samples); the round's sidebar toggle and the exam's glass question bar (‹ ›, the ring on the current number, tertiary unanswered numbers) are glass and draw only in the real window; the sentence player, drag-and-drop labelling, the exam clock ticking, Pause / Resume, Submit's question, 0:00 handing in, the sheet's PDF drop and the keys still need a look in the real window |
| iPhone recorder, Live Activity, iPhone Today | 09 | M7: built in `Packages/Recorder` (`RecorderScreen`, `PhoneRecorder`), the `SocratesWidgets` extension (Live Activity: Lock Screen, Dynamic Island) and `Packages/Phone` (`PhoneShell`: the tab bar, the Record slot, a stack per tab, the header's search and agent bubble), Today at compact width (CoursesUI); wired as the iPhone's root (`App/iOS/PhoneRootView.swift`); smart import on the Mac files the phone's capture bundles (`.lecturebundle`, also opened from Finder or AirDrop). Checked in the simulator (light and dark) against mockup 09: the recorder (recording, after Stop), the Live Activity's Lock Screen view (on a drawn wallpaper) and the real Dynamic Island (compact), Today with the red Record slot; the real Lock Screen, taps (the Record slot must not morph the bar), recording on a device locked for 90 minutes, the Lock Screen buttons with the phone locked and AirDrop to the Mac still need a look on a real iPhone |
| Documents (md) | – | built in `Packages/Documents` (`DocumentsUI`, 8.8) and wired to the `DocumentBank` (Mac only; documents never sync, the iPhone has no Documents): the Documents row after Notes (Go ⌘5), the list and reader with the summary, key facts and dates, Quick Look, drop and Import…, Delete with Undo, the empty state; Search's Documents group; the agent panel's `[[doc …]]` chips; window drops of Word, RTF, Pages, text and images with the "Added to Documents" toast. Checked off screen, light and dark (the parity render: `md-documents`, `md-documents-cv`, `md-documents-pending`, `md-search` on `.data/parity/docs/library`, `md-documents-empty` on the M7 library; `.data/parity/md/`); the list's selected row draws no fill off screen (Notes' does), and Quick Look, drop, ⌫ and Undo, Read Again and the toast's Undo still need a look in the real window |
| Lecture notes (ln): a lecture's notes pushed on its course's Lectures; Review's Whole lecture with notes | lecture-notes-mockups.html 30–33 | built in `Packages/StudyPage` (`StudyPageFormat`, `StudyPageUI`: `LectureNotesView`, 8.9), `CoursesUI` (`LectureNotesPage`) and `ReviewUI`, wired to StudyPass's `NotesWriter` (the agent's task queue) and `NotesAsker` (`\.lectureNotesAsker`, only with Claude Code; Mac only). Checked off screen against 30–33, light and dark (`.data/parity/ln/renders/`: `30-lecture-notes`, `31-notes-select`, `31-notes-ask`, `32-notes-kept`, `33-notes-writing`, `33-notes-paused` on `.data/parity/ln/library`, and `03-review` with `--review-tab lecture`); the capsule's glass, the popover's real anchoring and arrow, hover chevrons, the context menu, ⌘K / ⇧⌘E, Keep, Undo, Continue in Chat and Follow in the real window still need a look. nl (2026-10-21, mockups 34–35, they win over 30–33): the page at the window's width (text 780, figures 1120, slides 640) with Your notes as its inspector column (`YourNotesColumn`), the student's notes and ink beside Claude's text and no longer in it (also in Review's Whole lecture), and View ▸ Zoom In / Zoom Out / Actual Size on the course screens' content; checked off screen against 34–35 light and dark (`.data/parity/nl/renders/`: `34-notes-wide`, `35-notes-closed`, `35-notes-open` on `.data/parity/nl/library`, `35-notes-empty` on `.data/parity/nl-empty/library`, `nl-notes-zoom-z130` at 130 %); resizing across 1120–1160, ⌃⌘I, typing in the column, the marking following the scroll, the agent panel over the column and the zoom keys still need a look in the real window |
| iPhone travel day (study coach) | study-coach-mockups.html 16 | M7: built: the plan card on the phone's Today and the practice round at compact width (CoachUI), the phone's coach without Claude (`CoachEngine(services:)`); checked in the simulator against 16 (`.data/parity/m7/`: Today, the round's first question and the same answered right) |

### 1.3 Overrides per mockup

Build each mockup as drawn except for these points.

| Mockup | Don't build | Build instead | Why |
|---|---|---|---|
| all | `.screen-head` (h2 and intro), `.feat` tags, `.callouts`, the intro `.legend`, the `.stage` wallpaper, the footer note, window frame, traffic lights, shadows | nothing; the system draws the window | gallery chrome, not UI. Callouts are design rationale and never become copy |
| all | the sidebar footer state "● 15:02" (05, 06) | nothing; a mail sync failure goes in Mail's toolbar subtitle | rejected "Mail checked 15:02" |
| all | a clock glyph for Today (03, 06, 07, 08) | `sun.max` | |
| all | proportional digits for list, chip, grid and event times (04, 05, 06) | SF Mono (3.2), except the date stamps listed there | PRD "SF Mono for times" |
| 01 | the "All in your calendar" aside | nothing | rejected copy |
| 03 | the manual-marker tick on dividers | Remove Marker in the line's menu | |
| 03 | every course open on the lecture's screen | only the lecture's own course opens (and stays open); the others keep the state their chevrons gave them (6.2) | the sidebar should not change on its own when a lecture opens |
| 04 | the note list in the sidebar (and the toolbar's toggle for it), group counts | the note list as the first column of the detail; Notes folders as sidebar children without counts (6.2); the sidebar toggle as on every screen (6.3) | rule 13: the sidebar is navigation only |
| 04 | slide and sketch floated with text wrapping around them | attachments inside the line, as in Apple Notes (8.4) | notes behave like Apple Notes |
| 04 | the glass "S13" tag on the slide clip | an opaque `SlideChip` | content is never glass |
| 04 | the orange done checkbox | accent | orange is the professor's |
| 04 | the table button | left out | the note model has no table |
| 04 | one glass group with a hairline between [Aa … sketch] and [Slide, Quote] | two glass groups (6.3) | each group is its own capsule (6.3) |
| 04 | the Aa button as a plain menu | a popover of Title, Heading, Subheading, Body in their own type, the current one checked, inside the first toolbar group | as Apple Notes' Aa; a toolbar `Menu` left the group's glass |
| 04 | the note text across the whole editor column | 52 pt in from the left, at most 680 pt wide, the stamp centred over it (3.3; 2026-10-20: a centred column left a big gap before the text in a wide window) | 14 pt lines stay readable once the sidebar and the list column take their room |
| 04 | the AI suggestion at the caret (grey text with a sparkle, the source, [Accept ⇥] [Dismiss]) | nothing; later | it costs a model call per typing pause (plan-m6 §8). The provenance rule for Claude's text in notes is settled since ln: the `ai` mark (5.1) |
| 05 | "Tutor" next to the sender | the sender's address | (decisions: "The reader shows the sender's address") |
| 05 | the "Ask about your mail ⌘J" bar | the agent panel (8.6), View ▸ Show Chat ⌘J | ma: one panel for the whole window |
| 05 | the mailbox section labels "Courses", "Other", "Mailboxes" | flat children of the Mail row (6.2) | (decisions: "Navigation: `StudyDestination.mail") |
| 06 | the Day and Month segments | Week only in M3; the segmented control comes with a second view | later milestone |
| 06 | "Mon 19 Oct · 23:59" | "Mon 19 Oct, 23:59" | one day + time format (9) |
| 06 | the flag glyph in all-day pills and deadline tags | no glyph | a flag is the user's flag (3.5) |
| 06 | a second grey line under a deadline row ("Dropping out after this costs 1 of 3 attempts") | in the row's popover | rule 3 |
| 06 | the old top-level rows "Lectures", "Review", "Notes" in the sidebar; the inspector header's ⋯ | the app's sidebar (6.2); no ⋯ until it has items | |
| 09 | several sparkles, "Added" next to Undo, two chips on a row, "in 5 days" lines | section 4 applied | drawn before the density pass |
| 09 | the Live Activity's [Next slide] [Flag] | exactly two buttons, [Next Slide] [Stop Recording]; Stop there stops at once (a Lock Screen button cannot ask), Stop in the app asks first; Flag stays in the app | PRD "iPhone recording" |
| 09 | the recorder without a way out | a `chevron.down` (44 pt, secondary) before the course menu: Close before recording and after Stop, Hide Recorder while recording (recording goes on; the shell's Record opens it again) | the recorder is a full-screen cover; the mockup draws only the recording state |
| 09 | – | before recording: the same layout with "00:00", no dot, and one red 88 pt **Record** button (`circle.fill`) where Next slide will be; the row under it stays empty; a `tray.full` button (38 pt quiet fill) at the top right while the outbox has captures | 6.6: no copy; nothing moves when recording starts |
| 09 | – | after Stop: an inset grouped list, the finished capture first (course dot, title 17 semibold, "Tue 13 Oct · 37 stamps", SF Mono length) with a filled **Share**, then the other captures (rows with a share glyph; Delete… by swipe and context menu, asking "Delete “DC Lecture 2”?") | the one obvious next step is getting it to the Mac |
| 09 | the Live Activity's app tile and "Slide 17 of 88 · Lecture 2" | the course dot before the course name, "Slide 17 of 88 · DC Lecture 2" (the session name), [Next Slide] flexible (accent) and [Stop Recording] sized to its text (fill 2, red `stop.fill`) | PRD "iPhone recording" (course name, session name); "Stop Recording" does not fit 112 pt |
| 09 | – | Dynamic Island: expanded = the Lock Screen's content (title leading, time trailing, the two buttons below); compact = red dot + SF Mono elapsed / "S17"; minimal = the red dot; keyline red | 8.5 |
| 09, 16 | the header's search and bubble as 38 pt fill circles beside the large title | the navigation bar's trailing glass buttons (the bar row above the large title; it collapses to the inline title when scrolled) | native components |
| 09, 16 | the Record button as an overlay beside the tab bar | the tab bar's own separate circular slot (iOS 26's search-role tab, never selected): glass, a red dot; a red waveform while recording | the system bar keeps its own width and glass |
| 09, 16 | the mockup's #1e1e20 phone background | the system background (black in dark, as iOS screens are) | native |
| 10 | the Today drawn behind the drop (date tile, "Due" list) | Today as in 01 | the old, crowded Today |
| 10 | the predicted course opened in the sidebar, its lecture rows as titles only | the sidebar as it was before the drag; the predicted row lit only if it shows, the row under the cursor lit over the sidebar (6.2) | dragging a file over the sidebar was unreliable (rows opened, closed and changed height under the cursor) |
| 07 | "Save to notes" under an answer | Copy alone (markers become their labels: "S13", "37:59", "intel.com") | not built yet; the provenance rule it waited for is settled (ln: the `ai` mark, 5.1) |
| lecture notes 30 (nl: 34–35) | the notes as the detail of a list + detail split on the course's Lectures; a 680 pt column | the Lectures list full width; a row pushes the notes as a full-width page in the same stack (the Lectures row stays selected, the toolbar's Back returns). nl: the text grows with the page to at most 780 pt (14 pt on 21.7), code, tables, diagrams and charts break out to the page's width up to 1120, a slide up to 640 centred; Your notes is the window's inspector column beside it (3.3, 6.4, 8.9) | 2026-10-20: the notes take the full space and Back returns; 2026-10-21 (nl): the page left most of a wide window empty |
| lecture notes 31–32 | "Add to Notes" | **Keep** (⌘↩) | ln decision: it keeps the answer in the lecture notes, not in the app's Notes |
| lecture notes 31 | the popover's answer streaming in the render | the render draws the popover in place with a canned, finished answer (`\.lectureNotesPreview`) | an off-screen window draws no popover, and renders never call a model |
| 07 | the composer's globe | nothing | the agent researches the web through a research task when asked (a rule, not a control); the paperclip is the agent panel's (8.6) |
| 03 | only [Pen, Highlighter, Flag] while drawing | an Eraser (`eraser`) toggle that joins the group after Highlighter while Pen or Highlighter is on (toggling it off returns to that tool) | ink needs a way out without ⌘Z; shown only while drawing, so the group at rest stays as drawn |
| agent panel | the toolbar's chat bubble | ONE launcher (`bubble.left`) in the left sidebar's footer before the Settings gear (on a course's screen after the semester), tinted while the panel is open; while the sidebar is collapsed it floats at the window's bottom-left (32 pt glass, 12 from the edges) | an approved change to the mockup: the same on every screen |
| agent panel | expanded as a 336 pt column inside the detail | the window's full-height right sidebar (its inspector column), resizable by its leading edge 300–560 (ideal 380, the width kept); on Review and Calendar it takes their inspector's place | an approved change to the mockup |
| agent panel | compact inside a 336 pt column | a window overlay 12 pt from the window's bottom-trailing corner, movable by dragging its title row (the place kept per window, clamped into the window) | an approved change to the mockup (movable) |
| agent panel | a title row with ⤢ only | the title as a menu (recent conversations by day, New Chat, Memory…), ⤢ Expand and Close (`xmark`, "Hide Chat") | the panel has to close without the launcher (Live has none; the sidebar may be collapsed) |
| agent panel | "Tue 13 Oct" for a conversation three days back | "Today", "Yesterday", the weekday within the week ("Tuesday"), then "Tue 13 Oct" | the Notes list's day rule (9) |
| agent panel | the prompt turning to "Ask a follow-up…" after any answer | the prompt names the context ("Ask about this week") and turns to "Ask a follow-up…" only after a question in the same opening of the panel | the panel opens on a stored conversation; renders of it show the context prompt as the mockup does |
| agent panel | sent file tiles with the name only | the name with "3 pages" (PDF) or the size (text) | the student sees what went |
| agent panel | the change row's popover as sender + subject line | `SourceTrailPopover` (the source, the exact quote with its time, Undo); an undone row struck through in tertiary | the one source affordance (5.2) |
| agent panel | – | the task line is text only ("2 tasks running"), its list a popover with Cancel | no glyph needed |
| agent panel | the screens keeping a bottom inset under the compact panel; the "p. 2" chip into a sent PDF; Calendar's dashed preview from the panel's text; the panel in Live's window | not built yet (only the filing toasts move above the compact panel) | later (no marker for PDF pages yet) |
| agent panel (§7) | the iPhone sheet shown on every phone | built (`AgentSheet`), presented from the shell's bubble; absent (no bubble, nothing disabled) until iCloud sync runs (`AgentPanelActions.relay(isAvailable:)`) | the phone never runs Claude: its questions reach the Mac through sync |

### 1.4 Rules that come from past mistakes

- **Build to the spec.** A built screen matches its spec (section 8) and its mockup: its layout, sizes and hierarchy. Render and compare (section 11) before you call it done.
- **Design every empty state.** A new library starts empty. Every screen's empty state invites the next action (6.6); check it as well as the screen with content (11.1).
- **Callouts are rationale, never copy.** Most rejected copy was a callout turned into a label. Build the behaviour a callout describes; never render its text.
- **Leave later milestones out.** A control for a feature of a later milestone is left out, not shown disabled or empty.
- **Reuse, don't rebuild.** Check section 7 first. A piece that is private to one package moves into StudyUI when a second package needs it. It is never copied.
- **Keep it lean** (11.1): one implementation pass, one build, one render.

---

## 2. Principles

1. **Calm and native.** It should feel like a first-party macOS 26 app: `NavigationSplitView` plus inspector, system Liquid Glass, SF text styles, semantic colours, standard controls. Nothing decorative.
2. **No self-explanatory UI.** No copy that explains the system, its rules or its state when the UI already shows it. Trust lives in behaviour, not text.
3. **One obvious first thing per screen.** One filled button or one emphasized card.
4. **Provenance by typography.** How a line looks tells who wrote it: the user's text is primary, AI text is grey with one sparkle, the professor is marked in amber.
5. **Every fact once** per screen, in the place it belongs.
6. **Keyboard-first.** Every frequent action has a menu command and a key. Plain keys never fire while the user is typing.
7. **Never block on the model.** Nothing waits for Claude or Whisper before it can be used. Results stream into place. No spinners.
8. **Fast.** Cold launch under 1 s, slide switches without hitches, no blank frames.

### Rejected copy and what does the job instead

| Rejected copy | What carries the meaning instead |
|---|---|
| "Recording approved by the lecturer" | The "Record this course" switch in Course Settings. Record appears only for courses with consent. |
| "Rough live pass. The accurate transcript replaces it after class. Dotted words are low confidence." | Settling words are tertiary, unsure words have a dotted underline. After class the review transcript simply takes over. |
| "Reply drafted by AI" | Grey body text with one sparkle. Words the user edits turn primary. |
| "The agent drafts. Only you can send." | Send is the one filled button, and the agent has no send tool. |
| "Deadlines go in automatically. Other changes ask first." | An automatic deadline shows the in-calendar mark with Undo (in Mail's found row, or in the popover on Today and Calendar). Other changes arrive as proposals with Confirm (5.3). |
| "Sends nothing, invites no one" | Events go only into the app's own "Socrates" calendar, and there is no invitee field. |
| "All in your calendar" | The green `calendar.badge.checkmark` glyph in the source popover's footer, no text (mockup 01). |
| "Mail checked 15:02" | Nothing at rest. A failure shows in Mail's toolbar subtitle ("Offline", "Sign-in failed"). |
| "covered above" | Nothing. The fact appears once, where it belongs. |

**Test before you write a string:** if it explains what the app does, why, or what state it is in, and the screen already shows that, delete it.

---

## 3. Tokens

### 3.1 Colour

Use semantic and system colours. Literal colour values live only in StudyUI (course colours, `Color.professor`, `Color.ai`) and in CaptureUI's `LiveColors.swift` (content, canvas and inspector backgrounds; promote them to StudyUI on second use). Everything else is a recipe over those (table "Tints"). The accent is the user's system accent: `AccentColor` has no value, so never hard-code `#007aff`.

**Surfaces**

| Token (mockup) | Light / dark | SwiftUI | Used for |
|---|---|---|---|
| Content (`--win`) | #ffffff / #1e1e20 | `textBackgroundColor`, today as `Color.contentBackground` (CaptureUI, internal) and `Color.fieldBackground` (CoursesUI, internal); merge into one StudyUI `Color.contentBackground` | main content, Course Settings, filmstrip, the Calendar grid |
| Card | system | `.background.secondary` with a 0.5 pt `.separator` stroke | Today hero (radius 14), mail draft (12), attachment tile (10), proposal card (12) |
| Canvas (`--win2`) | #f6f6f8 / #252528 | `Color.canvasBackground(_:)` (StudyUI, M6); CaptureUI keeps `Color.liveCanvasBackground` (internal; it does not depend on StudyUI) | Live canvas, note sketch background |
| Settings group | primary at 3.5 % | `SettingsGroup` | Course Settings groups |
| Inspector | system | the `.inspector` column's own background. Only Live uses the opaque `Color.inspectorBackground` (#f8f8fa / #222225). | Review, Calendar; Live |
| Sidebar, glass | system | the `NavigationSplitView` sidebar; 3.4 | never draw either yourself |

**Text, lines and fills**

| Token | Light / dark | SwiftUI |
|---|---|---|
| Label / secondary / tertiary | #1d1d1f, #6e6e73, #a1a1a6 / #f5f5f7, #a1a1a6, #6e6e73 | `.primary` / `.secondary` / `.tertiary` |
| Separator | black 9 % / white 10 % | `.separator`, drawn as a 0.5 pt `Hairline` inside content. `Divider` is twice as heavy: use it between columns. |
| Quiet fill (`--fill`) | rgb(120,120,128) at 10 % / 20 % | `QuietFill`, a custom `ShapeStyle` (SearchUI, internal; promote it). It is **not** `.fill.quaternary` or `.quaternary`, which are other greys. Used for the segmented track, the selected search hit, weekend columns, the selected inspector row. Today's approved row hover uses `.fill.quaternary`; leave it. |
| Fill 2 (`--fill2`) | the same grey at 17 % / 30 % | no helper yet; add it next to `QuietFill`. The mockups use it for default buttons and the user's chat bubble. |

**Colours with a reserved meaning**

| Role | Light / dark | SwiftUI | Reserved for |
|---|---|---|---|
| Accent | system | `.tint` | the one filled button, time chips, the current transcript, caption or stamp line, Follow on, focus rings, drop targets, sidebar glyphs, the user's pin, checked checkboxes, unread dots |
| Red | #ff3b30 / #ff453a | `.red` | Record, Stop, the recording dot, the user's flags on a lecture moment, and an error shown under the field it concerns (a failed send, an account sign-in) |
| Green | #28a745 / #30d158 | `.green` | switches on, ready, the in-calendar check, mic level, an inserted correction |
| **Professor amber** | **#f08a00 / #ff9f0a** | `Color.professor` | professor pins, quote bars, the exam star and exam chip, exam scrub marks, spoken and slide search glyphs. Never system `.orange`, never anything else (not "busy", not done checkboxes). |
| **AI purple** | **#8a56d1 / #bf8cff** | `Color.ai` | the sparkle, AI pins, "Suggested", off-slide bars and marks, the dotted underline on found mail sentences. **AI text itself is `.secondary`, never purple.** |
| Highlighter | rgb(255,214,10) at 45 % / 40 % | `Color.highlighter(_:)` (StudyUI, M6; SearchUI's `MatchInk` resolves to it) | search match highlight, the note highlight, the highlighter's ink (on a slide 45 % multiplied over the white paper in both appearances) |
| Your ink (M6) | #0a5bd6 / #5aa2ff | `InkView` / `InkCanvas` (StudyUI) | pen strokes on slides (always #0a5bd6: the slide is white paper) and in sketches |

**Tints** (recipes; never mix a new literal)

| Tint | Recipe | Used for |
|---|---|---|
| Accent soft | accent at 12 % / 24 %: `Color.accentSoft(_:)` (StudyUI, internal; make it public) | chip and current-line backgrounds, toggled glass buttons, tokens, drop highlight |
| Professor soft | `Color.professor` at 14 % / 20 % | the exam chip (amber text and star on it) |
| AI soft | `Color.ai` at 12 % / 18 % | nothing yet; use this if an AI fill is ever needed |
| Red soft | `.red` at 12 % / 20 % | the iPhone Stop capsule |
| Course tint | `Color.course(c)` at 15 % drawn on the content background (all-day pills 14 %) | Calendar events and deadline tags |
| Course text | `Color.course(c).mix(with: .primary, by: 0.35)` | text on a course tint |
| Course sub-text | `Color.course(c).mix(with: .secondary, by: 0.6)` | the room line in an event |
| Proposal dash | 1 pt dashed stroke, course colour at 75 % | the "Room 5?" tag in an event, a typed preview |
| Code tokens (ln) | `NotesInk.token(_:)` (StudyPageUI): keywords `.pink` mixed 22 % toward the label, semibold; types and calls `.teal` 34 %; strings `.indigo` 26 %; numbers `.brown` 14 %; comments grey 50 % at 85 %; the rest the label ink; SF Mono 12.5 on the quiet fill, radius 10 | code blocks in the lecture notes and Ask answers (`CodeLexer`, 12 language families) |

**Course colours** (`CourseDraft.palette`): `#0a84ff #2fae55 #e0457b #5e5ce6 #30b0c7 #bf5af2 #a2845e #00c7be`. Always go through `Color(hex:)` / `Color.course(course)`, which is dynamic. The first three have hand-set dark values (`#409cff #3fd06b #ff6b9a`); every other colour gets +0.14 brightness and ×0.86 saturation in dark mode. `Color.course` falls back to the accent.

**Slides stay white in dark mode.** They are pre-rendered PDF bitmaps.

### 3.2 Typography

Use SF text styles. macOS sizes: largeTitle 26, title 22, title2 17, title3 15, headline and body 13, callout 12, subheadline 11, footnote, caption and caption2 10. Use a raw size only where this table gives one. Never set SF Pro Display yourself.

| Role | Style | pt / weight |
|---|---|---|
| Screen title (toolbar) | `.screenTitle` → `.title3` semibold | 15 / 600 |
| Toolbar subtitle | `.subheadline`, secondary | 11 |
| Hero title | `.title.weight(.semibold)`, tracking −0.3 | 22 / 600 |
| Mail subject (reader) | `.system(size: 17, weight: .semibold)` | 17 / 600 |
| Zone header | `.title3.weight(.semibold)` | 15 |
| Group header | `.body.weight(.semibold)` | 13 |
| Row title | `.body.weight(.medium)`; mail sender and note list `.semibold` | 13 |
| Body, transcript | `.body` | 13 |
| Inspector text, captions, AI blocks, popover names, attachment names | `.system(size: 12.5)` (names medium) | 12.5 |
| Agent answer words (8.6) | `.system(size: 13)` (phone 15), line spacing 3 (phone 4), in the answer grey `AnswerInk.body`: #6e6e73 / #a1a1a6 as a solid colour (4.8:1 / 6.2:1 on the panel's #f8f8fa / #222225), never the hierarchical `.secondary` (vibrant in the inspector column; black 49.8 %, 3.9:1, on the compact panel); italics stay grey | 13 |
| Agent answer emphasis | bold, headings and table headers in the label ink `AnswerInk.emphasis` (#1d1d1f / #f5f5f7): bold as Markdown draws it, headings semibold (`#` and `##` 1 pt over the words), table text 1 pt under the words with a semibold header | 13, 14 |
| Agent answer code | SF Mono 1.5 pt under the words in the label ink, the words' weight kept; inline on the quiet fill as the run's own background (it draws in selectable text; no radius, no padding); blocks on `QuietFill`, radius 8, padding 8/10, scrolling sideways (2026-10-20: the mockup's `.ans code` inherited the grey with no fill) | 11.5 |
| Agent answer list markers, quote bar | bullets (• ◦) in `AnswerInk.quiet` (#a1a1a6 / #6e6e73), numbers ("3.") in the answer grey, right-aligned in one column; a quote's 2 pt bar in `AnswerInk.quiet`; table hairlines: a full one under the header, half-strength between rows | 13 |
| Secondary line, field labels, small buttons, mail snippet, mail date | `.callout` or `.system(size: 12)`, secondary | 12 |
| Meta, section labels, transcript time | `.subheadline` (section labels semibold secondary) | 11 |
| Chips, thumbnail numbers, divider ranges | `Font.chip`, SF Mono 10.5 (StudyUI, internal; make it public) | 10.5 |
| Language badge | `.caption2.weight(.semibold)`, secondary, 0.5 pt separator border, radius 4 | 10 |
| Mail list time | SF Mono 11.5 for the clock; 12 text for "Yesterday" and days | 11.5, 12 |
| Calendar day header | weekday 11 secondary + date 15 semibold; Sat/Sun stacked 10 tertiary over 12 medium secondary | |
| Calendar event, tag, pill | 11; title semibold, time mono; pill medium | 11 |
| Calendar hour labels, "all-day" | 10 tertiary, hours mono | 10 |
| Note title (M6) | `.title.bold()` | 22 / 700 |
| Note heading, subheading (M6) | `.title2.weight(.semibold)`, `.title3.weight(.semibold)` | 17, 15 |
| Note body (M6) | `.system(size: 14)`, line height 21.7 pt (14 × 1.55) | 14 |
| Note stamp (M6) | `.subheadline`, tertiary, centred | 11 |

**SF Mono for every clock or duration value**, with `.monospacedDigit()`: recording clocks, clock-of-day times, ranges, durations, chips, the player, transcript and caption times, slot times, due times, mail list times, Calendar hour labels and event times, Notes list times. Days and dates ("Tue 20 Oct") stay in the text font; only the clock part is mono.

**Exception: date stamps** read as dates and stay proportional with tabular digits (`.monospacedDigit()`): the sidebar's next-session line "Mon 19 Oct, 12:15" (decisions: "The sidebar's next-session line is proportional"), the mail reader's date "Today, 13:37", the note stamp "16 October 2026 at 09:41".

For a mono time use `.system(size:, design: .monospaced)` plus `.monospacedDigit()`. `Font.chip` is internal to StudyUI and MailUI's `.mailMono(_:)` repeats the idea: make one StudyUI mono helper public instead of adding a third.

### 3.3 Sizes, spacing, radii

**Window and columns**

| Element | Value |
|---|---|
| Main window columns | sidebar 200–320, the screen (detail) at least 480, Mail 700 (its 318 list and a reader whose found rows, route menu and margins need about 380) (ideal 720), the agent's right sidebar 300–560. The screen's minimum is declared per screen (`WindowColumns.detailMin(for:)`, from the selection, so it changes in the same update as the screen: the detail column's own `frame(minWidth:idealWidth: 720)`, the split view's `frame(minWidth: screen + the sidebar while it shows)`, the agent's `AgentPanelRoom` and `SidebarFit`), never measured from a screen's content; the window's minimum is the sidebar + the screen's minimum + the agent's column (`.windowResizability(.contentMinSize)`). When space runs out: the screen narrows to its minimum and adapts, then the agent's sidebar opens narrower (down to 300), then the sidebar hides while the agent's sidebar shows (6.1); opening Mail with the agent's sidebar where sidebar + 700 + 300 do not fit hides the sidebar too (the panel stays expanded) |
| Sidebar column | min 200, ideal 228, max 320; row pitch 29 pt (`.sidebarRowSize(.small)`, `SidebarRowLabel` minHeight 21) |
| Inspector | 336 (min 260, max 440); header 52, level with the toolbar |
| Toolbar | 52 high; glass groups are capsules |
| List column (Mail, Notes) | Mail 318, Notes 236, fixed; a `Divider` after it (6.1) |
| Today column | max 600, centred; top 26, bottom 16, sides 20; 30 between zones |
| Course screens | max 760, margins 22 |
| Course Settings | two columns from 850 pt, one below 822 (`onGeometryChange`, a band so a width near them never flips the layout; 822 = two 380 pt columns, the gap and the margins), column gap 18, group gap 14, margins 22; Name and Lecturers fields 236 pt, down to 140 in a narrow column; long rooms and mail rule values truncate |
| Search | leading margin 18, trailing 14, group gap 14, hit padding 6/10; no max width (the Search README's 868 pt cap is not built) |
| Mail reader | padding 26 left and right, 4 top; 12 between blocks |
| Note document (M6) | text 52 pt in from the left, at most 680 wide (Apple Notes); the stamp centred over the text |
| Lecture notes page (nl) | D = the screen's width, C = D less Your notes while it is open; margins m = 52 (22 when C < 640); measure min(C − 2m, 780 z), breakouts (code, tables, diagrams, charts) min(C − 2m, 1120 z), the prose inset (breakout − measure) / 2 on each side, a slide min(breakout, 640 z) centred; z = the content zoom. 1600 pt window, open: C 1028, text 780, figures 924; 1180, closed: 780 / 840; 1180, open: C 608, m 22, text 564, no breakouts. Header and Keep in mind at the measure. Review's Whole lecture: text = figures = the pane |
| Your notes column (nl) | the page's inspector, 336 (260–440); open by default from D ≥ 1160, closed under 1120, unchanged between; padding 14 / 16; the lecture's own note first (empty: 96 pt on the quiet fill, radius 9), a hairline, then one group per slide: the chip in a 34 pt column, the ink thumbnail 176 × 99 (× z), the notes 7 apart; the reading section's groups share one quiet-fill run (radius 9, 8 pt out from the text) |
| Calendar grid (M3) | gutter 44; day header row 40; all-day row 28; 56 pt per hour; Sat/Sun 36 wide |
| Review | rail 96, leading 8 (16 without a deck), trailing 16, top 2; the slide takes at most about half the height |
| Live | filmstrip 92 pt thumbnails; inspector 280 / 336 / 440 |
| Player capsule | 44 high, inset 16 left and right and 14 at the bottom; content reserves `PlayerBar.height + 14 + 8` |
| Floating cards | HUD 236 wide; toasts up to 444 wide; source popover about 264 wide |
| Thumbnails | search 64; file tile 38 |

**Rows**

| Row | Spec |
|---|---|
| List row | padding 9/12 (Today 9/10), radius 9 hover fill |
| Mail list row | top 8, bottom 9; 8 pt unread dot column; system list selection (`.inset` list) |
| Note list row (M6) | padding 7/10; system list selection |
| Settings row | at least 32 pt (`.settingsRowPadding()`: minHeight 22, padding 5/12) |
| Lecture list row | minHeight 50 |
| Transcript line | 54 pt time column, padding 4.5/8, about 25 pt pitch |
| Caption line | 34 pt time column |
| Found row (Mail) | minHeight 28 |
| Separators | inset to start at the text, not the marker (Today 32 leading / 10 trailing; groups 12 / 12), hidden beside a hovered row |
| Hit targets | at least 28 pt in the Mac toolbar, 44 pt on iOS |

**Radii**

| Radius | Where |
|---|---|
| 16 | window (system), HUD, toasts (`.filingGlass`) |
| 14 | Today hero card |
| 12 | popovers, pin cards, proposal card, mail draft |
| 10 | settings groups, search selection block, attachment tile, note images and sketches, the agent panel's composer tiles (its composer 12, its compact panel 14) |
| 9 | list rows, Today rows, inspector rows, large buttons |
| 8 | thumbnail cells (the slide inside is 3) |
| 7 | small buttons, inputs, current transcript line, sidebar drop highlight |
| 6 | slide on stage, fields, card buttons, Calendar events and deadline tags |
| 5 | Calendar all-day pills |
| capsule | chips, toolbar glass groups, player, search field, the quoted-text "…" control |

### 3.4 Materials and Liquid Glass

- Use Liquid Glass **only through system components**: toolbar items (grouped with `ToolbarSpacer(.fixed)` / `.flexible`), the sidebar, and `.glassEffect(.regular, in: .capsule)` (`.interactive()` for buttons) on floating controls.
- Floating glass controls: the review player, the slide stepper, the drop HUD, filing toasts, the "Ask about your mail" bar (M5), the iPhone tab bar and Live Activity (M7).
- Content is never glass. Hero card, proposal cards, settings groups, mail draft, inspector blocks and note attachments are opaque. Never put glass on glass.
- Never hand-draw blur, glass, shadows or window chrome. The single exception is the slide: a hairline plus a soft drop shadow (0 1 3 at 18 %).
- Review and Live hide the toolbar band (`.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`).
- **Snapshot chrome.** Off-screen rendering draws neither glass nor window chrome, so each package has a switch: ReviewUI `\.reviewChrome` + `.reviewGlass(in:floating:)`, FilingUI `\.filingDrawsOpaqueGlass` + `.filingGlass(cornerRadius:)`, MailUI `\.mailChrome` + `MailGlass`. Calendar and Notes must not add a fourth: first promote one StudyUI switch, `\.studyChrome` (`.window` / `.snapshot`) with `.studyGlass(in:)`, then use it.

### 3.5 Icons

SF Symbols only, matched to the weight of the text beside them. Small toolbar glyphs use `.imageScale(.small)` (`ToolbarGlyph`).

| Meaning | Symbol |
|---|---|
| Today, Calendar, Mail, Notes (M6), Search | `sun.max`, `calendar`, `envelope`, `note.text`, `magnifyingglass` |
| Course screens: Lectures, Slides, Notes, Course Settings | `waveform`, `display`, `doc.text`, `gearshape` |
| Mail scopes | Inbox `tray`; a course its `CourseDot`; University `graduationcap` (outline, sidebar only); Newsletters `envelope`; Personal `person`; Other `tray.2`; Drafts `doc`; Sent `paperplane` |
| Mail actions | Reply `arrowshape.turn.up.left`, Archive `archivebox`, Flag / Unflag `flag` / `flag.slash`, New Message `square.and.pencil`, Send `paperplane.fill` (in the filled button), quoted text `ellipsis` in a capsule, learning platform file `doc.richtext` |
| Attachments | `doc.richtext` (PDF), `photo`, `waveform`, `film`, `doc.zipper`, `rectangle.on.rectangle`, `tablecells`, `doc.text`, `doc` |
| Found rows (Mail) | in calendar: green `checkmark` + "In Calendar" (mockup 05); Add to Calendar `calendar.badge.plus`; Undo `arrow.uturn.backward`; Restore `arrow.uturn.forward`; a proposal chip in the list `calendar` |
| In calendar, in a popover footer (Today, Calendar) | `calendar.badge.checkmark`, green, no text (mockup 01) |
| Sources: recording, mail | `waveform`, `envelope` (both when they agree) |
| AI, professor, you | `sparkle`; `graduationcap.fill`, only in an amber pin; `person` (Live note pin: `pencil`) |
| Exam, web, selection context | `star` (amber), `globe`, `link` |
| Record | `circle.fill` in red: Today's toolbar and hero (mockup `i-record`). `record.circle`: the Live window's Record button and its no-session empty state. |
| Stop, play, skip | `stop.fill`, `play.fill` / `pause.fill`, `gobackward.15` / `goforward.15` |
| Flags | the user's flag on a lecture moment: `flag.fill` red (Live stamps, Review scrubber). A flagged mail: `flag.fill` secondary. **Deadlines never use a flag.** |
| Undo, add, more | `arrow.uturn.backward`, `plus`, `ellipsis` |
| Sidebar, inspector | `sidebar.left`, `sidebar.trailing` |
| Ink (M6) | Review's toolbar: Pen `pencil.tip`, Highlighter `highlighter`, Eraser `eraser`, Flag `flag`; the rail's `pencil` marks a slide with notes or ink |
| Notes (M6) | New Note `square.and.pencil`; Aa ⌄ (text, not a glyph); `checklist`; Image `photo`; Sketch `pencil`; Slide `display`; Quote `waveform`; All Notes `doc.text`; a sketch's tools `pencil.tip`, `highlighter`, `eraser` |
| Agent panel (ma), recent search, tag | the launcher `bubble.left` (tinted while open); Expand / Shrink `arrow.up.left.and.arrow.down.right`; Close `xmark`; a task result's line `checklist`; `clock`, `tag` |
| Agent panel composer (ma) | `paperclip`; Send `arrow.up.circle` (19 light, accent outline, only with text or a file); Stop `stop.circle` (secondary, while the agent works); tiles `doc.richtext` (PDF), `doc.plaintext` (text) |
| A mail that needs a reply (M3.5) | `arrowshape.turn.up.left`, tertiary, small, in the mail list row before the flag; on Today the row's ring and its faint `envelope` |
| Backup recorder, mic (M7) | `iphone` with a green dot, `mic` with a five-bar level meter |
| Documents (md) | `doc.on.doc` everywhere a kept document shows: the sidebar row, Search's group and hit glyph, the `[[doc …]]` chip, the empty state, the toast's tile (never notes' `doc.text`); Import… `square.and.arrow.down`; a Word, RTF or Pages attachment tile `doc.richtext` |
| Empty states | `rectangle.on.rectangle.slash` (review without a deck), `waveform` (live without a deck), `record.circle` (live without a session) |

Sizes: sidebar glyph column 16 pt; source glyph 14 pt tertiary; chip play glyph 9 pt; search hit glyphs `waveform` 13, `display` 11, `pencil` 14 medium.

---

## 4. Density rules

The first Today "felt a bit crowded": chips on every line, a sparkle on every AI line, facts repeated across sections, six equal sections, long italic quotes. The approved fix is these rules. They apply to every screen.

1. **One obvious first thing per screen.** At most one filled (`.borderedProminent`) button and at most one emphasized card at rest. Some screens have none (Review, Live, Course Settings, Notes: the slide, the form or the document is the first thing). A Settings form's Save is filled only while there are unsaved changes.
2. **At most 3 content zones** per screen. Sidebar and toolbar don't count.
3. **Resting rows are plain.** A medium or semibold title, at most one grey secondary line, and a right-aligned date/time (mono time). No chips at rest.
4. **At most one chip per row, and only when it is the point of the row**: a jump-to-time on a transcript or review moment, a slide reference, an exam flag, a proposal in the mail list.
5. **Every fact once per screen.** If the hero's aside names Lecture 3, Coming up does not list it.
6. **Sources sit behind one faint glyph** (`waveform` = recording, `envelope` = mail, `calendar` = a timetable file), 14 pt tertiary, after the row's last line. The full trail opens in a hover popover.
7. **One sparkle per AI block**, and one per screen when the screen has a single AI line (Today).
8. **Status by shape and colour, not words.**
   - In a list that mixes classes and due items (Today's Coming up), a 4 pt course bar is a class or event and a 10 pt open ring (`DueRing`) is something due.
   - In a list of one kind (Calendar's Deadlines, the mail list), a course dot.
   - In the Calendar grid, a due item is a line with a dot and a tag, or an all-day pill.
   - An accent dot is unread; strike-through is cancelled, undone or discarded; a mini determinate ring is processing; a secondary warning triangle is failed.
9. **A course dot replaces a course-name chip.** In lists that mix courses, the title names the course in words ("Data Centers exercise"), because colour alone does not tell three courses apart.
10. **No long quotes at rest.** Quotes appear only in popovers or the inspector, at most about 15 words, in “”.
11. **No filler secondary lines.** No "in 5 days", no restating the title, no "covered above".
12. **Automatic actions are stated once.** A glyph (or Mail's "In Calendar"), plus Undo in the item's own popover, row or toast. No banners.
13. **The sidebar is navigation only**: destinations, their children and unread badges. No content rows, chips, previews, sync times or copy. The one control allowed is Calendar's calendar checkboxes (6.2), as in Calendar.app.
14. **The toolbar subtitle carries the screen's state**: the date and "no classes", "8 results", the course name, the ISO week, a sync failure.
15. **Hover reveals, rest is quiet.** Popovers, Undo, a slot row's ⋯ and a toast's close button appear on hover (on tap on iPad and iPhone).
16. **Custom selection is neutral.** Search hits, segmented knobs and selected inspector rows use `QuietFill`. The accent is kept for the filled button, the current playback item, time chips and drop targets. System `List` selection stays system.
17. **Nothing for later milestones.**

---

## 5. Provenance and trust patterns

### 5.1 Who wrote it

| Layer | Text | Marker | Code |
|---|---|---|---|
| You | `.primary` | accent pin with `person` | `.provenance(.user)`, `ProvenancePin(.user)` |
| Professor (said or shown in class) | `.primary` | amber pin with `graduationcap.fill`, or a 3 pt amber quote bar | `.provenance(.professor)`, `ProvenancePin(.professor)` |
| AI | `.secondary` | one `AIMark` (sparkle) per block; a purple pin with `sparkle` on slides | `.provenance(.ai)`, `AIMark()`, `ProvenancePin(.ai)` |
| AI in the student's notes (ln) | `.secondary` until the student edits it | the `ai` inline mark (`NoteInline.Mark.ai`): one sparkle per block that holds it; the words the student types or changes drop the mark and turn primary | Edit as Note (`LectureNotesExport.editAsNote`); NotesUI draws it |

- **The professor is marked by a pin or a bar, never by amber text.**
- **Grey becomes normal when the user takes it.** Accepting, editing or rewording AI text makes it the user's, so it turns primary (decisions: "An AI-read rule with a lecture source"). In mail drafts a word diff of `generated_body` against `body` decides which words stay grey (decisions: "Draft provenance is a word diff"). `RuleRow` is the reference row.
- **Names and facts are primary** even when the agent found them: a deadline's title, a mail subject, a session. Grey is for sentences the AI wrote: glosses, detail lines, found rows, drafts.
- Pins are 16 pt inline and 20 pt elsewhere. On a slide they get a shadow and a 2 pt ring in the slide colour. A pin card is about 268 wide, radius 12, 12.5 pt text, with an 11 pt grey "who" line.

### 5.2 Sources

- **A source is one quiet affordance**: a faint glyph that opens a popover (Today, Calendar, proposal cards) or a time or slide chip where jumping is the point (Review, Notes, Search, Mail found rows). The mockup legend's "always grey text with a source chip" is superseded.
- **Source popover** (system `.popover`, about 264 wide):
  - an optional header, 11 pt semibold secondary
  - rows of [16 pt glyph or pin | name (12.5 medium) over one 11 pt secondary line | one trailing chip]
  - a recording row: the name says which lecture ("Lecture 2, Example", "Seminar intro"), the line is optional ("Mon 12 Oct · slide 25"), the chip is a `TimeChip` **without** prefix ("▶ 0:37", "57:18"), since the name already says the lecture
  - a mail row: the sender's name; then either the quote as the 11 pt line with the mail's mono time as the chip (mockup 01), or the time as the line and the quote on its own full-width 12 pt secondary line below (mockup 06, for a longer quote). Quotes at most about 15 words, in “”.
  - a footer over a hairline: the green `calendar.badge.checkmark` glyph (no text) and a small Undo
- **Away from its lecture, a resting chip says which lecture**: `TimeChip(t, prefix: "L2")` reads "L2 · 0:37" (Mail found rows, Course Settings rules, Today rows). Inside a popover whose row names the lecture, no prefix.

### 5.3 Actions with an outside effect

**Automatic** (only deadlines into the app's own calendar, and filing): do it, then show it once. Mail: "✓ In Calendar" + Undo on the found row. Today and Calendar: the calendar-check glyph with Undo in the popover, or Undo on hover in the inspector row. Filing: a toast with Undo / Change…. No banner, no "added" text.

**Proposal** (any other change: a room move, a cancellation, rule wording): nothing changes until the user confirms. The shape depends on where it shows:

| Where | Shape |
|---|---|
| Calendar inspector | **Card** (`ProposalCard`): card surface, radius 12, padding 10/11; sparkle + 13 pt semibold question ("Move to Room 5?") + trailing faint source glyph; one grey detail line ("DC Lecture 4, Tue 20 Oct only"); [Discard] plain + [Confirm] filled when it is the screen's first thing, else plain accent |
| Mail list row | the row's one extra line: a grey capsule chip (`calendar` glyph + the question, 11 pt, `ChipButtonStyle`) that opens a menu with Confirm and Discard |
| Mail reader | a **found row**: the facts as grey AI text ("Lecture 4 **Tue 20 Oct, 16:15** in Room 5"), then Discard (secondary text button) and Confirm (accent text button). Never filled: Send is Mail's filled button. |
| Calendar grid | a dashed tag inside the affected event ("Room 5?", proposal dash, secondary text) |
| Course Settings | an AI-worded `RuleRow`: grey wording, one sparkle, a small bordered Confirm (built) |

After Confirm the change applies and the item reads as in calendar without Undo. After Discard it stays, struck through in tertiary.

**Guess** (mail route, platform file to lecture, PDF to lecture, live filing, import): a pick menu right on the item, so a wrong guess is one click: the value in secondary, an 8 pt tertiary chevron, the course dot drawn (`PickLabel` + `.quietMenu()` in MailUI; `PlainMenu` / `PopUpPicker` in CoursesUI). Never a dialog that asks first; filing corrections per 6.5.

**Send:** only the user sends, with the Send button (⇧⌘D). The agent has no send tool. Typing in a draft stops the agent.

**Recording:** the "Record this course" switch is the gate. Record shows only for courses with consent. The one string, "Recording is off for this course", appears only when the consent re-check fails.

Untrusted content (mail bodies, web pages, PDFs) is displayed as data. Never render text from it as UI labels or instructions.

---

## 6. Layout and navigation

### 6.1 Window anatomy

- **Main window:** one two-column `NavigationSplitView(columnVisibility:)`: the sidebar and a detail `NavigationStack`, plus `.inspector` where a screen has one (Review, Calendar), plus the agent panel (ma, 8.6): compact as an overlay of the whole window, expanded as the window's full-height trailing inspector column. It stays two-column for every screen.
- **No column is ever squeezed under its minimum or cut off at the window's edge** (2026-10-20). The screen's minimum is declared (3.3: 480; sidebar 200–320, agent 300–560) and the window's minimum is the sidebar + 480 + the agent's column, each counted once: on macOS 26 the split view runs under the agent's column, and measured from its content the window counted that column twice (sidebar 236 + 480 + a 560 column needed 1836 instead of 1276), so the split view declares its own minimum and still extends under the column (`ignoresSafeArea(.container, edges: .trailing)`; AppKit insets the detail's content by it). When the window cannot hold the sidebar, the screen's 480 and the agent's 300 together (a window as wide as the screen, full screen, a tile), the sidebar hides while the agent panel is expanded (the agent's column shows only once it has its room, so the three never share a window too narrow for them, not even for a frame) and comes back when the panel shrinks or closes or the window has room again (40 pt past the edge), as Xcode and Finder collapse theirs; the window is never made wider. A window narrower than the screen's 480 and the agent's 300 keeps the panel compact. The expanded panel opens at the student's width or the room left, whichever is less (300 at least). The student's own toggle wins: showing the sidebar in a window too narrow for all three turns the panel compact; hiding it stays hidden. A practice round or exam owns the sidebar while it runs. Screen titles hug their text up to 360 pt and truncate past it (6.3), so a long course name never makes the toolbar a rigid width.
- **List screens** (Mail, Notes) draw their list as a fixed column inside the detail, then a `Divider`, then the reader or editor: Mail 318 pt, Notes 236 pt. A third split-view column cannot exist for only some screens without rebuilding the split view, so the column is fixed, not resizable. On compact iOS the list pushes the reader.
- Today, Calendar, Mail, Notes and Search share one detail stack identity, so the toolbar search field keeps its focus (decisions: "The toolbar search field shows on").
- **Live lecture:** its own `Window` scene with no sidebar (a toolbar button brings the library window forward) and an inspector of 336 pt.
- **Feature screens never own navigation.** They call `@Environment(\.openDestination)` with a `StudyDestination` (`.today`, `.calendar`, `.search(q)`, `.course(id)`, `.lecture(id, ReviewTarget(time:plays:))`, `.mail(scope, message:)`).
- Writes go through `\.studyServices`. Only the integrator edits `App/`, `project.yml`, `tools/` and migrations.

### 6.2 Sidebar

Rows are flat (no `DisclosureGroup` gutter), small whatever System Settings says, with glyphs in `.tint`. The base order is fixed:

1. **Today, Calendar, Mail, Notes, Documents, Study, Search** (`SidebarRowLabel`; Notes since M6; Study (`brain`) since mc; Documents (`doc.on.doc`) since md, Mac only, no children, no badge). Mail's badge is the Inbox unread count (nothing at 0).
   - On Mail, Mail's lists sit under its row and fold with an 8 pt tertiary trailing chevron on the Mail row (and its context menu: Hide/Show Mailboxes); kept per window (`sidebar.mailListsExpanded`).
2. **Courses** section: `CourseDot` 9 + name.
   - Courses start closed. 8 pt tertiary chevrons appear only once some course is open.
   - An open course lists its lectures, "L2 · Virtualization & IaaS" over the secondary day, `ProcessingMark` trailing, then its next session, a secondary "L3" over "Mon 19 Oct, 12:15".
   - **The sidebar never jumps.** A course opens and closes only by its chevron (or Show/Hide Lectures) and the section's fold; the state is kept per window (`sidebar.openCourses`) and is the same on every screen. No screen opens or closes another course. The one exception: opening a lecture (from anywhere) opens that lecture's own course, as its chevron would, so the selected row shows; it stays open afterwards until its chevron closes it.
   - On a course's screen that course lists its own screens instead: Lectures (count), Slides, Notes, Progress (`chart.bar`, mc), Course Settings; its row has no chevron. The other courses keep their state (no chevrons at all while none of them is open, as in 08). A practice exam's results show with that course's Progress row selected.
   - A practice round or exam (mc) hides the sidebar; leaving brings it back as it was.
   - **A file drag never moves the sidebar** (2026-10-19): no course opens or closes, the Courses fold stays as it is, lecture and session rows keep their dates, and no row spring-loads its screen. Exactly one row lights (accent soft + 1.5 pt accent ring, radius 7, unanimated): the course, lecture or session row under the cursor, whose drop area is the whole row (full width, up to half the gap to the next row); while the cursor is over the screen, the predicted lecture or session row if it shows (10; nothing opens for it). A drop on a course row files into that course (smart import picks its lecture; the toast's Undo and Change…); on a lecture or session row, exactly there. The whole sidebar is one drop area (`filingDropZone`): over it the window's HUD and the screen's drop rings stay off, and a drop between rows is filed as on the window. A drop opens nothing either: the toast says where the file went.
   - The section folds with its header's native chevron (shown on hover); the state is kept per window (`sidebar.coursesExpanded`). A file drag leaves it folded (a drop then goes to smart import).
3. **Footer** over a hairline: [semester … `bubble.left` gear], or [+ New Course … semester `bubble.left`] on a course's screen. New Course stays on one line (the semester truncates first). The footer is a bar (`safeAreaBar`), so a long list scrolls under it with the scroll-edge effect, never through the semester. `bubble.left` is the agent panel's ONE launcher (ma, 8.6; help "Show Chat" / "Hide Chat", tinted while the panel is open, only with Claude Code); while the sidebar is collapsed it floats at the window's bottom-left (32 pt glass, 12 from the edges). No sync time or status dot.

**Per-screen additions** (only while that screen is selected):

| Screen | Addition |
|---|---|
| Mail | its scopes as flat, indented children of the Mail row (`MailScopeLabel`): Inbox, each course with mail (dot; a course without mail has no row), University, Newsletters, Drafts, Sent; without a mail account no children. No section labels. Badges: the scope's unread count; Drafts the open drafts; Sent none; nothing at 0. Course rows count like any mailbox. |
| Notes (M6) | children of the Notes row: All Notes (`doc.text`), then each course with notes in course order (dot + name), indented like Mail's lists. No counts: badges are only for things to act on. No fold chevron. |
| Calendar (M3) | a section after Courses titled by the account ("iCloud"), one checkbox row per calendar: "Socrates" (the app's own sessions and deadlines, on) and the user's other calendars (off by default; their events show read-only). This is the sidebar's one control. |
| Search | Recent searches: the last 3, `clock` rows |

### 6.3 Toolbar

- **Title:** every main-window screen uses `.screenTitle(title, subtitle:)` (15 pt semibold over 11 pt secondary, glass-less, each line at most 360 pt, then truncated with …), with `leadingInset: ScreenTitleInset.firstItem` when the title is the first item. Live has no title. Notes is "Notes" (a course's Notes: "Notes" / the course, as its Lectures and Slides; 2026-10-19: the window was titled "Socrates" before).
- **Groups:** each group is its own glass capsule, separated by `ToolbarSpacer(.fixed)`. Toggled buttons are accent soft with accent glyphs. Record and Stop are red.

| Screen | Leading | Title / subtitle | Trailing |
|---|---|---|---|
| Today | sidebar toggle (glass) | "Today" / "Friday, 16 October 2026 · no classes" | [search field] [● Record] [⋯ Import…, New Course…] |
| Mail | – | the scope ("Inbox", "Data Centers") / nothing, or "Offline" / "Sign-in failed"; without an account "Mail" | [Reply, Archive, Flag, Translate] [New Message] [search field "Search mail"]; Translate (`translate`, a toggle) only for a message in another language than the student's; without an account no message actions (6.6) |
| Calendar (M3) | – | "October 2026" / "Week 43" | [‹ Today ›] [+] ([+] opens the agent panel, compact, composer focused; ma); no search field |
| Notes (M6) | the title, then [New Note] (`square.and.pencil`) in its own glass (a course's Notes: after [‹ ›], never merged into it) | "Notes"; a course's "Notes" / "Data Centers" | while a note is open: [Aa ⌄ (popover), `checklist`, `photo` (file importer, images), `pencil` (sketch)] [`display` "Slide", `waveform` "Quote", with titles] in the toolbar's middle (`.principal`); no editing groups while none is open (an empty scope) … [search field 180 "Search notes"] at the trailing end; the same toolbar on a course's Notes screen, without the search field |
| Search | – | "Search" / "8 results" (nothing at 0: "No Results for …" says it) | [search field]; the "Also searched" line belongs to the content, never the toolbar |
| Course screens | [‹ ›] one glass group | "Course Settings" / "Data Centers"; "Lectures", "Slides" / the course | [Import + \| ⋯] one group (Course Settings); [Import +] alone on Lectures and Slides (the deck list has no Import of its own) |
| Study (mc) | – | "Study" / "Week 3 of 17" | nothing; no search field |
| Documents (md) | – | "Documents" (no subtitle) | [Import…] (`square.and.arrow.down`, help "Import…") in its own glass, only on the Mac; no search field (Search covers the contents) |
| Lecture notes page (ln, nl) | [‹ ›] one glass group | "Lectures" / the course | [Show Inspector] (`sidebar.trailing`) at the trailing end only while Your notes is closed; while it is open its header ("Your notes" 13 semibold, Hide) is the toolbar item over the column (6.4) |
| Progress, results (mc) | [‹ ›] one glass group | "Progress" / "Data Centers"; "Practice exam" / "Data Centers · All lectures · Tue 19 Jan, 09:00" | nothing |
| Practice round (mc) | sidebar toggle (the sidebar is hidden) | "Practice" / "Data Centers · 4 / 12" | [End] |
| Practice exam (mc) | – | "Practice exam" / "Data Centers · 2 / 8 · 1:16:05 left" (the time SF Mono) | [Flag] [Pause] |
| Review | – | lecture title / "Data Centers · Tue 13 Oct" | [recording picker, only with 2+] [‹ 16 / 88 ›] [Pen, Highlighter, (Eraser), Flag] (M6, Mac: only with a deck, Flag only with a recording; Pen and Highlighter are toggles, one at a time, accent soft with an accent glyph when on; the Eraser joins while one is on); inspector segmented + hide at the inspector column |
| Live | sidebar button, [● 38:41] | "Slide 17 of 88" (no title) | [‹ › Flag] [■ Stop] |

- The sidebar toggle shows on Today, or on any screen while the sidebar is hidden.
- **No chat buttons** in any toolbar (ma): the agent panel's one launcher is in the sidebar footer (6.2); the expanded panel's header (title menu, ⤡, Close) is a toolbar item over its column.
- **Search field.** The Mac draws its own field (`ToolbarSearchField`, 240 pt, tertiary magnifier and prompt) because `.searchable` cannot reach the mockup order on macOS 26.5; iOS uses `.searchable`. It shows on Today, Mail, Search and Notes (180 pt) only: not on Calendar (mockup 06), Study, Documents, a lecture or a course.
- **Prompts:** Today and Search "Search lectures, notes, mail" (mockup 01). Mail "Search mail". Notes "Search notes".
- **Query ownership:** Today and Search share one query (typing on Today opens Search). Mail and Notes each own theirs and filter their list in place. Switching screens shows the destination's own query: text never carries from Search to Mail or back.
- The idle Record button is on Today only. A running recording shows `RecordingIndicator` (pulsing red dot + mono elapsed time) on every screen.
- Retry appears only when the lecture's job failed, with the error as `.help`.

### 6.4 Inspector

- 336 pt, header 52 pt level with the toolbar; its controls sit in that header (Review's segmented "This slide | Whole lecture" and hide; Calendar's "Deadlines" title, 13 semibold).
- Which screen has which inspector: Review (notes), Calendar (Deadlines), the lecture notes page (Your notes, nl: open by default from 1160 pt of screen, the student's choice kept per window). The agent panel expanded (ma, 8.6) is the window's full-height trailing column on every screen (header 52 pt level with the toolbar: the title menu, ⤡ and Close; 300–560, the width kept): on Review, Calendar and the lecture notes page it takes their inspector's place (their Show Inspector hides too) until ⤡ / ⌥⌘J (both leave their `.inspector` out entirely meanwhile: a hidden one kept its column's room, the window grew past the screen, and on Review it took and gave back that room on alternate passes, a layout loop AppKit ends with an exception, also with the hidden inspector emptied; Calendar's week keeps its scroll position, and Review keeps its transcript's lines and scroll position in `ReviewModel` across the rebuild); on Today, Mail, Search, Notes and a course the screen narrows to its declared minimum (480, Mail 700) and adapts (Course Settings goes to one column), and where the window cannot hold the sidebar too, the sidebar hides while the panel is expanded (6.1). Never two inspectors.
- A screen with an inspector keeps its scroll view off the window's top edge (the lecture notes page: a 1 pt strip above it). A scroll view there runs under the toolbar, and the window then draws the inspector as floating glass over the screen instead of a column (nl). Its `.inspectorColumnWidth` is the outermost modifier of the inspector's content: under another modifier (a geometry reader) SwiftUI took the content's own width as the column's minimum and maximum.
- Show Inspector appears in the toolbar only while it is hidden. ⌃⌘I toggles it everywhere (`InspectorCommands`). Exactly one inspector toggle is ever in the toolbar.
- The header's toolbar item is added only while the inspector is shown (`if isPresented` inside the inspector's `.toolbar`). SwiftUI keeps a hidden inspector's content alive, and with it every toolbar item that content declares, so an unconditional header stays in the toolbar beside Show Inspector (Review showed two inspector buttons). Hiding by header, ⌃⌘I and dragging the column shut all write the `isPresented` binding.
- Blocks have a section label (subheadline semibold secondary) and are separated by hairlines. One sparkle per AI block.

### 6.5 Sheets, popovers, menus, alerts, toasts

- **Popovers** (system) for source trails, editors (`RuleEditor`, `SlotTimeEditor`), pin cards, Calendar's detail popover (8.3), the agent panel's change rows (the source trail, on a 350 ms rest) and its task list (8.6).
- **Menus and pick menus** for every choice that corrects a guess.
- **Filing never asks.** A drop files to the best guess with no dialog, even when unsure (decisions: "No dialogs when unsure"). Corrections start from the item: the toast's Change… is a menu of places (each course with its lectures and sessions, plus New Lecture), so a wrong guess is one click. A Change… that is an item in another menu or a row button opens `ChangeFilingSheet`, the one filing sheet: the deck rows' menu (Course Settings, a course's Slides), Mail's platform file lecture menu, and the toast while its places load.
- **Sheets** only for creation, setup and that change sheet: New Course, New Lecture Capture, Live's filing Change (choosing the class before the recording exists, mockup 02), Import Timetable (a timetable drop sets up courses, 8.3). One filled `.defaultAction` button and `.cancelAction`; keyboard-first (list focused, ↑/↓, ⏎, ⎋).
- **One alert**, "Couldn’t finish", for failures that need the user (`model.failure`).
- **Toasts** (filing): bottom right, stacked, glass. Filed toasts leave after 8 s, not while hovered. Review and needs-course toasts stay until handled, with a close button on hover. Toasts stay above a screen's own bottom controls (`.reservesBottomOverlaySpace(_:)`) and above the agent panel while it sits compact in its corner (`\.overlayInsets`).
- **Confirmation dialog** only for destructive or irreversible actions (stopping a live recording; deleting a deck, a lecture or a recording, 8.1, which also has Undo).

### 6.6 Empty, loading and error states

| State | Show | Never |
|---|---|---|
| Screen with nothing in it | it invites the next step (PRD "Empty screens invite the next action", the one allowed kind of guidance copy): the screen's glyph, **one short line and one button or drop target**, centred over the whole detail (`ContentUnavailableView`; `EmptyDropPrompt` for the drop screens, the whole detail a drop target with an accent ring while files are over it, filed through smart import). Course Lectures `waveform` "Drop the slides (PDF) and recordings here." + Import…; Slides `rectangle.on.rectangle` "Drop the slides (PDF) here." + Import…; Notes `doc.text` "No notes yet." + New Note (no editing groups until a note is open; a query without hits shows the search state instead); Progress `chart.bar` "Progress starts with this course's slides and recordings." + Import…; Study `brain` "Study starts with your lectures' slides and recordings." + Import…; Review without slides or a recording `rectangle.on.rectangle` "Drop this lecture's slides here." + Import… (filed to that lecture); Documents (md) `doc.on.doc` "Drop your documents here." + Import… (documents go to the bank, other files to smart import); Mail without an account (below). Where no next step exists (Today `sun.max`, placeholders, an empty mail scope in the list column) the glyph stands alone | a lone glyph where a next step exists; a title; a second line; copy that explains the system |
| No selection on a list screen (Mail, Notes) | the reader or editor stays blank (Notes opens on its newest note when nothing is selected, as Apple Notes) | "No Message Selected" |
| Empty query (Search) | nothing (`Color.clear`) | tips, suggestions |
| No hits (Search, Mail, Notes) | the system "No Results for “q”" (`ContentUnavailableView.search`), in the list column on list screens | a description |
| Mail without an account | `envelope`, "Connect your student mail.", one filled "Set Up Mail…"; the title "Mail", no message actions in the toolbar, no lists under the Mail row | setup copy beyond the one line |
| A week without events (Calendar) | the plain grid; deadlines that exist | invented sessions, ghost events |
| An empty group in a form | a **ghost row** in tertiary: the row that would be there ("–", the guessed slot, the lecturer's sender rule). Clicking adopts it; a drop files into it. | "No slots yet" |
| An unknown value | a muted inline value: "Add room", "Not announced" | |
| An empty note | one quiet editable line, no placeholder copy, no pin well | "Write a note…" |
| Processing | a determinate `ProgressView(value:)` labelled by phase ("Downloading model", "Loading model", "Transcribing", "Aligning") with a mono percent; a mini determinate ring on the sidebar row. Progress never goes backwards within a phase. | spinners, indeterminate bars |
| Loading content | a **skeleton**: the row's final layout at final size, `.redacted(reason: .placeholder)`, no shimmer; or the previous content kept up (`SlideImageView` keeps the last bitmap). A document being read or summarised (md): the list's second line after the kind, the reader's Summary as 3 lines | blank frames, layout jumps |
| Model output | streams into its final place (drafts about 10 times a second); the rest of the screen stays usable | modal waits |
| Job or send failed | a secondary warning triangle on the row (a mail draft: "Not sent" or the reason as its extra line), Retry or Send again, the error as `.help` or under the field. A document that could not be read or summarised (md): the list's triangle with the reason as help; the reader's one line with the reason and [Read Again] | red banners |
| Mail sync failed | the toolbar subtitle "Offline" (server unreachable) or "Sign-in failed" (the engine stopped until the account is saved again); the full error in Settings ▸ Accounts | a banner, a sync time |
| Launch failure | "Library unavailable" plus the error text | |

A new library starts empty; empty screens invite the next action (PRD UI rules). Permission prompts come only when needed: calendar access when a course shown in the calendar has a session or a deadline wants an event. The first launch makes no prompts.

### 6.7 iPad and iPhone

- The same views, one SwiftUI multiplatform app. `NavigationSplitView` collapses on compact widths; list screens push their reader.
- Hover becomes tap: source popovers, annotation content and Undo open on tap. Build each as one component that handles both.
- iOS uses `.searchable`. iPad uses the same menu `Commands` with a hardware keyboard. The slide view has its own Space handler.
- Live on iPhone and iPad is full screen and keeps a toolbar inspector toggle.
- The iPhone (M7) follows mockup 09 with section 4 applied (8.5). Its root is `PhoneShell` (Phone): the floating tab bar Today, Courses, Calendar, Mail with Record as its separate circular slot; each tab a navigation stack with a large title and the header's search and agent bubble. Touch targets are at least 44 pt (the bar's buttons, Coming up rows ≥ 44, answer rows 52, Start 50; the recorder's course menu and Stop capsule keep their drawn 30–34 pt look inside a 44 pt target). The phone's screens use the system background (black in dark).
- The iPhone records, practises and reads; it never transcribes, processes, plans or runs Claude (the Mac does, M7). Courses, Calendar and Mail on the phone are the iOS screens of the split view (their phone layouts are later); the iPad keeps the split view.
- Mail sync and the calendar mirror run on the Mac only (also with M7's iCloud sync: the iPhone shows the Mac's synced rows).

### 6.8 Keyboard and commands

| Menu | Command | Key |
|---|---|---|
| File | New Lecture Capture… / Import… / New Course… (Import… opens the Documents importer while Documents shows, md) | ⇧⌘N / ⇧⌘I / ⌥⌘N |
| Go | Today, Calendar, Mail, Notes, Documents, Study, Search (Notes since M6, Study since mc, Documents since md on the Mac; Search keeps ⌘F) | ⌘1–⌘7 |
| Documents (md; the list) | Delete (Edit ▸ Undo "Delete Document" restores it); Quick Look | ⌫; Space |
| A course's Slides (the list) | Open the selected deck in Review; Quick Look | ↩; Space |
| Go | Back / Forward | ⌘[ / ⌘] |
| Go | Search Library (focuses the toolbar field; opens Search from a lecture or course; not while a practice exam is written) | ⌘F |
| View | Show/Hide Inspector; sidebar | ⌃⌘I; `SidebarCommands` |
| View (ma; every screen of the main window, also while typing; only with Claude Code) | Show Chat / Hide Chat (the agent panel, compact); Expand Chat / Shrink Chat (the right sidebar) | ⌘J; ⌥⌘J |
| View (review) | Hide/Show Thumbnails; Hide/Show Transcript (only while a review is focused) | ⌥⌘1; ⌥⌘2 |
| View (nl; Mac; only while a screen with zoomable content shows in the key window) | Actual Size; Zoom In; Zoom Out | ⌘0; ⌘+ and ⌘=; ⌘− |
| Review | Play/Pause; Back/Forward 15 Seconds; Previous/Next Slide | Space; ⌥← / ⌥→; ← / → |
| Review | Follow Playback; Slide Starts Here; Mark as Reviewed | ⇧⌘F; ⌘\; ⇧⌘R |
| Review (M6, Mac) | Flag (the student's flag at the playhead; Edit ▸ Undo removes it) | F |
| Review (M6, Mac) | Pen; Highlighter; Eraser (only while drawing); Stop Drawing (only while drawing) | P; H; E; Esc |
| Edit | Undo / Redo also step through ink strokes, erases and flags on a review | ⌘Z / ⇧⌘Z |
| Lecture (live) | Next Slide (stamps); Previous Slide; Flag | → and Space; ←; F |
| Lecture (live) | Record/Stop (only while Live is focused) | ⇧⌘R |
| Lecture (ln; only while a lecture's notes have focus, so never while typing, nor while a note in Your notes has focus) | Ask… (the selection); Highlight / Remove Highlight | ⌘K; ⇧⌘E |
| Message | Reply; Archive; Flag; Mark as Read / Mark as Unread; Translate / Show Original | ⌘R; ⌃⌘A; ⇧⌘L; ⇧⌘U; ⌃⌘T |
| Message | Send (only while a composer is on screen) | ⇧⌘D |
| Message | New Message; Get Mail | none (⌘N is New Window, ⇧⌘N New Lecture Capture) |
| Calendar (M3) | Go to Today; Previous Week / Next Week | ⌘T; ⌘← / ⌘→ |
| Calendar (M3) | Confirm / Discard the selected proposal | ⌘↩ / ⌘⌫ |
| Calendar (M3) | New Deadline (opens the agent panel, like [+]; ma) | none |
| Practice (mc; a round) | Choice 1–4 (before the answer, nothing typed); Play Sentence and Next Question (after the answer, nothing typed); Submit Answer (a written answer); End | 1–4; Space and →; ⌘↩; none |
| Practice (mc; a practice exam) | Choice 1–4; Previous / Next Question; Flag / Unflag; Pause / Resume; Submit | 1–4; ⇧⌘[ / ⇧⌘]; ⇧⌘L; none; none |
| Format (M6; while a note editor has focus) | Title / Heading / Subheading / Body | ⇧⌘T / ⇧⌘H / ⇧⌘J / ⇧⌘B |
| Format (M6) | Checklist / Bulleted List / Numbered List | ⇧⌘L / ⇧⌘7 / ⇧⌘9 |
| Format (M6) | Bold / Italic / Underline / Strikethrough / Highlight; Add Link… | ⌘B / ⌘I / ⌘U / ⇧⌘X / ⇧⌘E; ⌘K |
| Notes (M6) | New Note (the toolbar button) | none until ⌘N is decided |
| Reserved | New Window; Day / Week / Month once Calendar has more than Week | ⌘N; ⌃⌘1–⌃⌘3 (Go owns ⌘1–⌘7). ⌘J is Show Chat since M3.5 (⌥⌘J Expand Chat since ma; ⇧⌘J stays Subheading); ⌘I is Italic since M6 |

The Review menu's plain keys (F, P, H, E, Esc) follow the command pattern below: attached only while the review is focused, nothing is typed and the item works. The Format keys are Apple Notes'; the editor handles them itself while it has focus (so they work in Review's "Your notes" too), and the Format menu attaches them only while a note editor has focus (⇧⌘L is Mail's Flag otherwise). In notes: ↩ continues a list (a done item's next is open) and ends it in an empty item, ↩ after a heading starts Body, Tab / ⇧Tab indent and outdent list items, ⌫ at an item's start outdents and then ends the list, Esc ends drawing on a sketch. In the Notes list: ⌫ deletes the note (Edit ▸ Undo restores it).

**Content zoom** (nl, "like Word"; `ContentZoom` in StudyUI, `ContentZoomCommands` in the app): one value for the whole app, kept across launches (`Socrates.contentZoom`), in steps of 75, 85, 100, 115, 130, 150, 175 and 200 %; a screen with zoomable content applies `.contentZoomable()` once at its root and its content multiplies its sizes by `\.contentZoom`. What scales: the lecture notes page (its title and meta line, Claude's text, code, math, diagrams, tables, charts, the slides' caps, chips, callouts, kept answers, the Writing line, Keep in mind) and the same text in Review's Whole lecture; the Your notes column's notes, chips and thumbnails; the note editor wherever a zoomable screen shows it (Notes and a course's Notes, Review's "Your notes", the column); Review's transcript and the inspector's text (summary, further reading, exam hints, said in class); the rows of a course's Lectures list. What does not: the sidebar, toolbar, window controls, buttons and menus (the page's [Open in Review] [Practice] ⋯ included), segmented controls, inspector headers, the Ask popover and capsule, the agent panel, Review's stage, rail and player, the Live lecture window and every other screen. The page's caps grow with the zoom (780 z, 1120 z, 640 z) while its margins, the column's width and the breakpoints stay, so a line keeps its words until the window runs out and then wraps (no sideways scroll). TextKit documents re-apply their attributes in one editing transaction (no re-parse, no save, no undo step), keeping the selection and the first visible character (the notes page: the reading line's).

The coach's screens (mc) follow the command pattern (`PracticeActions`, `PracticeCommands`): ↩ is the screen's one default action (Start on the hero and the sheet, Practice on Progress, Review misses on the results, Resume on a paused exam); Esc cancels the sheet. A practice exam's ⇧⌘L is its Flag (Mail's Flag is attached only while Mail is focused).

In the agent panel's composer (ma): ↩ sends (a beep while a message cannot go yet), ⌥↩ and ⇧↩ start a new line, ⌘V pastes a copied file or a screenshot as a tile (text with a picture of it, as Numbers and Office copy, pastes as text), Esc clears the text and files (⌘Z after Esc brings them back), then closes the panel. ⌘J and ⌥⌘J put the caret at the end of the kept draft. Every screen's plain keys stand down while the composer has focus (`\.isAgentComposerFocused`, folded into `\.isSearchFieldFocused`). Memory sheet (M5): ⌫ forgets the selected row, ↩ in a row saves its text, Done is the default button.

In lists: Search uses ↑/↓ to select (M5: click selects one hit, ⌘-click toggles, ⇧-click extends), ↩ or double-click to open and Space to play; ↩ in the toolbar field opens the selected or first hit. The mail list uses ↑/↓, ↩ moves focus into the reader (there ↑/↓ scroll, Space pages, Esc goes back), Delete archives. Segmented controls step with ←/→. Default buttons use `.defaultAction` (Today's "Start review").

**Command pattern** (copy it for any screen with plain-key shortcuts; `ReviewActions` and MailUI's `MailScreenCommands` follow it):

1. An `XActions` struct with `can…` flags, `isEditingText`, closures, and `…Enabled` properties that fold in `!isEditingText`.
2. Publish it with `.focusedSceneValue(\.x, actions)` from a tiny `Color.clear` publisher view (see `ReviewActionsPublisher`), so playback state does not re-render the screen.
3. A `Commands` struct reads `@FocusedValue(\.x)`. Plain and ⌥ keys attach only while the screen is focused and nothing is being typed. ⌘ keys attach only while the screen is focused, because AppKit lets a disabled menu item swallow its key.
   ```swift
   let keys = actions.map { !$0.isEditingText } ?? false
   .keyboardShortcut(keys ? KeyboardShortcut(.space, modifiers: []) : nil)
   ```
4. `isEditingText` = any editor's focus OR `\.isSearchFieldFocused`.
5. Check `menus.txt` from snapshot mode for keys that two items share.

---

## 7. Component catalog

Paths are under `Packages/`. **Visibility matters:** an `internal` or `private` piece cannot be used from another package. To use it elsewhere, first move it into StudyUI and make it public (one change), then use it. Never copy it.

### 7.1 StudyUI (public)

| Component | File | Use for |
|---|---|---|
| `Color(hex:)`, `Color.course(_:)`, `Color.professor`, `Color.ai` | `StudyUI/Components.swift` | course and reserved colours, light/dark aware |
| `CourseDot(course:size:)`, `CourseDot(hex:size:)` | same | the course wherever a name chip would go (7 eyebrow and mail list, 8 default, 9 sidebar and headers) |
| `TimeChip(_:prefix:showsPlayGlyph:action:)`, `SlideChip(page:action:)` | same | the one jump chip per row; "S13" |
| `TimeText.clock(_:)` | same | every recording time ("0:37", "1:08:13") |
| `DayText.day(_:locale:timeZone:)` | same | every day ("Mon 12 Oct") |
| `.provenance(_:)`, `AIMark`, `ProvenancePin` | `StudyUI/Provenance.swift` | who wrote it |
| `.screenTitle(_:subtitle:leadingInset:)`, `ScreenTitleInset` | `StudyUI/ScreenTitle.swift` | every main-window title |
| `FieldEditor.isComposing` | `StudyUI/FieldEditor.swift` | before taking a key or rewriting a focused field: never while the field editor has marked text (a dead key, an input method) |
| `SidebarRowLabel`, `SidebarSectionTitle` | `StudyUI/SidebarRowLabel.swift` | sidebar rows and sections |
| `StudyDestination`, `ReviewTarget`, `MailScope`, `\.openDestination`, `\.studyServices`, `\.isSearchFieldFocused`, `.reservesBottomOverlaySpace(_:)` | `StudyUI/Navigation.swift` | navigation, writes, key detaching, toast clearance |
| `SourceGlyph`, `SourceTrailPopover`, `SourceTrailButton`, `SourceTrailText` (M3), `SourceTrailRows` | `StudyUI/SourceTrail.swift` | the one source affordance and its popover (5.2) on Today and Calendar; rows from `TrackedItemRepository.trails(itemIDs:)`; `SourceTrailRows` is the popover's rows alone (Calendar's detail popover, 8.3) |
| `DeadlineActions`, `\.deadlineActions` (M3) | `StudyUI/DeadlineActions.swift` | every effect of Today and Calendar (Undo, Mark as Done, proposals, sessions); `preview` / `submit` are unused since ma (Calendar's composer is gone) |
| `.agentContext(_:refine:)`, `AgentContextSource`, `AgentContextPreferenceKey`, `\.openAgentPanel` (`OpenAgentPanelAction(expanded:)`), `\.agentPanelExpanded` (ma) | `StudyUI/AgentPanelSupport.swift` | a screen says what it shows to the agent panel (Review: the slide, and the playhead at ↩ through `refine`; Calendar: the week and the selection; Today), opens it (Calendar's [+]) and hides its own inspector while it is expanded, without depending on ChatUI |
| `DueRing`, `CourseBarRow` (M3) | `StudyUI/DueRing.swift`, `StudyUI/CourseBarRow.swift` | the due marker; Today's dated row (bar or ring, title, grey gloss with the exam star, day over mono time, trailing accessory) |
| `ProposalCard` (M3) | `StudyUI/ProposalCard.swift` | a staged change that waits for Confirm / Discard (5.3) |
| `Color.contentBackground` (M3) | `StudyUI/Styles.swift` | the window's content surface (Calendar's grid and composer) |
| `DayText.time`, `.timeRange`, `.dayTime`; `Font.mono(_:weight:)`, `Font.chip`; `QuietFill`; `Hairline` (M3) | `StudyUI/Components.swift`, `StudyUI/Styles.swift` | "10:15" always 24-hour, "Mon 19 Oct, 23:59"; SF Mono times; the neutral fill; 0.5 pt lines |
| `AnnotationPin`, `AnnotationPinMark`, `AnnotationPinStyle` (M4) | `StudyUI/AnnotationPin.swift` | the one pin on a slide or a transcript line: You = accent `person`, Professor = amber `graduationcap.fill`, AI = purple `sparkle`; 20 pt with shadow and 2 pt white ring on the slide, 16 pt inline |
| `InkView(drawing:surface:)`, `InkCanvas(drawing:tool:surface:)`, `InkSurface`, `InkTool` (M6) | `StudyUI/Ink.swift` | the student's ink as vectors, aspect fit: on a slide (`.slide`: white paper, highlighter multiplied, pen 3 / highlighter 22 of 1000 units) or in a note's sketch (`.sketch`: light/dark ink, 1.8 / 14 pt). `InkCanvas` draws with the mouse or trackpad (crosshair pointer; a click is a dot; finished strokes thinned), erases whole strokes (7 pt ring, swept), and puts each stroke or erase on the window's undo manager; tool nil passes clicks through. Give it an `.id` per drawing |
| `Color.canvasBackground(_:)`, `Color.highlighter(_:)` (M6) | `StudyUI/Styles.swift` | the canvas surface behind a sketch; the highlighter yellow (notes, search matches, ink) |
| `PinCard`, `PinCardMetrics`, `PinCardQuote`, `FurtherReadingRow` (M4) | `StudyUI/PinCard.swift` | the pin's card (268 wide, radius 12, 12.5 text): the professor's “quote” over the who line (pin + surname + `TimeChip`), the AI's reading rows, the student's editable text; the further-reading row in the inspector |
| `EmptyDropPrompt(systemImage:line:target:)`, `.importDropTarget(_:)`, `\.importFiles` (`ImportFilesAction`: `open(to:)`, `drop(_:to:)`), `ImportTarget` (2026-10-19) | `StudyUI/EmptyDropPrompt.swift` | an empty screen's one line + Import… over the whole detail as a drop target (6.6); files dropped on a screen; both go through the app's smart import to the course or lecture |
| `\.deleteFromLibrary` (`DeleteFromLibraryAction`), `OpenLibraryItems` / `\.openLibraryItems` (focused) (2026-10-19) | `StudyUI/LibraryDelete.swift` | Delete… on a deck, lecture or recording (the window confirms, 8.1); the Edit menu's Delete items for the open review |
| `OffMainScheduler` | `StudyUI/OffMainScheduler.swift` | `$rows.load(request, scheduler: OffMainScheduler())` for a heavy request: its first fetch and every later one off the main thread (SQLiteData's default fetches the first value on main, in the parent's body) |

`Color.accentSoft(_:)` is public since Mail's Translate (MailUI's snapshot toolbar draws the toggled button with it). (`Font.chip` is public since M3.)

### 7.2 Feature packages

| Component | Where | Visibility | Use for |
|---|---|---|---|
| `HeroCard`, `heroButtonStyle()`, `HeroButtonLabel`, `Eyebrow` | `Courses/…/CoursesUI/TodayView.swift` | private | the emphasized card, the one filled button (Coming up rows are StudyUI's `CourseBarRow` since M3) |
| `SettingsGroup`, `SectionHeader`, `FormRow`, `SwitchRow`, `.settingsRowPadding`, `.fieldChrome`, `.focusRing`, `.tokenStyle`, `PopUpPicker`, `SegmentedChoice`, `PlainMenu`, `CourseColorMenu`, `NamesField` | `CoursesUI/Components.swift` | internal | grouped forms |
| `FlowLayout`, `GlossaryField`, `SuggestedHeader`, `GlossarySuggestionRow` | `CoursesUI/GlossaryField.swift` | internal | token flows; the "one sparkle per AI block" header |
| `RuleRow`, `MailRuleRow`, `GhostMailRuleRow`; `SlotRow`, `GhostSlotRow`, `SlotColumns`; `DeckRow`, `GhostDeckRow`, `PDFGlyph`; `DeckMenu`, `DeckFiles` | `CoursesUI/RuleRows.swift`, `WeeklySlotRows.swift`, `CourseSettingsView.swift`, `DeckActions.swift` | internal | provenance reference row; ghost rows; column-aligned editable rows |
| `LectureListRow` | `CoursesUI/CourseScreens.swift` | private | lecture rows |
| `SessionText` | `Courses/Sources/Courses/SessionText.swift` | **public** (module `Courses`) | session titles, "10:15", "10:15–11:45" |
| `PlayerBar`, `Scrubber`, `SpeedMenu`, `FollowButton` | `Review/…/ReviewUI/PlayerBar.swift` | internal | the glass player capsule |
| `TranscriptRow`, `TranscriptText`, `SectionDivider`, `ProcessingProgress` | `ReviewUI/TranscriptViews.swift` | internal | transcript lines, doubt dots, determinate progress |
| `SlideRail`, `SlideStage`, `SlideBitmapView`, `NoteFlowLayout` | `ReviewUI` | internal | thumbnails, the large slide, chips in transcript pins and study blocks |
| `SlideInkLayer`, `InkToolButtons`, `SnapshotInkTools`, `DrawingFollowGuard` (M6) | `ReviewUI/SlideInk.swift` | internal | the page's `InkCanvas` over the bitmap (under the pins) with its `SlideInkEditor`; the toolbar's ink group (window and snapshot chrome); Follow coming back on ends drawing |
| `SlideInkEditor` (M6) | `Review/SlideInkEditor.swift` | public | one deck page's ink: load, save 500 ms after a change and on `flush()` |
| `NotesView`, `NoteEditor`, `NoteEditorController`, `NoteFormatCommands`, `NoteLink`, `NoteEditorStyle`, `NoteParagraphKind`, `NoteMark` (M6) | `Notes/…/NotesUI/` | public | the Notes screen; the rich editor (Notes, Review); its toolbar and Format menu handle |
| `NoteTextView`, `NoteEditorCoordinator`, `NoteDocumentBuilder` / `NoteDocumentReader`, `BlockFormat`, `NoteTextAttachment` + `ChipAttachment` / `MediaAttachment` / `QuoteAttachment` / `KeptAttachment`, `NoteListFragment`, `NoteSlidePicker`, `NoteQuotePicker`, `NoteStylePicker`, `NoteListRow`, `NoteReadOnlyView` (M6) | `NotesUI` | internal | the TextKit 2 editor, blocks ⇄ text, attachments with view providers, list markers, the popovers, list rows, the iOS read-only rendering |
| `NoteSession`, `NoteNames`, `NoteList`, `NoteListTime`, `NoteBlocks`, `NoteMedia` (M6) | `Notes/…/Notes/` (no SwiftUI) | public | one open note and its saving; names; the list and All Notes' groups; the mapping's pure parts; images, sketches, slide clips, quotes |
| `.reviewGlass(in:floating:)`, `ReviewTitle`, `SectionLabel` | `ReviewUI` | internal | floating glass; inspector labels |
| `ReviewContent`, `PaneDivider`, `ReviewLayout` | `ReviewUI/ReviewPanes.swift`, `ReviewLayout.swift` | internal | rail \| slide over transcript; an invisible draggable, double-clickable pane edge; the stored layout |
| `SearchResultsView` | `Search/…/SearchUI/` | public | the Search screen |
| `SearchHitRow`, `SearchGroupHeader`, `FilterSegments`, `QuietFill`, `MatchInk`, `RecentSearchesSection` | `SearchUI` | internal | results, neutral segments, neutral fill, highlight |
| `.smartImport`, `.filingDropTarget`, `.filingDropZone`, `ChangeFilingSheet` | `Filing/…/FilingUI/` | public | drop anywhere, sidebar row targets, the sidebar as one drop area, the change sheet |
| `FilingToastView`, `DropHUD`, `.filingGlass`, `FilingSmallButtonStyle`, `UndoLabel`, `FilingText` | `FilingUI` | internal | toasts with Undo / Change…, lifted glass cards |
| `SlideImageView`, `RecordingIndicator` | `Capture/…/CaptureUI/` | public | every slide thumbnail; the recording capsule |
| `LevelMeter`; `CaptionsSection` | `CaptureUI` | internal; private | mic level; live captions |
| `Hairline`, `SectionLabel`, and in `LiveColors.swift` (a file, not a type): `Color.contentBackground`, `.liveCanvasBackground`, `.inspectorBackground` | `CaptureUI` | internal | 0.5 pt lines, backgrounds |
| `MailView`, `MailScopeLabel`, `MailCommands`, `MailAccountSettingsView`, `MailActions` | `MailUI` | public | the Mail screen and its app hooks |
| `MailListRow`, `FoundBlock`, `DraftComposer`, `AttachmentChip`, `PickLabel` + `.quietMenu()`, `ChipButtonStyle`, `MailGlass`, `MailDateText`, `FlowLayout` | `MailUI` | internal or private | mail rows, found rows, the inline draft, pick menus, grey chips |
| `.agentPanel(context:launch:floatingLauncher:room:expandedChanged:)`, `AgentPanelRoom`, `AgentPanelLayout` (the column's minimum and `fits`), `.agentPanelContextReader()`, `AgentPanelLauncher(style:)`, `AgentPanelCommands`, `AgentPanelActions` (`\.agentPanelActions`), `AgentPanelLaunch`, `AgentPanelSnapshot`, `\.isAgentComposerFocused`, `ChatMemorySheet`, `ChatLiveReply` (ma) | `ChatUI` | public | the agent panel (8.6): installed once on the main window's split view, the sidebar footer's launcher, ⌘J / ⌥⌘J, the app's hooks to `AppAgent`, renders |
| `CompactAgentPanel`, `ExpandedAgentPanel`, `AgentThreadView`, `AgentChangeList`, `AgentTaskLine`, `AgentComposer`, the attachment tiles, `PanelSurface`, `Fill2` (ma) | `ChatUI` | internal | the panel's forms, the thread, change rows, the task line, the composer; the inspector's opaque surface and Fill 2 (promote both into StudyUI on their second use; CaptureUI's `Color.inspectorBackground` has the same values) |
| `ToolbarGlyph`, `ToolbarSearchField` (240 pt; Notes 180), `ProcessingMark` | `App/` | app only | icon-only toolbar buttons, the Mac search field, the sidebar ring |

### 7.3 Add to StudyUI when first needed (use these names)

| Piece | Spec | Start from |
|---|---|---|
| ~~`SourceGlyph` + `SourceTrailPopover`~~ | added in M3 (7.1) | |
| ~~`DueRing`, `CourseBarRow`, `ProposalCard`~~ | added in M3 (7.1) | |
| ~~`Color.contentBackground`~~ (added in M3), `.inspectorBackground`, ~~`.canvasBackground`~~ (added in M6 as `Color.canvasBackground(_:)`, with `Color.highlighter(_:)`), `SectionLabel`, Fill 2 (`Hairline`, `QuietFill` added in M3; the CaptureUI and SearchUI copies merge when touched) | 3.1 | CaptureUI, SearchUI |
| `Color.accentSoft(_:)` made public (`Font.chip` and the mono helper `Font.mono` added in M3) | 3.2 | StudyUI, MailUI `.mailMono` |
| ~~`DayText.time(_:)`, `DayText.timeRange(_:_:)`~~ | added in M3 (with `DayText.dayTime`) | |
| `\.studyChrome` + `.studyGlass(in:)` | 3.4 | `MailGlass`, `.reviewGlass` |
| `PickLabel` + `.quietMenu()`, `ChipButtonStyle`, `FlowLayout` | 5.3 | MailUI |
| ~~Inline note attachments~~ | built in NotesUI (M6: TextKit 2 attachments, 7.2) | |

### 7.4 Duplicates: use the canonical one, merge when you touch the other

| Duplicate | Canonical |
|---|---|
| `TimeChip` in StudyUI (Button) and CaptureUI (internal Text) | StudyUI `TimeChip` |
| `TimeText.clock` "5:12" and CaptureUI `ClockText.string` "05:12" | `TimeText.clock` |
| Accent soft: `Color.accentSoft` (StudyUI), `.accentSoft` (CaptureUI), `ReviewTint.soft`, `.tokenStyle`'s own values | StudyUI `Color.accentSoft`, made public |
| `SectionLabel` in ReviewUI and CaptureUI | one StudyUI `SectionLabel` |
| `SeparatorLine` (CoursesUI) and `Hairline` (CaptureUI) | `Hairline` (0.5 pt) |
| `SegmentedChoice` (CoursesUI) and `FilterSegments` (SearchUI) | `FilterSegments` as the base (keys, accessibility) |
| `Color.fieldBackground` (CoursesUI) and `Color.contentBackground` (CaptureUI) | `Color.contentBackground` |
| `FlowLayout` in CoursesUI and MailUI | one StudyUI `FlowLayout` |
| Glass helpers `.reviewGlass`, `.filingGlass`, `MailGlass`; snapshot switches `\.reviewChrome`, `\.filingDrawsOpaqueGlass`, `\.mailChrome` | StudyUI `.studyGlass` + `\.studyChrome` |
| `Font.chip` (StudyUI) and `.mailMono(_:)` (MailUI) | one public StudyUI helper |
| `PickLabel` + `.quietMenu()` (MailUI) and `PlainMenu` / `PopUpPicker` (CoursesUI) | `PickLabel` for a guess on content; `PopUpPicker` in forms |
| `MailDateText` (MailUI) and `DayText` / `SessionText` | `DayText` + `DayText.time` |
| `TranscriptText` in Courses (struct in `GlossarySuggestions.swift`) and ReviewUI (enum) | ReviewUI's, or rename the Courses one |

Merge as part of the change that touches them. Don't start a refactoring sweep.

---

## 8. Screen specs

### 8.1 Approved screens (built)

The code and the maintainer's parity renders (mockup against build) are the reference. Change them only by an explicit design decision or when a later milestone adds what is listed as Later. The invariants that must survive any change:

**Today** (01). Sidebar + detail; M3.5: the chat as the inspector (8.6), only with Claude Code. Three zones in the 600 pt column:
1. **Hero card**, the first thing: eyebrow (dot 7 + course, subheadline semibold secondary, tertiary "· recorded Tue 13 Oct"); title "Review Lecture 2 before Monday" when the next lecture is within 7 days, else "Review Lecture 2"; meta with mono times ("Virtualization & IaaS · 1:08:13 · slides 1–37 of 88"); **"Start review"**, the one filled button (`.defaultAction`), then a 12 pt secondary aside "Lecture 3 is Mon 19 Oct at 12:15, Room 101". With nothing to review the hero is the next class; its Record shows from 30 min before the start until the end, only for courses with consent.
2. **Coming up**: one dated list of `CourseBarRow`s [10 pt marker | title naming the course | day over mono time in a 100 pt right column], soonest first: sessions within 8 days and open dated items within 21 days. Weekly lectures are left out (the next one is the hero's aside). Cancelled sessions stay, struck through in tertiary, with Restore Session in the context menu. A course bar is a class or event, a `DueRing` something due; a due item always has its own row. An event or announcement tied to a listed session folds into that row (the event names it, "First CL tutorial", which keeps the session's time range; the gloss; the sources); tied to a session that is not listed it is not shown. One event on several days is one row, the first day over "and Fri 13 Nov" (12 pt text). At most one 12 pt grey gloss line (the item's details, without a sparkle), an amber `star` before it for exam admission; the `SourceTrailButton` after the last line, its popover with the green check and Undo. Hover: quiet fill, neighbouring hairlines hidden. Items' context menu: Mark as Done, Add to Calendar, Delete.
   - **Tasks and replies (M3.5).** An open task (something to do without a date of its own) is a `DueRing` row: title, its details as the gloss, the source glyph and popover; context menu as for items (Mark as Done completes it, Delete). A task tied to a session that has not ended sits at that session's day, with no time (the session row carries the time; a session beyond 21 days hides it until then). Every other task and every mail that needs a reply (`needs_reply`, not answered) follow the dated rows, newest first, with an empty right column: no invented date and no filler. A reply row is a ring in the mail's course colour, "**Reply to Ada Example**" (the sender), the subject as its one grey line, the faint `envelope` as its source glyph; a click opens the mail in Mail; context menu Open Message, No Reply Needed (clears `needs_reply`, nothing on the server). Why rows and not a count in the mail line: the mail line only counts and "facts from mails live in the rows" (rule 5); a reply is something to do, like a task, and its row opens the mail in one click; still three zones.
3. **Mail line**: only with a mail account and unread mail; 42 pt over a hairline, 8 pt closer to Coming up: `envelope`, "**5 unread**", per-course dot + count in course order, "· 1 newsletter" in grey, trailing plain "Open Mail". It only counts; facts from mails live in the rows (M3.5: also mail that needs a reply, as "Reply to …" rows in Coming up).

M4: the hero's second meta line "5 highlights, 3 not on the slides" in grey with the screen's only sparkle (highlights = exam hints + highlights, hidden ones not counted; "1 highlight"; a zero part is left out; nothing before the study pass wrote rows).

**Live lecture** (02). Own window, no sidebar, opaque inspector, canvas on the canvas surface, no toolbar band, no inspector button on the Mac (⌃⌘I). Zones: the slide (first thing, no filled button) with the filing line under it (dot + "Data Centers · Lecture 2 · deck · Tue 13 Oct, 16:15 · Room 101" + plain "Change"); the filmstrip (current slide ringed with a bold accent number, future slides at 50 %); the inspector: mic + `LevelMeter`, "Captions" + "EN" badge (settling words tertiary, unsure dotted, no disclaimer), "Notes", "Stamps" rows [slides glyph | "Slide 15 · topic" | time chip]. Before recording, Record is `.borderedProminent` `.tint(.red)`; Stop is a red rounded square + "Stop" and asks first. Keys are off while typing; after Stop, notes and flag text are read-only. Later: pencil and image tools (not in M6: ink is Review's, plan-m6 §8), the iPhone backup glyph (M7), the you-pin on the slide.

**Lecture review** (03). Sidebar + [96 pt rail | slide over transcript] + inspector. The slide is the first thing, kept in step with the transcript; no filled button. The glass `PlayerBar` floats 14 pt above the bottom; rail and transcript end 8 pt above it and fade over their last 14 pt.
- The student sets the layout (`ReviewLayout`, one `@AppStorage` value, the same for every lecture). The 6 pt gap between slide and transcript is a divider with no line: row-resize pointer, drag to resize (slide at least 160 pt and at most its full-width height, transcript at least 120 pt; by default the slide is half the height to the window's bottom, as mockup 03). Dragged past half the transcript's minimum, or double-clicked, or View ▸ Hide Transcript (⌥⌘2), the transcript collapses and the slide fits the room (centred); the player stays whenever the lecture has a recording; the divider then sits above the player and drags or double-clicks back. The 10 pt between rail and slide is the rail's edge: drag it left past half the rail, double-click it, or View ▸ Hide Thumbnails (⌥⌘1); collapsed, the slide starts 16 pt from the edge and the edge drags back out. A collapsed pane's edge shows a small grabber (a 36 × 4 pt tertiary capsule across it) so it can be found; both panes showing, no line. No buttons or copy for either.
- Dividers "Slide 16" + mono "36:57–38:28"; off-slide stretches have untitled dividers. The current line is accent soft; clicking a line plays from it with Follow on.
- Doubt dots are a tertiary dotted underline on low-confidence content words (thresholds: decisions: "Transcript dots only content words"). A language tag shows only when the line's language differs from the lecture's. No marker tick.
- Player: −15, play/pause, +15, mono "37:27 / 1:08:13", scrubber with slide ticks, red flag marks and grey off-slide marks (M4: amber exam-hint marks; said-in-class items as purple `Color.ai` marks, which replace the grey off-slide marks once a lecture has them; marks of one kind closer than 0.5 % of the width merge), "1×" speed menu, Follow. ←/→, the stepper, a thumbnail or scrubbing pause playback and turn Follow off.
- Inspector "This slide" and "Whole lecture". Your notes (M6) are rich notes (`NoteEditor(.inspector)`, 8.4's editor at 13 pt): every note of the slide, or one empty editor (one quiet line) that becomes a note on its first keystroke (audio time = the playhead then); the time chip after the last word; a chip of this lecture moves the review (slide or playback), another lecture's opens it. "Whole lecture": the lecture's own notes (page nil, editable), then each slide's notes read-only after a `SlideChip`. Typing pins the inspector to its slide until the editor loses focus. On iOS the notes are read-only.
- Empty: no deck → no rail; no deck and no recording → the drop prompt for this lecture's slides (6.6), centred in the column; no recording → no player, no transcript; before transcription → `ProcessingProgress`.
- Delete (2026-10-19): the recording picker's menu ends with Delete Recording…, the slide count's menu has Delete Slides…; Edit ▸ Delete Lecture… / Delete Slides… / Delete Recording… for the lecture open here (below).
- M4 (the study pass; blocks appear when their rows land, no skeleton and no copy while the pass waits or is paused): "This slide" has Summary (one sparkle; grey 12.5 text, one `TimeChip`), Your notes, Further reading (≤ 2 `FurtherReadingRow`s, a click opens the URL), a hairline, then the lecture-wide Exam hints (amber `star`; 16 pt professor pin + “quote” in primary + `TimeChip`) and Only said in class (sparkle; grey rows + `TimeChip`), 3 rows each in time order, then a plain "Show N more". "Whole lecture": the lecture's Summary, every exam hint, Only said in class under Admin / Deadlines / Questions / Examples / Explanations, Further reading with a `SlideChip` each, Your notes by slide. Topics are not shown.
- Pins (M4) are drawn in an overlay over the slide bitmap (never re-rendered): a professor pin after the end of its `anchor_text` line, else in the top-right stack under the one AI pin (when the slide has further reading); at most 3 professor + 1 AI per slide, the student's own always; none on the rail or when the slide is narrower than 320 pt. Hover opens the `PinCard` on the Mac, tap on iPad/iPhone. Context menus: Hide (AI and professor items, gone from every surface), Add Pin (at the pointer; the card opens for typing; an empty pin is deleted when its card closes), Delete Pin (the student's own only).
- Corrections (M4): a patched word reads ~~old~~ (tertiary, red strike) + new (green soft, radius 3); corrected words lose their doubt dots; the line's menu has Revert Correction. A line quoted by a professor item ends with the 16 pt inline professor pin and the same card.
- Ink (M6, Mac; mouse and trackpad): the toolbar's [Pen, Highlighter, Flag] glass group after the stepper (6.3). Pen and Highlighter are toggles, one at a time; clicking the one that is on, Esc or turning Follow back on (the Follow button, ⇧⌘F, a transcript line, a time chip) ends drawing; while one is on an Eraser joins after Highlighter (1.3) and removes whole strokes. A tool turns Follow off: the slide stays put, the audio plays on. Clicks and drags on the slide draw (crosshair); the pins stay above the ink with their cards and menus (Add Pin works). The student's ink is blue (#0a5bd6), the highlighter yellow at 45 % multiplied over the slide's white paper in both appearances; it is drawn as vectors over the bitmap in its frame (never into it, never into the PDF, never on the rail). Ink belongs to the deck page: the same on that slide in every lecture. The rail's pencil marks slides with notes or ink. ⌘Z / ⇧⌘Z step through strokes and erases of the slide on screen.
- Flag (M6, F): the student's red flag at the playhead with the slide on screen; the scrubber's red mark appears; Edit ▸ Undo removes it. No text, no dialog.
- Shared decks (mr): a lecture's slides are its page range of a course's deck (`LectureSlides.current`; one PDF serves several lectures, never cut or copied). The rail, the stepper, ← / →, the toolbar's ‹ › and Previous / Next Slide show and stop at only the range, with the deck's page numbers ("50 / 88": S50 stays S50 in every lecture that shows it); the title's meta adds " · slides 38–88 of 88" when the range is not the whole deck ("Data Centers · Mon 19 Oct · slides 38–88 of 88"), nothing for a whole deck. A slide chip of this lecture outside its range does not move the review. The screen reloads when the range changes (the agent's link, continuation detection, their Undo). Ink stays per deck page; pins and notes stay per lecture. No copy explains the range.

**Search** (07). One surface scrolling under the toolbar. `FilterSegments` All | Lectures | Notes | Mail + a quiet "All courses ⌄". Groups: dot 9 + course (semibold) + secondary "L2 · Virtualization & IaaS · Tue 13 Oct" over a hairline; weak-match groups collapse to their header while another group matches fully. Hit row: glyph (`waveform` amber = professor speech, `display` amber = slide, `pencil` accent = your note) | top line + one `TimeChip` | two-line snippet with yellow highlights | optional 64 pt thumbnail with a blank card until it loads. Selected hit on `QuietFill`, radius 10. Searches on every keystroke, keeps old results until new ones land, follows the index; no refresh control.

M5: an "Also searched" line above the filters when the planner's alternatives were searched: one sparkle, tertiary "Also searched", the alternatives in secondary joined by " · " (12 pt, 8 pt in like the group headers, 10 pt above the filters); hovering a term shows a small × that removes it and searches again; no line without a plan. `FilterSegments` All | Lectures | Notes | Mail | Web. A Web group after Your notes and before Mail: `globe` + "Web" header; rows of a secondary glyph (`doc.text` a paper, `book` a manual or book), the title 13 pt primary over "byline · domain" 11.5 pt secondary; a click opens the page in the browser; it holds the reading that matched and the verified reading on the slides of the other hits (≤ 5) and never collapses. Multi-selection: click selects one, ⌘-click toggles, ⇧-click extends, ↑/↓ move one; consecutive selected hits share one `QuietFill` block (radius 10). Until the student chooses, the first group's hits (≤ 4, never mail) are selected (mockup 07); the selection is the tutor's context (8.6). Results show at once (keyword and on-device meaning); the alternatives fuse in when the plan lands; nothing waits for Claude. The Tutor toggle and the tutor inspector: 6.3, 8.6.

**Course Settings** (08). One scroll view of `SettingsGroup`s, two columns from 850 pt (one below 822; 3.3), autosave after 400 ms, no filled button. Groups: Course, Glossary ("Suggested" with one sparkle, kept offline from parity), Slides (deck rows, a ghost row when empty), Weekly slots (mono times, muted "Add room", ⋯ on hover, "Show in Calendar", a ghost slot when empty), Exam & exercises (`RuleRow`: prof pin, **Title.** text, one chip; AI wording grey with one sparkle and Confirm; unknown values muted), Recording (the switch is the gate; Scope "Lecturer only | Whole room"), Mail rules ("Sender is", "Mailing list is", "Subject contains", "<platform> course is" once the profile names a learning platform; learned rules after the user's, secondary). Switches small and green, segmented controls neutral, Tab reaches every row. Import .ics (Weekly slots and the More menu), like a timetable dropped on the course's sidebar row, opens the timetable sheet (8.3) with everything for this course.

**Import** (10). Drop anywhere (`.smartImport`); no import dialog; every sidebar course, lecture and session row is a drop target (6.2: the sidebar never moves during a drag; its rows keep their dates, overriding 10's title-only rows). HUD (first thing, glass, radius 16, 236 wide): dot + course (14 semibold), "Lecture 3 · Mon 19 Oct", "58 slides" or a mono duration, [Change…]; it follows the cursor with one destination and stays put when it offers a choice; it hides over the sidebar, where the row under the cursor lights up instead. Toast after the drop: 38 pt file tile, course, "Lecture 1 · Tue 13 Oct", "Recording 6.m4a · 44:34", [↶ Undo] [Change…]; captures offer Change… only (Undo never deletes a capture); an unfiled file's toast offers Change…. No copy explains the matching.

**Course Lectures, Slides.** `CourseLecturesView`: `LectureListRow` (waveform glyph, "L2 · Title" over the day, tertiary chevron, min 50 pt) in a 760 pt column; its menu Open, Delete…. `CourseSlidesView`: the course's decks as a `List` (`.inset`, system selection) of `DeckRow`s in a 760 pt column: the deck's title over its lecture(s) and day, no button; a click opens the review of the lecture that uses the deck at the first page of its range (several lectures: a menu "Lecture 2 · slides 1–23"; none: Quick Look), ↩ opens the selected deck (its first lecture), Space toggles its Quick Look; the row's menu (`DeckMenu`, also on Course Settings' deck rows) Open in Review (one item per lecture), Quick Look, Show in Finder (Mac), Change…, Delete…; deck thumbnails are later. Both: toolbar [Import +]; files dropped anywhere on the screen go to the course; empty, the drop prompt (6.6) instead of a lone glyph or a ghost row.

**Deleting decks, lectures and recordings** (2026-10-19). Delete… is in the context menu of every deck row (Slides, Course Settings), every lecture row (a course's Lectures, the sidebar's lecture rows; Retry Processing stays first after a failure), Review's recording picker (Delete Recording…) and slide count (Delete Slides…), and Edit ▸ Delete Lecture… / Delete Slides… / Delete Recording… for the lecture open in review (list rows are buttons: the Edit menu acts on the open lecture only). Every entry asks the window's one confirmation dialog (`FilingCenter.requestDelete`, `libraryDeleteConfirmation`), which names what goes: "Delete “Virtualization & IaaS” (88 slides)?" over "Your 3 notes and the ink on its slides go too."; a lecture: "Its 2 recordings, transcript, 3 notes and 14 practised questions go too."; a recording: "Its transcript goes too." (its notes and flags stay with the lecture). Zero counts are left out; the student's notes, ink and practice never go silently. [Delete] is destructive, with Cancel. Edit ▸ Undo Delete Slides / Delete Lecture / Delete Recording puts everything back, Redo deletes it again; the files are kept until the next launch. Deleting the lecture on screen shows its course's Lectures. **Courses** (2026-10-19): Delete Course… is the last item of the course row's sidebar menu (after a divider) and of Course Settings' More menu; the same dialog asks "Delete “CL”?" over "3 lectures, 88 slides and 2 recordings are deleted with it." (zero counts left out; no line when nothing goes; the student's notes stay and are not named); Edit ▸ Undo Delete Course. Deleting the course on screen (its screens, a lecture, its notes or mail) shows Today.

### 8.2 Mail — mockup 05 — built, wiring in progress

Built in `Packages/MailUI` (README there; plan-m2 §5). What remains:

**Integrator wiring** (plan-m2 §7, App only): the Mail row's scopes as sidebar children (6.2); `MailView(scope:selection:query:)` as the detail with `\.studyServices` and `\.mailActions` wired; the toolbar field with "Search mail" feeding `query` instead of opening Search; `MailCommands`; `MailAccountSettingsView` in Settings ▸ Accounts (the Claude key's Save filled only while its field has text); app snapshot shots `05-mail…`; the Today/Search prompt "Search lectures, notes, mail".

**Deviations to fix in MailUI or Mail** (this document wins):

1. `MailDateText.clock` follows the locale's hour cycle, so a 12-hour region gets "1:37 PM". Times are always 24-hour: use `DayText.time` once promoted, or `SessionText.time`'s pattern.
2. An empty scope shows a blank list. Show the scope's glyph in the list column (`ContentUnavailableView`; no next step to offer, so no line). Course lists show only for courses with mail (6.2), so few are empty.
3. A sync failure shows nowhere on the screen. Put "Offline" or "Sign-in failed" in the toolbar subtitle from the account's sync state.
4. `MailSender` stores "Not sent." with a period; MailUI's fallback is "Not sent". State strings have no final period.

Built and correct, so don't "fix" them: "In Calendar" on found rows, the fixed 318 pt list, the sender's address instead of a role, plain-text Confirm on found rows, the platform file menu's Change… opening the change sheet (6.5), the attachment tile.

**The screen as built (keep it):**

- **Zones:** list (318 pt, fixed) | reader. Toolbar per 6.3; the title is the scope's name, with no subtitle at rest (the unread count is the sidebar badge).
- **List row:** an 8 pt unread dot (accent; white on the selected row); sender semibold, M3.5: a small tertiary `arrowshape.turn.up.left` while triage says the mail asks the student something and it is not answered (no chip, no copy; the row's context menu adds No Reply Needed; Send of a reply sets `is_answered` and the marker goes), `flag.fill` secondary when flagged, time right ("13:37" in SF Mono, "Yesterday", else the day); subject + 7 pt course dot at the end; one 12 pt secondary snippet line. At most one extra line, only when there is something to act on:
  - a proposal: the grey chip-menu "Move to Room 5?" (5.3);
  - a learning platform's "New file" mail whose file was filed: `doc.richtext` + the lecture as a pick menu "Lecture 2 · Tue 13 Oct" (Open Lecture 2, Change…);
  - a failed send (in Drafts): a secondary warning triangle + the reason, or "Not sent".
  
  An unsent draft without a recipient lists as "New Message", a mail without a subject as "No Subject". System list selection.
- **Reader** (the selected message is the first thing): subject 17 semibold; a 32 pt initials avatar (quaternary circle); the sender's name (semibold) and address (secondary, middle-truncated), the date right (12 pt tertiary, "Today, 13:37"); "To: …" in secondary with the route pick menu at the right (course dot + name; courses, then University, Newsletters, Personal, Other; "No Course" when unrouted).
- **Found block** (only when there are items): one sparkle, between hairlines. Rows in the order their quotes appear in the mail (subject first), then by due date. Each row is grey AI text with the facts in bold and the clock in SF Mono semibold ("Sheet 1 due **Thu 29 Oct, 23:59**"), then its state:

  | State | Shows |
  |---|---|
  | added on its own | green `checkmark` + "In Calendar" (12 pt secondary) + Undo |
  | tied to an existing session, or a confirmed proposal | "In Calendar" without Undo; a `TimeChip(prefix:)` when the source is a lecture ("L1 · 31:05") |
  | dated but not verified | Add to Calendar (`calendar.badge.plus`) |
  | a room change or cancellation | Discard (secondary) + Confirm (accent); plain text buttons |
  | undone | struck through, tertiary, + Restore |
  | discarded | struck through, tertiary |

  "In Calendar" is the one state word on the screen, as mockup 05 draws it: the calendar is not visible here. Don't remove it, and don't copy it to other screens.
- **Body:** sanitized HTML rendered to `AttributedString` (no WebKit); found quotes have a purple dotted underline (lost when the row is undone or discarded); quoted earlier mail collapses behind one "…" capsule.
- **Translate** (decisions: "Mail Translate" and its 2026-10-20 row): on-device OPUS-MT models (as local-translate), in place and streaming: the subject lands first in the student's language (primary), then each paragraph replaces its original as soon as it is translated, translated paragraphs grey (`.secondary`, per paragraph; one still waiting shows the original in primary); the found block, attachments, quoted mail and the draft untouched. The first use of a language pair downloads its model once: meanwhile a thin determinate `ProgressView(value:)` (linear, mini, full width) runs along the reader's top edge, with the help "Downloading model" and no other copy; loading a downloaded model shows nothing. A failure turns the toggle off with the help "Couldn’t finish". No sparkle, no "Translated from …": the toolbar toggle's on state is the signal.
- **Attachments:** the mockup's tile in a flow: card surface, radius 10, 26 pt type glyph, 12.5 medium name, 11 pt secondary size in binary units ("412 KB"). Click opens Quick Look; drag out gives the file.
- **Draft:** inline at the bottom of the reader, card surface, radius 12. To tokens after a reply or envelope glyph. The agent's unchanged words grey with one sparkle at the start; the student's words primary; typing stops the agent. [Discard] (bordered; deletes the draft) [**Send**] (`paperplane.fill`, the one filled button, ⇧⌘D), disabled while generating, sending, or without recipient or text. A failure shows in red under the editor, and Send works again. "Draft cut short" when the model stopped early.
- **New Message:** the same editor in the reader zone with To and Subject, no agent.
- **Drafts scope:** the selection is the draft's id; a reply draft shows under its message, a new message alone.
- **Behaviour:** a selected unread message is marked read after 0.8 s; Reply always asks the agent, and when that fails writes an empty threaded reply; no selection leaves the reader blank.
- **No account:** `envelope`, "Connect your student mail." and one filled "Set Up Mail…" (opens Settings ▸ Accounts); the title "Mail", no toolbar actions, no lists under the Mail row (6.6). The password is a `SecureField`; servers are disclosed on demand.
- **Chat (M3.5):** the inspector is the chat (8.6) with the open message as its context line; Show Chat ⌘J. M5 adds lectures to the same chat.

### 8.3 Calendar and deadlines — mockup 06 — built (M3)

- **Window:** sidebar (6.2, with the calendar checkboxes) | week grid | inspector "Deadlines" (336, the system inspector background). Two zones.
- **Data:** the grid draws the library's rows: sessions (`lecture_session`) and tracked items. It never reads the "Socrates" EventKit calendar back; that calendar is the mirror. Other calendars come from EventKit, read-only, only when checked: drawn like events in the calendar's colour, without popover or actions.
- **Toolbar:** "October 2026" ("Oct – Nov 2026" when the week spans two months) / "Week 43" (ISO 8601) … [‹ Today ›] [+]. Week only in M3. [+] opens the agent panel (ma: compact, composer focused; the "New deadline" composer is gone). No search field.
- **Grid** (Mon–Sun):
  - day header row 40: weekday 11 secondary + date 15 semibold, bottom-aligned; Sat/Sun 36 wide, stacked 10 tertiary over 12 medium secondary, on `QuietFill`. Today's date is accent.
  - all-day row 28 with a right-aligned "all-day" gutter label (10 tertiary): all-day deadlines as pills (height 19, radius 5, 11 medium, course tint 14 % and course text).
  - hours 08:00–18:00 visible at 56 pt per hour (scrolls for the rest, without a visible scroller; opens at 08:00); 44 pt gutter with mono 10 pt tertiary labels; 0.5 pt hour lines; columns separated by 0.5 pt lines.
  - the current time in today's column: a 1 pt accent line with a 6 pt accent dot at its leading end.
  - **event**: radius 6, course tint 15 %, 3 pt inset course bar on the left, 11 pt course text: mono time range, semibold title ("DC Lecture 3", the short course name), the room in course sub-text. A cancelled session is struck through in tertiary. A proposed change is a dashed tag inside it ("Room 5?").
  - a timed **event item that is no session** (the timetable's exam review, "Klausureinsicht") is a block like a session, not a due line: its start alone ("11:00", the end is not stored), its title, its short room; one hour tall (the length the calendar mirror gives it).
  - an item due at 23:59 draws as an all-day pill too (mockup 06's Quiz 1); its time stays in the inspector row and the popover. Tags and pills show the item's title on one line.
  - **timed deadline**: a 2 pt course-colour line at the due time, an 8 pt dot at the column's leading edge, and a tag under the line (11 semibold, radius 6, course tint, course text: "Survey due"). Selected: the tag filled with the course colour, white text. (M3's dashed preview of the composer's parse went with the composer in ma.)
  - an event tied to a session is that session (not drawn again); announcements are not drawn; a cancellation proposal's tag reads "Cancelled?". Overlapping blocks share the column in lanes; the all-day row grows when a day has more than one pill.
- **Click:** a click on a session, an event block, a deadline tag or a pill selects it (filled with its course colour, white text; a tag also selects its inspector row) and opens its **detail popover**; Esc or a click elsewhere closes it. Hovering an item with sources opens the light source popover (5.2, the item's detail as its header, Undo in the footer) as before, and a click turns it into the detail in place. Double-click or ↩ opens the session's lecture when it has one, else the course. A session's context menu has Cancel Session or Restore Session; an event block's Add to Calendar and Delete. Clicking an inspector row selects it and moves the grid to its week (no popover); its Undo shows while hovered or selected.
- **Detail popover** (system `.popover`, 300 wide, the arrow on the item's leading edge, padding 12/14; like Calendar.app's event popover, in the calm style: no explanatory copy, SF Mono for times, provenance by typography, at most one filled button). Blocks are separated by 0.5 pt hairlines with 10 pt above and below; a fact is a row of [16 pt secondary glyph | 13 pt primary over a 12 pt secondary line].
  - **Session:** course dot 10 + "Data Centers · Lecture 3" (15 semibold; the kind with its number; struck through in tertiary when cancelled). `clock` "Mon 19 Oct, 12:15–13:45" over "weekly" / "every 2 weeks" (from its weekly slot; a one-off has no line). `mappin.and.ellipse` the room ("Room 104"), over the full location ("Sample Street 1, Lecture Building") only when the stored room holds one (weekly slots and sessions store the short room today). `graduationcap` the course's lecturers. Then one block per item tied to the session: a waiting room change or cancellation (M2's proposals still open in a library) as sparkle + "Move to Room 5?" / "Cancelled?" (13 semibold) with Discard (secondary) and Confirm (accent) as text buttons; a settled one "Moved to Room 5" / "Cancelled", and since ma a time change "Moved to Tue 20 Oct, 12:15" and an extra session "Extra session" (the agent applies session changes on its own; the footer's Undo takes them back); a folded event by its title and grey gloss; each over its source rows (`SourceTrailRows`). The lecture the session became: `waveform` "L2 · Virtualization & IaaS" (13 medium) over the recording's length (mono) and the study pass's sparkle + "5 highlights, 3 not on the slides". The course's next deadline as one row: [`DueRing` | title (+ exam chip) over "Thu 29 Oct, 23:59"], a click selects it. Footer: [Cancel Session / Restore Session] … [Undo] (an automatic change of a tied item) [**Open Lecture**] (filled, ↩) when a lecture exists, else [Open Course].
  - **Deadline, exercise, exam, task, event:** course dot 10 + the title (15 semibold); a 12 pt secondary line with the kind ("Exam"; "Data Centers · Exercise" when the title does not name the course) and the exam-admission chip when set. `clock` "Mon 19 Oct, 23:59" (the day alone when all-day; " · SN seminar" when tied to a session). `mappin.and.ellipse` the short rooms ("Room 102 / Hall A") over the full locations. The gloss (the item's details, when they are not its rooms) grey with one sparkle (primary for the student's own item). Then the source rows: the timetable file with its quote, a mail (opens it), a recording with its `TimeChip` (plays the lecture at the second), what the student typed. Footer: the green `calendar.badge.checkmark` or [Add to Calendar] … [Undo] for an item added on its own, else [Delete]; [Mark as Done] (not for events). No filled button.
  - The source popover on hover and the detail are one popover per item, so they never stack. Off screen (the parity render's calendar sample) the detail draws inline as a card beside its item.
- **Sidebar checkboxes:** one section per account as in Calendar.app, the Socrates calendar's account first; other calendars' checkboxes take the calendar's colour.
- **Inspector "Deadlines":**
  - proposal cards first (`ProposalCard`, 5.3, with its trailing source glyph); Confirm is the screen's one filled button while a proposal waits.
  - then rows by due date from today: [course dot 9 | title 13 medium (+ one exam chip only where it is the point: `star` + "Exam admission", amber on professor soft) | trailing faint source glyph(s)] over one 12 pt secondary line "Mon 19 Oct, 23:59" (" · Prototyping session" when tied to a session). Undo on hover for items added on their own. Selected row on `QuietFill`, radius 9. Done and dismissed items leave the list.
  - the list ends with its last row (ma: no composer; a deadline is added by asking the agent panel, which [+] and Calendar ▸ New Deadline open). While the panel is expanded the Deadlines inspector (and its Show Inspector) hides: the panel takes its place.
- **Timetable drop** (decisions: "Timetable `.ics` drops"): `.ics` files from the university's timetable system (one per course unit: lecture, exercise, seminar) dropped anywhere in the window (Calendar included), on a course row, or picked with File ▸ Import… or Course Settings' Import .ics open one sheet per drop, "Import Timetable": a `Form` section per course (dot 9 + semibold name; a checkbox, off, for a course the library does not have; its rows only while checked), its new rows as `LabeledContent` [kind | grey facts with mono times: "Mon 16:00–18:00 · Room 104 · weekly", "Fri 12:00–14:00 · Room 103 · every 2 weeks", "Mon 12 Oct, 16:00–18:00 · Room 204", an exam "Tue 9 Feb, 10:00–12:00 · Hall A"; the full location as `.help`], then the semester with the break it widens ("Christmas break · Thu 24 Dec – Wed 6 Jan"); [Cancel] [**Import**]. No copy. Dropping the same files again shows no sheet, or only the courses still to add. Exams arrive as items added on their own (calendar glyph, the popover row: file name over “Klausurtermin 1 · 09.02.2027 10:00”, Undo).
- **Keys:** 6.8.
- **Empty, with real data:** the real library has no weekly slots yet, so its week shows only what exists. Never invent sessions; no ghost events, no copy. With no deadlines the inspector is empty. Verify on a copy of a sample library with placeholder slots, sessions and mail-derived items (11.3).
- The app writes only to its own "Socrates" calendar, never touches other calendars, and has no invitee field.

### 8.4 Notes — mockup 04 — built (M6)

Built in `Packages/Notes` (README there; plan-m6 §4, §5.1) and wired by the app.

- **Navigation:** a top-level Notes row after Mail (`note.text`; Go ⌘4, Search ⌘5 and ⌘F). Its children while it shows: All Notes, then each course with notes (6.2). The course's own Notes screen (its sidebar screens, 08) is the same screen scoped to that course, without the search field. A note opened from Search (a lecture or course note; a slide note opens Review at its slide and moment) shows under the Notes row with that note selected.
- **Layout:** note list column (236) | `Divider` | editor (content background). Toolbar per 6.3: the title "Notes" (a course's: over the course), New Note in its own glass, the editing groups only while a note is open. A scope without notes is one line and New Note over the whole detail (6.6).
- **List:** All Notes groups under course headers (dot 8 + name, subheadline semibold secondary, no counts), in course order, newest first within a course; notes without a course last, without a header. Rows: name 13 semibold; one line of time (12 medium primary: "09:41" SF Mono today, "Yesterday", the weekday within the last week, else the day) + preview (12 secondary), padding 7/6 in an `.inset` list; system selection. Names: the title (the first block when it is a level-1 heading), else "DC L2 · Slide 15" (a slide note), else "DC L2 · " + the first line (a lecture note), else the first line, else "New Note"; the preview is the first line after what the name used. The toolbar field ("Search notes") filters the list in place (titles and text, case and diacritics folded); no hits → `ContentUnavailableView.search` in the list column. Context menu: Move To ▸ course ▸ (the course itself, its lectures) and Delete; ⌫ deletes; Edit ▸ Undo restores. With nothing selected the screen opens its newest note (Apple Notes).
- **Document:** the centred stamp "16 October 2026 at 09:41" (11 pt tertiary, tabular digits, from `updatedAt`) 2 pt from the top, the text 27 pt down, 52 pt in from the left and at most 680 wide (Apple Notes: a wide editor leaves its room on the right), the stamp centred over the text; Title 22 bold, Heading 17 semibold, Subheading 15 semibold, Body 14 on 21.7 pt lines, paragraphs 9 apart. Aa ⌄ opens a popover of the four paragraph styles; checklist, image, sketch, Slide and Quote insert at the caret. The user's text is primary. Bold, italic, underline, strikethrough, yellow highlight, links (the system link panel; typed URLs are detected; a click opens the browser). Lists indent 24 pt per level: bullets 5 pt (hollow every other level), numbers right-aligned 6 pt before the text, round 15 pt checkboxes (1.5 pt tertiary ring; done: accent with a white check) that toggle on click. Inline `SlideChip` "S13" and `TimeChip` ▶ "37:59" are one character each; a click opens the slide or plays from the time. A professor quote is its own paragraph: a 3 pt amber left bar, the “quote”, and a by-line (16 pt professor pin + "Prof. Example" + `TimeChip`, 12 secondary).
- **Inline attachments, like Apple Notes.** Images, slide clips and sketches are TextKit 2 attachments **inside the paragraph's text**: inserted at the caret, they move, select, delete, copy and undo like characters. Each is line-wide, so it takes its own line within the paragraph (3 pt above and below); text never wraps around it (mockup 04's floats are not built, 1.3). Radius 10 with a 0.5 pt separator ring. Images are drawn downsampled to their display size (ImageIO), at most 680 wide. A slide clip (256 wide) draws the page from the deck's PDF with an opaque `SlideChip` 5 pt in from its top right and opens the slide on click. A sketch draws `InkView(.sketch)` on the canvas surface; a click draws on it in place (`InkCanvas` with a pen / highlighter / eraser strip in glass at its bottom right and an accent ring while drawing); Esc or a click in the text ends it.
- **Slide and Quote:** Slide opens a popover of the note's lecture's slides as thumbnails (a course note: its course's lectures, newest first, under "L2 · Title"); a click inserts the slide clip at the caret. Quote opens a popover with a filter field over the lecture's transcript lines (mono time + 12.5 pt line; "L2 · " before the time when several lectures show); a click inserts the professor quote.
- **New Note** (the toolbar button; no key, 6.8): an empty note in Title at the top of the list with the caret in it; it becomes a row on its first keystroke, in the scope's course (All Notes: the selected note's course, else none). A note in Review starts in Body.
- **Paste and drop:** images (files or image data) become inline images; note text keeps its chips and media; other text pastes plain in the paragraph's format.
- **Storage:** one paragraph is one `NoteBlock`; inserted media are `NoteInline(.attachment)` inside a paragraph block's `inlines` (images: the original bytes in the BlobStore; sketches: `InkDrawing` blobs; slide clips: the deck's own PDF blob with the inline's `source`). The editor never creates `NoteBlock` `.image`, `.drawing` or `.slide` blocks: it shows ones it finds (older or imported notes) and keeps them, like unknown kinds. Stacked blocks were rejected. A note is written only after the student changed it, 500 ms after typing stops and when its editor closes; unchanged blocks keep their JSON (decisions: "A note is written only after the student changed it").
- **iOS:** notes render read-only (no iPad work in M6).
- **Later:** the AI suggestion at the caret (grey text + one sparkle + `globe` and the domain + [Accept ⇥] [Dismiss]; Tab / Esc) and Save to notes under a tutor answer wait for a provenance rule for Claude's text in notes (1.3); tables (no table block); ink in the live lecture window; iCloud sync of notes and ink (M7).

### 8.5 iPhone — mockup 09 — built (M7)

- **Shell** (`PhoneShell`, Phone): iOS 26's floating tab bar, Today `sun.max`, Courses `books.vertical`, Calendar `calendar`, Mail `tray`; **Record** is the bar's separate circular slot (glass, a red `circle.fill`; a red `waveform` while recording; it opens the recorder either way). Each tab its own navigation stack with the large title; the header's trailing glass buttons Search (`magnifyingglass`: the library's search full screen) and the agent bubble (`bubble.left`, only while iCloud sync runs, 8.6).
- **Recorder** (`RecorderScreen`, presented full screen): a leading `chevron.down`; course menu [● Data Centers ⌄] (13 semibold course colour on its 14 % tint) … [■ Stop] (red-soft capsule, 34 high); a 76 pt SF Mono light timer (tracking −3) with the 12 pt pulsing dot 26 pt to its left; "Lecture 2 · Tue 13 Oct" 15 pt secondary; a 70 pt waveform (3 pt bars at a 6 pt pitch ending at the red playhead, four samples a second, accent stamp lines with a 7 pt dot); "Slide 17 of 88" (15 semibold + 13 secondary) over the slide (radius 10, the slide's hairline and shadow), "Slide 17" alone without a deck. **The first thing is the 88 pt "Next slide" button** (accent, radius 26, 25 pt semibold, `chevron.right`), then [‹ Previous] [Flag] (54 pt, radius 18, quiet fill, Flag's glyph red). Stop asks "Stop recording?" (Stop, destructive). A failed start shows Live's alert ("Microphone access is off" with Open Settings, "Recording is off for this course", …). Before recording and after Stop: 1.3. Only courses with recording consent can record; the default course is the class on now, else the last one used; without the class's deck on the phone the slides count from 1.
- **Live Activity** (`SocratesWidgets`, views in `Widgets/Shared`): Lock Screen: course dot + "Data Centers", "Slide 17 of 88 · DC Lecture 2", the elapsed time in SF Mono (frozen at Stop), [Next Slide] (accent, flexible) [Stop Recording] (sized to its text, fill 2, red `stop.fill`); Dynamic Island 1.3. It starts with the recording, updates only when what it shows changes, and ends at Stop (dismissed at once).
- **Today** (phone, 16 with 8.1 and section 4): the date line "Friday 23 October · 25 min planned" (13 semibold secondary, capitals, the digits in SF Mono) over the large title "Today" (the bar's `.largeTitle` item; "Today" inline when scrolled); the hero card (radius 22, padding 16/16/14): eyebrow 13, title 26 bold, meta 15, the one filled button the whole width under the thumb (50 pt capsule, 17 semibold), "Then read J&M §4.9 · 15 min" centred under it (13); "Coming up" (17 semibold) over one card (radius 20) of rows [4 pt bar or 10 pt ring | title 15 semibold over the 13 pt gloss (the amber star for exam admission), the source glyph after the last line | the day (15) over the time (SF Mono 12.5)], hairlines from 36 pt; the mail line at 15 pt. A tap opens a row's source popover (a reply row opens the mail); a long press its menu.
- **To the Mac:** after Stop the capture waits in the outbox; Share sends one `.lecturebundle` (AirDrop); the Mac's smart import files it (course by id, else by name; session by start time) like any capture, and opening the file in Finder does the same.

### 8.6 The agent panel — the agent panel mockup with its approved changes (ma)

Built in `Packages/ChatUI` (README there; plan-agent §6) and wired to `AppAgent` by the app. ONE panel for the whole main window and ONE conversation across screens (until New Chat): the screen only changes what the next message is about. Only with Claude Code (`AgentPanelActions.isAvailable`): without it the launcher, the panel and the menu items are absent, with no copy. It replaces M3.5's chat inspectors (Today, Mail), M5's tutor (a course, Search's Tutor toggle, Review's Tutor tab) and Calendar's "New deadline" composer.

- **Compact:** a panel floating over the window's content, 336 wide, 12 pt from the window's trailing and bottom edges; the inspector's opaque surface (#f8f8fa / #222225: answers are content, never glass), radius 14, a 0.5 pt ring (black 12 % / white 14 %), the mockup's panel shadow (0 18 40, spread −14 / −12: it falls below the panel, never clouding the rows above or beside it). **Movable** by dragging its title row (the free part of the row shows the grab pointer; the title menu takes at most 200 pt); the place is kept per window (`@SceneStorage("agent.panel.position")`, an offset from the bottom-trailing corner, clamped into the window under the toolbar). As tall as its content up to half the window (title row, task line and composer included), then the thread scrolls with a 40 pt faded top edge (and a 14 pt faded bottom edge while more is below, as Review's rail and transcript; the task line 6 pt under it). It shows the whole conversation. It opens with the latest exchange's question 44 pt under the top, clear of the fade (or at the bottom when that exchange fits, or while an answer is written). It follows a streaming answer only while scrolled to the end, and ↩ scrolls to the end (2026-10-20; supersedes the latest-exchange window of 2026-10-18); a New Chat shows only the title row and the composer. While it sits in its corner the filing toasts stack above it.
- **Expanded:** the window's full-height right sidebar (its `.inspector` column), resizable by its leading edge (min 300, ideal 380, max 560; the width the student drags is kept in `@AppStorage("agent.panel.width")`, never a width a window resize, a sidebar toggle or a narrow window imposed); it opens at that width or the room the window has beside the sidebar and the screen's 480, whichever is less (300 at least; 6.1). Its 52 pt header (the title row) is the toolbar's own items over the column: the title menu (truncating past 200 pt), flexible space, ⤡ and Close; nothing measures the column. The column is the compact panel's opaque surface (#f8f8fa / #222225) with a 0.5 pt hairline on its leading edge, so nothing of the screen beside it shows through. The width the student drags is stored once the drag rests. On Review and Calendar it takes their inspector's place until ⤡ / ⌥⌘J; elsewhere the screen narrows to its 480 pt minimum, and in a window too narrow for the sidebar as well the sidebar hides until the panel shrinks (6.1). Never two inspectors.
- **Title row** (38 compact, 52 expanded): the conversation's title as a menu (13 semibold; "New Chat" in tertiary for an empty one): recent conversations by day ("Today", "Yesterday", the weekday within the week, then "Tue 13 Oct"; titles only, the open one checked), then New Chat and Memory… (the Memory sheet below); then ⤢ Expand Chat / ⤡ Shrink Chat (`arrow.up.left.and.arrow.down.right`) and Close (`xmark`, "Hide Chat"), 28 pt borderless secondary.
- **Launcher:** `bubble.left` in the sidebar footer before the Settings gear (6.2), tinted while open; floating 32 pt glass at the window's bottom-left while the sidebar is collapsed. No toolbar chat buttons anywhere (6.3).
- **Thread** (padding compact 2/14/12, expanded 14/16/14; 12 between entries; anchored to the bottom): the student's words a bubble on Fill 2 (radius 14/14/4/14, at most 250 compact / 264 expanded, 13 pt primary); files sent with it as small tiles above the bubble (an image thumbnail 44×28 with a hairline edge; a PDF `doc.richtext` + name + "3 pages"; a text file `doc.plaintext` + name + size; 28 pt, radius 8); the answer 13 pt in the answer grey with ONE sparkle, Markdown with its emphasis (bold, headings, table headers, code) in the label ink (3.2's agent answer rows) and the M5 checked chips (a slide "S13", a moment "37:59" that plays, a web page `globe` + domain; only chips that check out against rows or tool results; "L2 · " only when the answer cites another lecture than the one asked about). A **faint context line** (11 pt tertiary: the screen's sidebar glyph + "DC Lecture 2", "Calendar", "Inbox"… and a hairline) before an exchange asked on another screen than the one before (the student's bubble just sent has it at once). **Task results**: after a faint `checklist` + the task's title, the result as an answer; a task that failed: the same line with a secondary warning triangle after the title (its reason on hover; under the line on the phone); one the student cancelled: the title struck through. No tool activity (narration before a tool call is left out: one short line without a marker when the text after it is longer, decided the same while streaming and once stored), no thinking, no mail text, no `<attached_file>` text (a message of files alone shows its tiles). Every sparkle in an answer has the text's size; a list's sparkle sits in its first item, a table's, code's or quote's on its own line above. Tables are as wide as their cells and scroll sideways when wider than the panel; inline `code` is SF Mono 1.5 pt under the text on the quiet fill. A paragraph's Markdown is read as a whole, so bold or italics around a chip keep their style on both sides (no `**` left where a chip split it). An answer with chips has Copy in its context menu (chips as "S13", "37:59", the domain). A marker the agent got wrong is left out, never shown raw.
- **Change rows** (`[[change …]]` in an answer, e.g. for "what did you change?"): [the item as Today and Calendar name it, 13 medium primary | the grey summary 12 secondary with its times in SF Mono ("Moved to Room 5 · Mon 19 Oct") + the source glyph (`envelope`, `bubble.left`, `waveform`, `calendar`) | when it was applied as the Notes list says it: mono "14:08" today, "Yesterday", the weekday within the week, "Tue 13 Oct" (11 tertiary)], hairlines between rows, `QuietFill` on hover; a 350 ms rest opens the source popover (`SourceTrailPopover`: the source, the exact quote, Undo). An undone change: struck through, tertiary, no Undo. Change answers are rows only: a list item that carries a change marker gives way to its rows (the item's words would say each change twice); a sentence keeps its words with the rows after it. Rows that start the answer have the sparkle's column; others start at the answer's text edge.
- **Task line:** the open conversation's own sub-agent tasks only (never the app's background work; none for a New Chat): while they are queued or running, one quiet 11.5 pt secondary line above the composer: "2 tasks running" / "1 task running", or "1 task waiting" when none runs; a click lists them in a popover (title, elapsed time in mono, Cancel).
- **Composer** (radius 12 on the content surface, 0.5 pt ring, 1–6 lines): files waiting as tiles above the field (× on hover); [paperclip (`paperclip`; images, PDFs, text and code only) | the field | Send (`arrow.up.circle`, accent outline) only with text or a file / Stop (`stop.circle`) while the agent works]. The prompt names the context: "Ask about today", "Ask about this week", "Ask about this mail" ("Ask about your mail" without one), "Ask about this lecture", "Ask about this course", "Ask about this note", "Ask about the selection" ("Ask about your lectures" without one); after a question in this opening of the panel "Ask a follow-up…". Keys 6.8. Never blocks: typing works while the agent answers.
- **Drop and paste:** files the accept rule takes (images, PDFs ≤ 32 MB / 100 pages, text and code ≤ 512 KB; ≤ 5 per message) ring the panel in the accent (2 pt) and become tiles; anything else gets no ring, so the window's smart import keeps it. ⌘V pastes a screenshot or a copied file.
- **Context (implicit, never typed):** the screen, the course, the open mail, the lecture with the slide on screen and the playhead at ↩, the calendar week and the selected item or session, Search's query and selected hits, the open note. Review, Calendar and Today publish theirs (`.agentContext`), the app the rest.
- **Streaming and states:** the answer streams into place about ten times a second; a skeleton line (redacted, no shimmer) before its first words; the student's words and files show at once (the thread scrolls to them). "Paused until 17:20" (a usage pause; the time in SF Mono; it ends by itself at the reset), else a secondary warning triangle + "Not answered" (12 pt) with the stored sentence under it in tertiary ("Claude Code is signed out.", "The answer stopped early."), then "Try again" (borderless, 12 pt, tint); when part of the answer was written it stays, and the triangle stands with the sentence alone ("The answer was cut off."). A run the student stopped keeps what it wrote (grey, its sparkle) and has no line. What a stopped, failed or cut-off run wrote stays under the message it answered when the student sends the next one; Try again replaces it once the new run starts. A message that could not go comes back into the composer before whatever the student wrote since, with one readable sentence under it (11.5 pt secondary, e.g. "Notes.pdf could not be read.", else "Not sent").
- **Trust** (behaviour, not copy): the agent changes the app's own data on its own only with a code-verified exact quote (the student's words, a mail, the lecture's lines, the timetable file), each change in the activity log with Undo where it lands (the change rows, Today, Calendar's detail, Mail's "In Calendar"); it writes reply drafts that appear grey with one sparkle under the mail in Mail; it never sends mail, writes other calendars, or deletes notes or recordings (those tools do not exist). Reminders it plans arrive as macOS notifications.
- **Memory sheet** (title menu ▸ Memory…): "Memory" (13 semibold), rows grouped You, Preferences, then each course (dot + name); a row is the memory's text, edited in place; the student's words it came from on hover (“…”); Forget in the context menu and on ⌫; "Done". No add button, no copy; glyph-only (`brain`) when empty.
- **On the iPhone** (M7, §7): a sheet with two heights over the shell (the header's bubble opens it): small 356 pt with the conversation scrolled as the panel (its latest question in sight; Today stays usable above it), large with the whole conversation (Today dimmed); the content surface at both heights; the title row's menu as the panel's (17 pt); the thread rows at 15 pt (bubbles radius 18/18/5/18, photos 72×54); the composer [paperclip 38 pt circle: Photo Library, Take Photo (only with a camera), Choose File… | the 38 pt field, Send inside it]; Paste of a photo, screenshot or PDF in the field. A question goes to the Mac (an `agent_request` row through iCloud sync) and shows as the student's bubble with the skeleton line until the Mac's answer arrives; one that could not be answered reads "Not answered" with the reason under it. Questions queue up: the next may go while one waits. Absent (no bubble) until sync runs.
- **Not built yet** (1.3): the screens' bottom inset under the compact panel, the "p. 2" chip into a sent PDF, Calendar's dashed preview from the panel's text, the panel in Live's window, Undo of a change row from the phone.

### 8.7 Study coach — the study coach mockups v3, screens 11–19 (mc)

Built in `Packages/Coach` (`CoachUI`; the engine in `Coach`; README there; plan-coach §6) and wired by the app (`\.studyCoach`: the `CoachEngine` on the Mac; on iOS (M7) `CoachEngine(services:)` without Claude: Start and the round's choices and labels work, written answers wait for the Mac's grade, nothing plans). Everything the coach decides (the plan, rounds, exams, the budget) is code; Haiku drafts questions and Opus grades written answers in the background, so no screen ever waits on a model. Phases (term, break, exam runway) are never labelled. No settings for any coach choice: credits, away days, caps, which date to sit, seminar hours and skips go through the agent (`plan_query`, `plan_adjust`, `set_course_credits`, `mark_away_days`; PRD "Manage it through the agent").

- **Today** (11, 12): with `study_block` rows for today and one still open, the hero is `PlanHero` of the first open block (else the review / session hero as before). Eyebrow: course dot + name (a round over several courses: dots + short names, "Data Centers · CL"); an item's "· due Mon 19 Oct, 23:59" in tertiary; on an away day `tram` leads (tertiary), nothing else says so. Title 22 pt semibold. Meta: detail · length (SF Mono digits) · the grey why, or for an exam-admission item "· ★ Exam admission" + one source glyph with its trail popover. Start (filled, ▶, ↩) opens what the block opens (`StudyStart`); beside it "Then Lecture 2 · slides 13–21 · 1 h 30 min" ("Then read J&M §4.9 · 15 min"; the last separator tertiary). Subtitle "Tuesday, 20 October 2026 · 5 h 15 min planned" (every block but skipped ones, done included; digits in SF Mono). Coming up adds each course's next lecture (later weekly lectures stay out) and leaves out the hero's item.
- **Study** (13; sidebar `brain` after Notes, Go ⌘5): 680 pt column, zones 28 pt apart; no search field. Subtitle "Week 3 of 17" (`TermWeek`). Zone 1 the same `PlanHero`. Zone 2 "Courses" with column heads "Ready" and "This week": dot, name over "Exam Tue 9 Feb, 10:00" / "Second date Wed 7 Apr, 10:00" once sat / a seminar's next due item ("Survey Mon 26 Oct, 12:00 · 12 places"); Ready "22%" over a 4 pt meter (a seminar: none); "2 h of 6 h 10 min" (studied in primary medium, durations rounded to 5 min; nothing for a seminar without seminar hours); a click opens the course's Progress. Zone 3 "Weakest topics" (≤ 6 seen topics, by mastery then next due): dot, "Data Centers · Paravirtualization", a `TimeChip` "L2 · 37:10" on hover, `MasteryDots` (help "Mastery 1 of 4 · again Tue 20 Oct"); a click opens the lecture at the topic's slide and second; context menu Practice This Topic. Only courses with lectures, questions or due items get a row (a timetable's course with none has none); Ready shows once one of the course's questions was answered, and a column head only while some row has a value. Nothing to study yet (no plan block, no such course): the drop prompt `brain` "Study starts with your lectures' slides and recordings." + Import… (6.6).
- **Progress** (14; a course's row `chart.bar` between Notes and Course Settings): 760 pt column. Hero eyebrow "Exam Tue 9 Feb, 10:00 · Hall A · Second date Wed 7 Apr" (+ the form once announced). Two figures, "22 % ready" and "2 h 10 min of 120 h self-study", each over a meter (Ready counts recall; hours only show pace; pages never count). Practice (filled, ↩) with the aside from `previewRound` ("12 questions · 10 min"); in the runway a plain "Practice exam" opens the sheet, aside the last settings ("8 questions · 90 min"); an exam in progress offers "Resume practice exam". "Topics and reading" by lecture, newest first: head "L2 · Virtualization Basics" + date over a hairline; topics weakest first (dots, title, "Slides 15–16"; `TimeChip` on hover; a click opens the lecture at the second; context menu Practice This Topic, and Read … when a reading is mapped); then the readings (`book`, title + faint source glyphs with the trail popover, "Slides 5–21", length; a click opens it). A lecture with every topic solid and its readings read is a closed group (chevron, count). Ready only once something was taught (never for a seminar); a course whose credits and self-study hours are unknown shows the studied time alone ("self-study"), not the profile's default budget as its own. No questions yet: no Practice and no ↩ (nor Practice exam in the runway). A course without lectures: the drop prompt `chart.bar` "Progress starts with this course's slides and recordings." + Import… (6.6).
- **Practice round** (15): full window (the sidebar hides, its toggle stays; restored on leaving), 680 pt column. Title "Practice", subtitle "Data Centers · 4 / 12", [End]. Zone 1: course dot + "Lecture 2 · Paravirtualization" + the topic's dots; the question (title 2); four choice rows with keys 1–4, or the answer field (⌘↩). Zone 2 once answered: the slide (`SlideImageView`), the verdict (choice: the pick keeps the neutral fill with a grey cross, the right one semibold with the green check, the rest dim; written: Claude's grade as one grey AI block with one sparkle, "Right." semibold; while pending: the model answer in grey), the professor pin + name + `TimeChip` (the lecture at slide and second), the quote in curly quotes under the 3 pt amber bar with the transcript's corrections as ~~old~~ new, the explanation; [Count as wrong] (written) [**Next question** →]. Space plays the sentence. A new or missed question comes back later in the same round.
- **Practice exam sheet** (17): Questions from [All lectures | Weakest topics | each old exam | Add Old Exam…], Length [the announced length | 60 / 90 / 120 min | Untimed] + a faint source glyph (help: where the length comes from); "8 questions · 90 points" (`previewExam`); Cancel (Esc) / **Start** (↩). A dropped PDF becomes an old exam (one Opus call in the task queue).
- **Practice exam** (18): full window with nothing else: no sidebar, sidebar toggle, agent panel, launcher or search field (⌘J and ⌘F stand down) until it is handed in. "Practice exam" over "Data Centers · 2 / 8 · 1:16:05 left" (SF Mono, ticking each second); toolbar [Flag] [Pause]. "Question 2 · 12 points", the question (title 2) in its form: choices (1–4), a short or long field (content surface, radius 10, accent focus ring), a label diagram (drag a term onto a box or click the box and type; drag a token back to the bank to remove it). The glass bar: ‹ 1…8 › (filled = answered, ring = current, small flag) | **Submit** (filled once all are answered, else it asks once: "N questions have no answer"). Pause covers the question; leaving pauses; 0:00 hands it in and opens the results. Drafts save as they are typed.
- **Results** (19): pushed on the course's Progress (the sidebar back with Progress selected, ‹ in the toolbar). "71 of 90 points", "1 h 24 min of 90 min"; Review misses (filled, ↩: a round of the misses) and Retake (new questions, same settings). "Questions" in exam order: number, title, "9 / 12", a miss's `TimeChip` "L2 · 38:28"; a row opens Your answer beside Model answer, then Claude's grade (grey, one sparkle); context menu Change Points… (the student's points win; Claude's stay beside them). An old exam's questions carry the amber quote bar. **No grade estimate anywhere**: points only.
- **Reminders**: the agent's existing ones (exam admission 24 h and 2 h before, registration the day before it closes) as notifications; "Register for exams" items come from the university profile through the change log. No reminder row in the panel.
- **On the iPhone (16, M7):** Today's plan card: the eyebrow 13, title 26 bold, meta 15, Start the whole width under the thumb (50 pt capsule), "Then …" centred under it. The round (a full-screen cover): one question per screen; "Practice" over "6 / 12" in the bar, End (×) leading; the eyebrow names the course ("CL Lecture 1 · ELIZA"); answer rows of at least 52 pt; after a tap the green check, the professor's sentence with its moment and the explanation; Next under the thumb; no slide. Written answers wait for the Mac's grade (the model answer in grey meanwhile). No practice exams on the phone (an exam's session opens its course instead).
- **Not built** (mc): phase banners, a grade calculator, attempt counters, Calendar blocks for the plan, a settings screen for any coach choice, the reminder as a row in the panel's thread; Progress's toolbar [Import + | ⋯] group (Progress has the course screens' history chevrons only; its empty prompt has Import…).

### 8.8 Documents — no mockup (md)

Built in `Packages/Documents` (`DocumentsUI` draws, `Documents` keeps and reads; READMEs there) and wired by the app over one `DocumentBank` (Mac only: documents never sync, the iPhone has no Documents row or screen, `DocumentsUI` compiles there read-only). The screen writes only through `\.documentActions`; rows come from `@FetchAll`. Everything the bank decides (types, size, reading, OCR, chunking, which dates survive) is code; one background Haiku call per document writes its title, kind, summary, related courses, key facts and dates, so no screen waits on a model. Titles, kinds and summaries are changed through the agent, never a form (PRD "Manage it through the agent").

- **Navigation:** the Documents row after Notes (`doc.on.doc`; Go ⌘5), no children, no badge. `\.openDestination(.documents(id, page:))` (a search hit, a `[[doc …]]` chip) selects it with that document; another screen drops the page.
- **Layout** (Notes' pattern, 6.1): the list column (260) | `Divider` | the reader on the content background. Toolbar 6.3.
- **List** (`.inset`, system selection, newest first, no separators, rows 7/6 like Notes): the title 13 semibold (one line) … the added day trailing (SF Mono 11.5, tertiary, "19 Oct"; another year "19 Oct 2025"); then the kind 12 medium primary ("Handbook", "Regulations", "CV", "Transcript", "Certificate", "Letter", "Document"), ONE sparkle and the summary 12 secondary (one line). Pending (being read or summarised): the kind and a skeleton line. Failed: the kind and a secondary `exclamationmark.triangle`, the reason as help. Context menu: Quick Look, Read Again (only after a failure), Delete. ⌫ deletes (no confirmation; Edit ▸ Undo "Delete Document" restores it, the bank reads and summarises again what the delete stopped), Space toggles Quick Look. With nothing selected the newest opens.
- **Reader** (at most 680 wide, centred, 52 from each side, 26 from the top): the title (22 bold, primary, selectable); the facts line 12 secondary, digits SF Mono ("Handbook · PDF · 6 pages · Added Mon 12 Oct"; no pages for an image); the related courses (dot 8 + short name, one line, in the sidebar's order; absent when none). Then the file as one tile (card surface, radius 10, 0.5 separator ring): the first page's thumbnail 64 high (`QLThumbnailGenerator`, radius 6 + hairline), the file name 13 medium (middle-truncated) over "PDF · 20 kB" 12 secondary; a click opens Quick Look (help "Quick Look"). Then the AI blocks, 18 apart, each a section label (subheadline semibold secondary) with ONE sparkle at its first line and grey 13 pt text: **Summary**; **Key facts** (rows, "p. 12" trailing in tertiary SF Mono 11; a click opens Quick Look); **Dates** (the day SF Mono 12 secondary "Mon 1 Feb", a range "18–29 Jan" / "28 Dec–8 Jan", ", 10:15" only when the document states a time, the year only outside the half year behind and the year ahead; then what; then "p. 6"). A block without content is absent. Pending: Summary as a 3-line skeleton, nothing else. Failed: one secondary line, the triangle and the reason, then [Read Again] (bordered, small).
- **The page** a hit or chip named: that page's key facts and dates sit on the quiet fill while the document is the one it opened with. Quick Look opens at the file's start (no jump to a page in md).
- **Quick Look:** `.quickLookPreview` on a temporary link named as the student's file (the panel's title is "Modulhandbuch_Inf_MSc_WS2627.pdf", never the blob's hash), removed when the panel closes.
- **Drop and Import…:** the whole screen is a drop target for `StudyDocument.acceptedTypes` (PDFs too: here a PDF is a document, never slides); the reader shows `EmptyDropPrompt`'s accent ring only while such files hover; a drag with none of them is left to smart import. Mixed drops: documents to the bank, the rest to smart import. Import… (toolbar, File ▸ Import… ⇧⌘I while Documents shows) opens a multiple-file importer on the same types. The first new (or already kept) document is selected; a file the bank refuses shows "Couldn’t finish" with its sentence ("This file is larger than 200 MB.").
- **Empty:** `EmptyDropPrompt` `doc.on.doc` "Drop your documents here." + Import… over the whole detail (6.6); it rings for any file (its own rule), only documents are kept.
- **Agent:** the screen publishes the selected document (`AgentContext(screen: .documents, documentID:)`); the panel's prompt "Ask about this document" / "Ask about your documents"; the thread's context line "Documents" with `doc.on.doc`. Keeping a file the student dropped on the panel is "keep this" (the agent's `keep_document`, "Added to Documents" in its change rows with Undo). No other agent UI.
- **Search** (8.1): a Documents group (header `doc.on.doc` + "Documents"; collapsed it shows its best hit like Notes and Mail), rows with a secondary `doc.on.doc`, "Modulhandbuch M.Sc. Informatik · p. 3" over the highlighted snippet; ↩, a double click and Open go to `.documents(id, page:)`. Never the agent's sources (like mail) and not in a segment.
- **Chips** (8.6): `[[doc 3f2a9c1e p12]]` becomes a chip only when its key names exactly one kept document and the page is one of its pages (else dropped): web's chip shape with `doc.on.doc`, secondary on the quiet fill, "p. 12" or the title clipped to 24; help the title; a click opens Documents at the page. On the iPhone every document marker is dropped.
- **Window drops** (FilingUI): Word, ODT, RTF, Pages, text, Markdown and images dropped anywhere else go to the bank (PDFs and `.ics` stay with smart import), one toast per drop in the filed toasts' shape: the 38 pt tile with `doc.on.doc`, "Added to Documents" over the file names, [↶ Undo] only when the drop added something new (it deletes only those); it leaves after 8 s, not while hovered. A refused drop: the triangle, the names over the bank's sentence, × on hover.
- **Not built** (md): Quick Look at a page, a full PDF viewer in the reader, editing title, kind or summary in the UI, folders, tags, export, sharing, a course's related documents on its screens, Documents on the iPhone.

### 8.9 Lecture notes — lecture-notes-mockups.html 30–35 (ln, nl)

Built in `Packages/StudyPage` (`StudyPageFormat`: the Markdown block parser shared with the agent panel, inline math, `ChartSpec`, the Mermaid subset with its layout, `CodeLexer`, text-quote anchors; `StudyPageUI`: the block views and `LectureNotesView`; docs/modules.md "StudyPage"), `CoursesUI` (`LectureNotesPage`) and `ReviewUI` (the Whole lecture tab), and wired by the app: StudyPass's `NotesWriter` runs in the agent's task queue (one `lecture_notes` task at a time, background slots), `NotesAsker` is `\.lectureNotesAsker` while Claude Code is ready, `\.lectureNotesUnavailable` says why not. Mac only in ln (the tables sync; the iPhone opens the lecture, the iPad its review). docs/plan-lecture-notes.md §1–5 and its "Build plan" are the full spec; the points below are what the screens show.

- **Name** (2026-10-22): the student sees Claude's lecture notes as **Summary** ("Remove from Summary", "Summary: Lecture 3" tasks and change rows, "the summary could not be written", the agent's words); the student's own notes stay **Your notes**. Code, tables and tool names keep `lecture_notes` / `LectureNotes`.
- **Navigation** (decision 1): a row of the course's Lectures (full width) opens `.lectureNotes(id)`: `SidebarItem.lectureNotes(_, course:)` pushed on the course's Lectures (that row selected, ‹ › in the toolbar, Go ▸ Back). Title "Lectures", subtitle the course. A row's menu: Open, Open in Review, Delete…; while its notes are written the row shows a mini ring.
- **The page** (30; nl 34–35): at the window's width (3.3): the text at most 780 pt, code, tables, diagrams and charts breaking out to at most 1120, a slide to at most 640, centred; margins 52 (22 under 640 pt of page); on the content background. Your notes beside it as the window's inspector column (below). Header: the title (title semibold), "Lecture 3 · Mon 19 Oct · 1:29:36 · slides 1–42" (12 secondary, the length SF Mono), [**Open in Review**] (the one filled button, ↩), [Practice] (only with the coach and notes questions: a round of that lecture's questions), ⋯ (Write Again… with its one-line popover, Previous Version, Edit as Note, Copy as Markdown). Then the notes; then **Keep in mind** (the lecture's tracked items with their source glyph).
- **The notes** (`LectureNotesView`, one read-only TextKit 2 document, so a selection spans paragraphs and figures): the overview with the document's one sparkle; one section per topic: heading 15 semibold with one chip (time, else slide) and an amber star only with a verified exam hint; Claude's sentences grey, emphasis, headings, table headers, formulas and code primary (14 pt on 21.7 pt lines, the inspector 13); figures: formulas (SwiftMath), charts (Swift Charts), diagrams (the Mermaid subset in a `Canvas`), code (3.1 Code tokens, Copy on hover), tables, callouts, the slide on white paper with Claude's `box` as a faint rounded box in the AI colour (never the student's ink: nl), the professor's quotes drawn from their rows (amber bar, their words primary, the moment chip); the student's notes and ink are beside the text, in Your notes, never inside it (nl: every fact once; the writer still reads the notes, and an older version's `note` fences draw as nothing); Check yourself with one Answers disclosure. Sections fold by a chevron hung in the margin on hover (kept per lecture).
- **Your notes** (nl, 34–35; `YourNotesColumn`): the page's inspector column (336, 260–440, its own scroll; header "Your notes" and Hide over it). The lecture's own note first (the `Note` with the lecture and no slide, the one Review's Whole lecture edits; empty: 96 pt on the quiet fill, no placeholder, a click puts the caret there), a hairline, then one group per slide with a note or ink in deck order: the chip, the ink thumbnail (white paper in both appearances), each note edited in place (saved 0.5 s after typing stops and on leaving; emptied, it is deleted with Undo); a chip or thumbnail opens Review there. The groups of the section under the reading line (a third down) share one quiet fill, and the column scrolls them a third down unless the pointer is over it, a note in it has focus, or the student scrolled it in the last 2 s. Open by default from 1160 pt of screen, closed under 1120; Show Inspector, Hide and ⌃⌘I toggle it and the choice is kept per window; the expanded agent panel takes its place. While a note in it has focus, ↩ (Open in Review), ⌘K and ⇧⌘E stand down; Esc ends typing.
- **Select and ask** (31): a settled selection floats the glass capsule [highlighter] [Ask] 6 pt above its last line; its context menu starts with Ask…, Highlight / Remove Highlight, then the system's items; ⌘K and ⇧⌘E (6.8). Ask opens the 340 pt popover at the selection: one focused field "Ask about the selection" (then "Ask a follow-up…"), [Explain simpler] [Example] [Why?] that send at once; the question in primary 13 medium, Claude's answer grey with its sparkle (a skeleton line before the first words, "Paused until 17:20" at a limit), then [**Keep**] (⌘↩) and [Continue in Chat] (the passage and exchange go to the agent panel as context). The passage keeps an accent-soft mark while the popover is open. Without Claude Code the capsule and menu offer Highlight only.
- **Kept answers and highlights** (32): a kept answer is a callout on the quiet fill under the paragraph where its passage ends: the question primary, the answer grey with its own sparkle; several on one paragraph stack in the order kept; hovering marks the passage; its menu Remove from Summary (Undo), Continue in Chat, Copy. A highlight is `Color.highlighter` under the words (their colour unchanged). Marks follow a new version by their quoted text; an orphaned kept answer moves to its section's end with its passage quoted, an orphaned highlight hides.
- **States** (33): queued: the outline (headings from the topics) over skeleton lines; writing: one determinate "Writing" line, the text arriving in place (a figure keeps its placeholder until its fence closes; nothing being read moves); paused: "Paused until 17:20" (SF Mono); failed: what came, then one secondary line: the triangle, the reason (cut to one line, in full as help), Write Again… (a version without text is written again at once, no popover; off while a version is open or nothing could be written); nothing to write from yet (no slides with pages, no transcript and synthesis): nothing under the header, never a triangle, the notes queue themselves when the material arrives or on the next open; no Claude Code: the outline with the app's one readable sentence (the student's notes are in Your notes); from the slides: shorter notes, no quotes, replaced once when the recording's pass lands. Review's Whole lecture under a failed version: the same failure line over the study pass's blocks.
- **Review's Whole lecture** (decision 2): with notes text, the same view in the inspector style (13 pt, the slide 296 wide, no breakouts; nl: without the student's notes and ink), then Further reading, then the lecture's own note; no Summary, Exam hints or Only said in class beside it. Without notes text the old blocks, and the first show queues the notes. Follow on: the pane scrolls to the section whose slides hold the slide on screen. Chips move the review (slide, moment) instead of navigating; Ask, Keep and Highlight work as on the page.
- **Not built** (ln): editing Claude's text in place, Write Again for one section, Find in the notes, Search over notes, notes on the iPhone or iPad, a course-wide summary, export and sharing. Not in nl: starting a note on a slide without one from the column (Review's This slide does), reordering notes, Find in the column, the column on the iPhone or iPad, a course-wide notes column, content zoom on iOS.

---

## 9. Copy and voice

**What may be text:** names, titles, facts (dates, times, counts, rooms), labels on controls, and the strings below. Nothing that explains the app.

- **Casing:** menu items and context menus in Title Case ("Slide N Starts Here", "Not on Slides From Here", "Remove Marker", "Cancel Session", "Restore Session", "Mark as Reviewed", "Follow Playback", "Show Inspector", "Retry Processing", "Search Library", "New Lecture Capture…", "Import…", "New Course…", "New Message", "Get Mail", "Mark as Read", "Mark as Unread", "Add to Calendar", "Show Quoted Text"). In-content labels in sentence case, as the mockups draw them ("Start review", "Coming up", "Your notes", "This slide", "Whole lecture", "Recent searches", "Record this course", "Show in Calendar", "Lecturer only", "Whole room", "Sender is", "Subject contains", "Mailing list is", "<platform> course is").
- **Punctuation:** "…" (one character) on anything that opens a choice (Change…, Import…, Set Up Mail…). " · " separates different facts. "," joins a day and its time. "–" (en dash) for ranges. Curly quotes “” around quotes. State strings have no final period.
- **Strings that exist** (add new ones sparingly, as short facts): "Couldn’t finish", "Library unavailable", "Recording is off for this course", "Interrupted 3 times", "Not sent", "Draft cut short", "No Subject", "New Message" (an unsent draft's sender), "No Course" (unrouted mail), "In Calendar" (Mail only), the four progress phases, and the launch-recovery reason "Sending was interrupted; it is not known whether the message went out." (the one sentence: the student decides whether to send again). To add: "Offline", "Sign-in failed" (Mail subtitle). M3.5: "Paused until 17:20" and "Not answered" (the chat's state line; "Paused until 17:20" also as Settings ▸ Accounts' Claude Code value), "Claude Code" (the Settings row) with the values "Not installed", "Not signed in" or the subscription as the CLI names it, capitalised ("Team", "Max", "Pro"), "Reply to Ada Example" (Today's reply row), "Ask about your mail" (the composer's prompt); menu items "Show Chat", "Hide Chat", "New Chat", "No Reply Needed", "Open Message". M4: "Show N more" (plain, under a block's first 3 rows); menu items "Hide", "Add Pin", "Delete Pin", "Revert Correction"; inspector labels "Summary", "Further reading", "Exam hints", "Only said in class"; the said-in-class subheadlines "Admin", "Deadlines", "Questions", "Examples", "Explanations"; Today's hero line "5 highlights, 3 not on the slides" ("1 highlight"; a zero part left out). M5: "Also searched" (Search, before the alternatives), "Web" (segment and group header), "Remove" (help and accessibility action of an alternative's ×); "Tutor" (header, Search's toggle, Review's segment); "Ask about this lecture", "Ask about this course", "Ask about the selection", "Ask about your lectures", "Ask a follow-up…"; "4 selected" (Search's context line); "Copy"; menu items "Memory…", "New Chat" (also in Review's ⋯), "Forget"; the Memory sheet's "Memory", "You", "Preferences", "Done"; help "More". M6: "All Notes" (sidebar), "New Note" (toolbar help, an untitled note's name), "Search notes", "Slide", "Quote" (toolbar titles), help "Paragraph Style", "Checklist", "Image", "Sketch"; the Format menu's "Title", "Heading", "Subheading", "Body", "Checklist", "Bulleted List", "Numbered List", "Bold", "Italic", "Underline", "Strikethrough", "Highlight", "Add Link…"; the note list's "Move To", "Delete"; Review's "Pen", "Highlighter", "Eraser", "Flag", "Stop Drawing". ma (the agent panel; M3.5's "Chat" header, "Tutor" and "4 selected" are gone): menu items and help "Show Chat", "Hide Chat", "Expand Chat", "Shrink Chat", "New Chat", "Memory…", "Attach", "Send", "Stop", "Remove", "Cancel", "Copy"; "Try again" (under "Not answered"); the stored sentences of an answer that did not come "The answer stopped early.", "Stopped after too many steps.", "The answer was cut off.", "Claude is busy." (an answer is never retried by itself; a sub-agent task's "Claude is busy; trying again later."); a refused file "Notes.zip can’t be attached."; the history menu's "Today", "Yesterday" and weekdays; the prompts "Ask about today", "Ask about this week", "Ask about this mail", "Ask about your mail", "Ask about this lecture", "Ask about this course", "Ask about this note", "Ask about the selection", "Ask about your lectures", "Ask a follow-up…"; the task line's "2 tasks running", "1 task running", "1 task waiting", "3 tasks waiting"; file tiles' "3 pages" / "1 page"; the change summaries (written by the agent into `agent_change.summary`) "Added · Mon 19 Oct, 12:00", "Moved to Room 5 · Mon 19 Oct", "Moved to Tue 20 Oct, 12:15", "Cancelled · Thu 5 Nov", "Restored", "Extra session · Fri 6 Nov, 10:15", "Done", "Remembered", "Added to notes", "Reminder · Tue 20 Oct, 23:59"; Calendar's detail popover "Moved to Tue 20 Oct, 12:15" and "Extra session". mc (the study coach): "Study", "Progress" (sidebar); "Start", "Then …", "planned" ("5 h 15 min planned"), "Week 3 of 17", "Courses", "Ready", "This week", "Weakest topics", "Exam Tue 9 Feb, 10:00", "Second date Wed 7 Apr, 10:00", "Exam admission", "· due Mon 19 Oct, 23:59", "Practice", "Practice exam", "Resume practice exam", "Read J&M §4.9 · 15 min", "Topics and reading", "22 % ready", "of 120 h self-study", "Slides 15–16" / "Slide 5", "Questions from", "All lectures", "Weakest topics", "Old exam", "Add Old Exam…", "Length", "Untimed", "Written", "Oral", "Next question", "Count as wrong", "End", "Flag", "Flagged", "Pause", "Resume", "Submit", "1 question has no answer" / "N questions have no answer", "Review misses", "Retake", "Questions", "Your answer", "Model answer", "Right", "Wrong", "Change Points…", "Change", "Points", "N questions", "N points", "71 of 90 points", "1 h 24 min of 90 min", "Question N · M points", "Mastery N of 4 · again Tue 20 Oct", "Sources"; menu items "Practice This Topic", "Read", "Choice 1"–"Choice 4", "Play Sentence", "Submit Answer", "Next Question", "Previous Question", "Unflag"; the profile's deadline "Register for exams" ("<registration system> · 18–29 Jan"). Durations "5 h 15 min", "6 h 10 min", "10 min" (`DurationText`, digits in SF Mono). M7 (iPhone): "Next slide", "Previous", "Flag", "Record", "Stop", "Stop recording?", "Share", "Delete…", "Delete “DC Lecture 2”?", "37 stamps" / "1 stamp", "No Course" (the recorder's menu without a course that may record); Live Activity "Next Slide", "Stop Recording", "Slide 17 of 88", "Slide 17", "S17"; accessibility "Hide Recorder", "Close", "Back", "Recordings", "Course", "Recording time"; tabs "Today", "Courses", "Calendar", "Mail", "Record" / "Recording"; "Practice", "6 / 12"; sync states (only where shown: Settings ▸ Accounts' "iCloud" row) "Up to date", "Syncing", "12,480 to upload", "3 not uploaded", "Not signed in to iCloud", "Another iCloud account", "iCloud is restricted", "iCloud is unavailable", "iCloud status unknown", "Sync doesn’t cover …"; md (Documents): "Documents", "Import…", "Drop your documents here.", "Quick Look", "Read Again", "Delete", "Delete Document" (Edit ▸ Undo), "Added to Documents" (the window's toast and the agent's change row), "Summary", "Key facts", "Dates", "Added Mon 19 Oct", "6 pages" / "1 page", "p. 12", "PDF · 2.4 MB", the kinds "Handbook", "Regulations", "CV", "Transcript", "Certificate", "Letter", "Document", the file types "PDF", "Word", "OpenDocument", "RTF", "Pages", "Markdown", "Text", "PNG", "Ask about this document", "Ask about your documents", and the readable failures (one sentence each, the only full sentences on the screen): "No text found in this file.", "This file could not be read.", "The file is no longer there.", "This file is larger than 200 MB.", "This kind of file can’t be kept in Documents.", "This PDF is locked with a password. Remove the password and add it again.", "This Pages file has no preview to read. Export it as PDF in Pages and add that.", "Word, RTF and Pages files are read on the Mac.", "The summary could not be written.", "This file could not be added."; mr (shared decks): the change summaries "Uses DC L4’s slides 21–40" (a `deck_link` row: the deck named by the earliest other lecture that uses it, else "slides 21–40 of Virtualization & IaaS"; title the lecture, "DC Lecture 5") and "No longer uses DC L4’s slides 21–40" (`deck_unlink`); the Delete Slides… confirmation for a deck several lectures use, "DC Lecture 2 and DC Lecture 3 lose these slides."; a refused Change… of such a deck, "Other lectures of the course use these slides."; "Already uses …" is the agent tool's note, never a row or UI text.

**Formats** (never build date strings by hand)

| Value | Format | Source |
|---|---|---|
| Day | "Mon 12 Oct" (German "Mo. 12 Okt."), no commas, whatever the region | `DayText.day` |
| Full date (toolbar) | "Friday, 16 October 2026" | |
| Clock time | "10:15", **always 24-hour** | `SessionText.time` (module `Courses`) until `DayText.time` exists in StudyUI (7.3); a package that does not depend on Courses promotes `DayText.time` first instead of writing its own |
| Range | "10:15–11:45", "36:57–38:28", "slides 1–37 of 88" (mr: also a lecture's range of a shared deck in Review's meta and Today's hero, "slides 38–88 of 88"; "slides 21–40" / "slide 7" in a change summary, `LectureSlideRange.pagesText`) | `SessionText.timeRange` |
| Day + time | "Mon 19 Oct, 12:15" in lists, deadlines and the sidebar; "Mon 19 Oct at 12:15" in a sentence | |
| All-day deadline | the day alone, "Thu 29 Oct": a time the source does not state is never invented (decisions: "Extracted times") | |
| Mail list time | "13:37" today (mono), "Yesterday", else the day | `MailDateText.listLabel` |
| Mail reader date | "Today, 13:37", "Yesterday, 16:10", "Tue 13 Oct, 16:10" | `MailDateText.readerLabel` |
| Notes list time (M6) | "09:41" today (mono), "Yesterday", the weekday ("Wednesday") within the last week, else the day | |
| Note stamp (M6) | "16 October 2026 at 09:41" | |
| Calendar title / subtitle (M3) | "October 2026", "Oct – Nov 2026" / "Week 43" (ISO 8601) | |
| Calendar day header (M3) | "Mon 19" (weekday + day) | |
| Recording time | "0:37", "37:59", "1:08:13" | `TimeText.clock` |
| Player | "37:27 / 1:08:13" | |
| Slide position | "16 / 88" (review stepper); "Slide 17 of 88" (live) | |
| Slide reference | "S13" chip; "Slide 16" divider | `SlideChip` |
| Lecture | "L2 · Virtualization & IaaS"; "Lecture 2 · Tue 13 Oct"; away from the lecture, chip "L2 · 0:37" | |
| Attachment size | "412 KB", binary units | `MailText.byteCount` (`.byteCount(style: .memory)`) |
| Counts and units | "58 slides", "8 results", "5 unread", "1×", mono "42%" | `FilingText` |

**Names**

- In lists that mix courses, titles name the course ("Data Centers Lecture 4"). Long names (over 16 characters, or 3+ words) fall back to the short name ("CL tutorial") via `SessionText.title`; Calendar events use the short name ("DC Lecture 3").
- Notes: "DC L2 · Virtualization generations", or "DC L2 · Slide 15" when untitled.
- Deck titles come from the title slide's heading, never the file name.
- Search shows the lecturer's surname ("Example").

**Languages:** UI copy is English with British conventions (day before month, 24-hour). Days localise through `DayText`. Course content (slides, transcripts, mail) stays in its own language; a transcript or caption line gets an "EN"/"DE" badge only when it differs from the lecture's language.

---

## 10. Motion, accessibility, dark mode, performance

**Motion**

- System animations, short and functional. Animate state changes (hover fill, toast in/out, Follow), never decoration.
- The recording dot pulses on a 1.6 s ease-in-out cycle and stops under Reduce Motion, where animated scrolls and pulses become jumps.
- No shimmer on skeletons. Slides never cross-fade through a blank frame.

**Accessibility**

- Rows: `.accessibilityElement(children: .combine)` with one full label (Today: "course, title, day, time range").
- Decorative glyphs are hidden (`CourseDot`, the mail avatar). Meaningful ones are labelled ("AI", "You", "Professor", "In Calendar", "Unread", "Flagged", "Close").
- Custom controls expose a real one: `FilterSegments` uses `accessibilityRepresentation` with a `Picker`; the scrubber is adjustable (label "Recording", value the time); Follow has `.isSelected`; the route menu reads "Route" with its value.
- Transcript lines are buttons with a "Play from Here" action; dividers are headers; language tags read the language name; search rows have open and play actions.
- **Colour is never alone.** Course names stay in titles, pins have distinct glyphs, AI is grey plus a sparkle.
- Tab reaches every control in forms.

**Dark mode**

- Check every screen in light and dark.
- Course colours get brighter (`Color(hex:)`), soft tints go to their dark percentages (3.1), the Live inspector is #222225, `.filingGlass` frost is rgb(52,52,58) at 62 %, the review inspector sits slightly lifted (white at 2.5 %), the player gets a lighter fill. Slides stay white.

**Performance budgets**

| Area | Budget |
|---|---|
| Launch | cold launch < 1 s; launch work off the main actor, after the first frame |
| Review | slide switches without hitches (prefetch ±2); < 300 MB with an 88-slide lecture open; at most 56 MB of slide bitmaps; the large slide drawn into a backing store, not a SwiftUI `Image` |
| Playback | one clock at 10 Hz; publish the current segment or slide only when it changes |
| Search | query < 50 ms; indexing a 90-minute transcript < 1 s |
| Filing | HUD prediction about 300 ms from drag-enter |
| Mail | a message opens in < 50 ms; 2,000 messages scroll without hitches; a sync burst never rebuilds the reader |

---

## 11. Verification and process

### 11.1 Build once, render off screen

- No automated test suite at present: changes are verified by building the app and, for UI, by rendering it. One implementation pass; build the affected target once (`-jobs 4`).
- Render the app's real windows off screen to PNG, without launching the app or taking focus: `swift run -j 4 --package-path tools/ParityRender ParityRender --library <a copy of a library> --out <folder>` (options in its `Render.swift`). Point it at a copy, never at your real library.
- Judge a screen on a library with content, then check its empty state.
- Quit helpers (servers, renderers) when you are done.

### 11.2 Checklist for a UI change

1. Read the screen's spec (section 8) and its overrides (1.3).
2. Build with the components in section 7. Promote, don't copy.
3. Render it off screen (11.1) and compare against the spec: layout, sizes, hierarchy, colours, copy.
4. Density check: one filled button or emphasized card at most; at most 3 zones; at most one chip per row; no fact twice; one sparkle per AI block; no explanatory copy; mono times; no later-milestone controls.
5. Check the empty state and dark mode.

**Off-screen limits are not app defects. Don't "fix" them:** no Liquid Glass or vibrancy (glass content overlaps what is behind it); the chat's inspector column (a glass container like every inspector) draws as a tinted rainbow in light and light in dark; sidebar symbols and chevrons missing in light mode; vibrant secondary text drawn as primary; the toolbar search field shows no typed text; the dark sidebar glass draws light. Off-screen windows are inactive (grey window controls, grey switches, an unfilled default button); never restyle controls to compensate.

### 11.3 Do and don't

| Do | Don't |
|---|---|
| Match the fragment, apply only the listed overrides, compare renders | Ship a screen you haven't compared to its mockup |
| Let behaviour show trust (Undo, Confirm, grey text, the switch as gate) | Write copy that explains the system or its state |
| One filled button, one emphasized card | Two prominent buttons, or a card per section |
| A course dot; name the course in titles | Course-name chips |
| One faint source glyph with a hover popover | Source text, quotes or chips on resting rows |
| One sparkle per AI block; AI text `.secondary` | A sparkle per line; purple text |
| Amber pin or bar for the professor | System orange, or orange for anything else |
| SF Mono for every time (date stamps excepted) | Proportional times in lists, the calendar or notes |
| `DayText`, `TimeText`, `SessionText`; always 24-hour | Hand-formatted dates ("Tue, Oct 13"), "1:37 PM" |
| Empty screens: the glyph, one short line naming the next step and one button or drop target ("Drop the slides (PDF) here." + Import…); ghost rows in forms | "No items yet. Add one to get started.", a lone glyph where a next step exists, a second line of explanation |
| Delete… with a confirmation naming what goes (the student's notes, ink, practice) and Edit ▸ Undo | Deleting without saying the student's work goes too; no way to delete what was added by mistake |
| Determinate progress, skeletons, keep the previous frame | Spinners, blank frames, blocking on the model |
| System glass and one snapshot chrome switch | Hand-drawn blur or glass; a fourth glass helper |
| `onGeometryChange` for sizes | `GeometryReader` for simple size observation |
| Menu `Commands` with keys that detach while typing | Plain-key shortcuts that fire in a text field |
| Images and drawings inline in note text, stored as inline attachments | Images stacked as blocks; `NoteBlock.image` from the editor |
| File to the best guess; corrections start from the item | A dialog that asks before filing |
| Leave later-milestone features out | Disabled or empty placeholders for them |
| Verify off screen on a copy of a library with content, then its empty state | Render against your real library; judge a screen only when it is empty |
| Promote a shared piece into StudyUI | Copy a private component into a second package |

---

## Appendix: older docs this file settles

| Older source | What it says | Current rule |
|---|---|---|
| decisions: "Course Settings is two grouped `Form`s" | native `Form`s, native row height | `SettingsGroup`s with 32 pt rows (parity commit 871380e) |
| decisions: "The drop HUD follows the cursor", Filing README, `DropHUD.swift` header | dropping on Change… opens the change sheet | the file is filed and its toast stays with Change… lit; the toast's Change… is a menu of places (6.5) |
| decisions: "Mail rule fields are shown as" | "Sender is", "Subject contains", "Mailing list is"; "<platform> course is" has no field yet | all four exist (the platform course rule kind, `platform_course` since v15, `RuleRows.swift`) |
| decisions: "The toolbar search field shows on", "Supersedes the toolbar search rows above on the Mac" | the field on Today, Calendar, Mail and Search | Today, Mail, Search, Notes (180 pt); not Calendar (6.3) |
| plan-m1 §5, Review README, eval/m1 | a manual-marker tick on the divider | no tick; Remove Marker in the line's menu |
| plan-m1 | low confidence < 0.5 | content words < 0.15 (decisions: "Transcript dots only content words") |
| eval/m1, `FilingText` comments | "Tue, Oct 13" | "Mon 12 Oct" (decisions: 'Supersedes "One day format everywhere"') |
| plan-m1 §3 | Glossary "Suggested" is M4 | the offline Suggested list stays (871380e) |
| plan-m2 §5 | attachments as one chip each | mockup 05's tile, in a flow (as built) |
| plan-m2 §5 | an empty scope shows an empty list | the scope's glyph (6.6) || Search README | Search at most 868 pt wide | no cap is built; none required |
| Mockup legend | AI always has a source chip | one quiet source affordance (5.2) |
| Mockup `.state` busy dot | orange | a determinate ring (orange is the professor's) |
