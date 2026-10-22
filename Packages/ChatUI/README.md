# ChatUI

**ma: the agent panel** (PRD "One agent UI, everywhere"; the agent panel mockup with its approved changes): ONE panel for the whole main window (on the Mac since panes the small floating chat or the window's Agent pane, see "Panes" below; on the iPad compact and movable or expanded as the window's full-height right sidebar), one `app` conversation across screens, the screen's context passed implicitly, files attached, the activity log's change rows with Undo, the sub-agent task line. It replaces the per-screen chat inspectors (Today, Mail, Search, course screens), Review's Tutor tab and Calendar's "New deadline" field. The M3.5/M5 chat (`.chatInspector`, `ChatToolbarItem`, `ChatCommands`, `ChatActions`, `ChatPanel`, `ChatPane`, `.chatCommand`) was deleted when the app was wired (ma integration, 2026-10-18).

Depends on StudyCore, StudyUI and ClaudeKit (only to decode stored turns); never on AppAgent, Agent, Tutor or MailIntelligence: the panel reads its rows itself (`agent_conversation` kind `app`, `agent_turn` + `context`, `agent_task`, `agent_change`) and every effect goes through `AgentPanelActions` (`\.agentPanelActions`), which the app wires to AppAgent. Nothing here can send mail. No automated test suite at present; verified by building and rendering (the renders below).

## Entry points

```swift
extension View {
    // Once, on the main window's split view, on the model the app owns (`@State`): \.openAgentPanel,
    // \.isAgentComposerFocused (also folded into \.isSearchFieldFocused: apply it INSIDE the app's
    // .environment(\.isSearchFieldFocused, …)), Memory…'s sheet, the floating launcher, the focused
    // value AgentPanelCommands reads. Mac: the model holds the window's panes
    // (AgentPanelModel(launch:panes:)); the app presents
    // AgentMiniChat in its floating panel and offers AgentPane as the Agent pane. iOS: the compact
    // overlay and the expanded .inspector, \.agentPanelExpanded. Nothing without
    // AgentPanelActions.isAvailable.
    public func agentPanel(model: AgentPanelModel, context: AgentContext, floatingLauncher: Bool = false) -> some View
    // On the detail column's root: forwards what the screen publishes (.agentContext) to the panel
    // (a split view's columns are hosted apart; their preferences may stop at the column).
    public func agentPanelContextReader() -> some View
}
@MainActor @Observable public final class AgentPanelModel {   // the window's chat (the app's @State, shared by every view below)
    public init(launch: AgentPanelLaunch = AgentPanelLaunch())
    public var isMiniShown: Bool                                // Mac: compact and the Agent pane closed (the floating panel's isPresented)
    public func focusComposer()                                 // the caret into the composer on screen (the Agent pane offer's focus)
}
public struct AgentPane: View { public init(model:) }           // Mac: the Agent pane's content (no header; 720 pt measure while maximized)
public struct AgentPaneAccessory: View { public init(model:) }  // Mac: the Agent pane header's title menu
public struct AgentMiniChat: View { public init(model:) }       // Mac: the floating panel's content (title row, thread, composer)
public struct AgentPanelLauncher: View {                       // the sidebar footer's bubble.left, or the floating 32 pt glass form
    public enum Style { case sidebarFooter, floating }
    public init(style: Style = .sidebarFooter)
}
public struct AgentPanelCommands: Commands { public init() }   // View ▸ Show Chat/Hide Chat ⌘J, Expand Chat/Shrink Chat ⌥⌘J
public struct AgentPanelActions: Sendable {                    // \.agentPanelActions; inert defaults: no panel, launcher or commands
    public var isAvailable: Bool
    public var pausedUntil: Date?
    public var send: @Sendable (_ text: String, _ context: AgentContext, _ attachments: [AgentAttachment], _ conversation: AgentConversation.ID?) async throws -> AgentConversation.ID
    public var stop: @Sendable (AgentConversation.ID) async -> Void
    public var liveReply: @Sendable (AgentConversation.ID) -> AsyncStream<ChatLiveReply?>
    public var cancelTask: @Sendable (AgentTask.ID) async -> Void
    public var undoChange: @Sendable (AgentChange.ID) async throws -> Void
    public var retry: (@Sendable (AgentConversation.ID) async throws -> Void)?  // Try again after a failed answer (nil: no button)
    public var contextLine: (@Sendable (AgentContext) async -> AgentContextLine?)? // the pending bubble's faint line
    // A failed send throws `AgentSendFailure(sentence:)`: its one readable sentence is the notice line.
}
public struct AgentPanelLaunch: Hashable, Sendable {           // renders: mode (closed/compact/expanded), conversationID, newChat,
    …                                                          // exchanges (renders only: which exchanges show; nil = the whole
    …                                                          // conversation, as the app), draft, attachments, pendingText
    …                                                          // (renders: a message just sent, its bubble + skeleton), now
}
public struct AgentPanelSnapshot: View {                       // renders without a window: the compact panel, or the expanded column with its header inline
    public init(style: Style, context: AgentContext, launch: AgentPanelLaunch, windowHeight: CGFloat = 740)
}
extension EnvironmentValues { public var isAgentComposerFocused: Bool }   // screens' plain keys stand down (Review reads it)
public struct ChatMemorySheet: View { public init() }          // Memory… (title menu)
public struct ChatLiveReply, ChatUnavailable                   // unchanged
```

Screens publish through StudyUI (no ChatUI dependency): `.agentContext(_:refine:)`, `\.openAgentPanel` (Calendar's [+]), `\.agentPanelExpanded` (Review and Calendar hide their inspectors). In this workstream: Review publishes `.lecture` (course, lecture, recording when not the first, the slide on screen; the playhead through `refine` at ↩), Calendar `.calendar` (the week's Monday, the selected item or session), Today `.today`.

## What it draws

- **Compact** (the iPad's `CompactAgentPanel`; the Mac's small chat is `AgentMiniChat` in the app's floating panel, see "Panes" below): an overlay at the window's bottom-trailing corner, 12 pt from the edges, 336 wide; the inspector's opaque surface (#f8f8fa / #222225, `PanelSurface`), radius 14, a 0.5 pt ring (black 12 % / white 14 %), the mockup's panel shadow (an inset copy of the shape, 14 / 12 pt in, casts r 20 y 18 at #141e32 38 % / black 70 %: it falls below the panel). Title row 38 pt: the conversation title as a menu (13 semibold, at most 200 pt; "New Chat" 13 medium tertiary for an empty one) with a tertiary chevron, then ⤢ (`arrow.up.left.and.arrow.down.right`, "Expand Chat") and Close (`xmark`, "Hide Chat"), 28 pt borderless secondary. Dragging the title row's free part (grab pointer) moves the panel; the offset from the bottom-trailing corner is kept per window (`@SceneStorage("agent.panel.position")`, "x,y"), clamped inside the window under the toolbar. As tall as its content up to half the window (title row, task line, composer and notice included, measured; at least 80 for the thread), then the thread scrolls with a 40 pt faded top edge, and a 14 pt faded bottom edge while more than its bottom padding is below (the task line sits 6 pt under it). Every size (compact, expanded, both sheet heights) shows the whole conversation (2026-10-20); it opens on the latest question (`scrollTo` a 1 pt anchor at its top with a unit-point anchor of `topClear` ÷ the visible height, so it lands 44 pt down in compact, clear of the whole fade, 8 elsewhere; at the end while an answer is written or a message waits; again while its rows load in the first second, until the student scrolls), follows the end on size changes only while within 24 pt of it and writing, and scrolls to the end on ↩. A New Chat shows only the title row and the composer. The conversation on screen is pinned when the panel appears (a newer one never takes over by itself). One answer is written at a time: one skeleton (then the live text) under the last question, kept across the run's end until its stored turn lands. A drag moves the panel by an offset only (`PanelMove`, read by `PanelPlacement` alone) and stores the place once, when it ends. While it sits in its corner it reserves its height in `\.overlayInsets`, so the filing toasts stack above it.
- **Expanded** (the iPad's `ExpandedAgentPanel`; on the Mac the Agent pane, see "Panes" below, and the room rules in this paragraph are gone): the window's `.inspector` column (applied on the split view: full height), `inspectorColumnWidth(min: 300, ideal: <kept, at most the room>, max: 560)`: the width the student drags is kept in `@AppStorage("agent.panel.width")` (ideal 380; a window resize or a sidebar toggle is never stored), and it opens no wider than the window has beside `room` (`AgentPanelRoom`: the screen's 480 and the app's sidebar while it shows; 300 at least). The column shows only while the window holds its 300 beside them (`AgentPanelLayout.fits`; the window's width is measured outside the inspector, unobserved): `expandedChanged` tells the app, which hides its sidebar where all three do not fit, and the column appears once it has; a window too narrow even without the sidebar keeps the panel compact, and a sidebar shown in a window too narrow for all three turns it compact. The content has no minimum of its own (`minWidth: 0`), so a long answer never widens the column. The system column, lifted by white 2.5 % in dark mode as Review's and Calendar's. Its header is the toolbar's own items over the column only while expanded (the title menu, at most 200 pt; flexible space; ⤡ and Close); nothing measures the column; a hairline under it. The whole conversation, anchored to the bottom.
- **Title menu**: recent `app` conversations (≤ 40, by `created_at`, newest first) in sections "Today", "Yesterday", the weekday within the week ("Tuesday"), then the day ("Tue 13 Oct"); titles only, the open one checked; then New Chat and Memory… (the M5 `ChatMemorySheet`). The panel opens on the most recently active conversation (`updated_at`); New Chat shows an empty one that becomes a conversation with its first message.
- **Thread** (`AgentThreadView`; padding compact 2/14/12, expanded 14/16/14; 12 between entries): the student's words a bubble on Fill 2 (radius 14/14/4/14, at most 250 compact / 264 expanded, 13 pt primary, selectable); the files sent with it as small tiles above the bubble in the student's order (image: 44×28 thumbnail with a hairline edge; PDF: `doc.richtext` + name + "3 pages"; text: `doc.plaintext` + name + "1 KB"; 28 pt, radius 8, content surface, 0.5 ring; 11.5 pt secondary, the detail tertiary). The answer: 13 pt secondary, ONE sparkle, inline Markdown, M5's checked chips (see below). A **faint context line** (11 pt tertiary: the screen's glyph from `AgentTurnContext.glyph` at 10.5 pt + its `label` + a hairline to the trailing edge) goes before an exchange whose label differs from the one before; before the first one only when the conversation moved between screens or was asked elsewhere than the screen on display (Calendar's two exchanges both have one, §3); in the compact panel the first exchange shown has one only when it was asked elsewhere (Review's own exchange has none, §1). **Task results** (succeeded tasks the conversation spawned, by `finished_at`, after the exchange sent before they finished): a faint line `checklist` + the task's title, then the result as an answer (web chips checked against the task's own conversation's tool results). The answer being written streams from `liveReply`; a skeleton line (redacted, no shimmer) until its first words; the student's words show at once as a pending bubble (with its files and, when the screen changed, its context line from `contextLine`), and it gives way in the very update its stored turn is read. One `LiveReplyBox` per conversation lives in the panel's model (`liveBox(for:)`), so ⌥⌘J, reopening or picking shows the text so far in the first frame. A run that ends without storing its text (stopped, failed, cut off) publishes it once as unsaved (`ChatLiveReply.isUnsaved`); the box keeps it (`unsaved`) and the thread draws it under the message it answered (the last message stored before its `afterTurns`), also after later messages are sent and answered. Narration is left out by one rule for stored and live text (`ChatTranscript.answerText`: a tool-use turn's one line under 160 characters, without a marker, when the text after it is longer), so nothing jumps when the final turn lands. A hand-over (↩, Try again) keeps the skeleton until the run is seen starting (`AwaitedRun`); Try again hides the unsaved text it replaces meanwhile and drops it only then (it comes back when the retry could not go). States: "Paused until 17:20" (`TimelineView(.explicit)`: it turns into the failed line at the reset), else `NotAnsweredLine`: the triangle + "Not answered" (12 pt; the sheet's footnote) with the stored sentence in tertiary under it, or the triangle with the sentence alone when part of the answer was written, then "Try again" (`retry`); "Stopped." (`ReadableError.stopped`) has no line. A failed or cancelled task: `FaintLine` `checklist` + its title with a warning triangle (reason on hover; under it on the phone), or struck through.
- **Change rows** (`AgentChangeList`): each run of `[[change 1a2b3c4d]]` markers in an answer is one list (ONE sparkle in a 16 pt column when the list starts the answer, else the rows start at the answer's text edge; text before or after it stays text, but a list item carrying a marker gives way to its rows: `PanelAnswerBlock.split`). The applied time reads as the Notes list: mono "14:08" today, else "Yesterday", the weekday, "Tue 13 Oct" (`HistoryDay.title`). A row: the item as Today and Calendar name it (`agent_change.title`, 13 medium primary, one line) over the grey summary (12 secondary, its clock times in SF Mono: "Added · Mon 19 Oct, 12:00") + the source glyph (11 tertiary: `envelope` mail, `bubble.left` chat, `waveform` transcript, `calendar` timetable or calendar), the applied time trailing (mono 11 tertiary); padding 5/8, hairlines between rows (inset 8, hidden around the hovered row), hover on `QuietFill` radius 8. A rest of 350 ms on a row (tap on iOS) opens StudyUI's `SourceTrailPopover` to the row's leading side: the source (the item source written with the change when there is one, else one built from the change's columns: mail sender and time, lecture, what the student said) with its exact quote, Undo in the footer (`undoChange`). An undone change: title struck through, tertiary, no Undo. A marker that names no change (or two) is left out.
- **Task line** (`AgentTaskLineSection` → `AgentTaskLine`): while a task of the open conversation (`parent_conversation_id`; none for a New Chat, never the app's own background work) is queued, running or paused, one 11.5 pt secondary line above the composer: "2 tasks running" / "1 task running", or "1 task waiting" / "3 tasks waiting" when none runs. A click opens a popover (300 wide) listing them: title (13, two lines), elapsed time while running (mono 11 secondary, ticking), Cancel (small) → `cancelTask`.
- **Composer** (`AgentComposer`): radius 12 on the content surface, 0.5 separator ring, min 36; files waiting as tiles above the field (image: 40 pt thumbnail, radius 10, hairline edge; PDF / text: [glyph | name 12.5 medium over "3 pages" / "1 KB" 11 secondary], 40 high, radius 10 on the raised surface, max 200 wide; × on hover, top-leading 16 pt circle); a placeholder tile while a file is read; then [paperclip (`paperclip`, 28 pt secondary; the open panel limited to images, PDF, text, source code, JSON) | the field (13 pt, 1–8 lines, then it scrolls inside) | Send (`arrow.up.circle` 19 light, accent outline) only with text or a file / Stop (`stop.circle`, secondary) while the agent works, in a 28 pt place kept while neither shows]. The prompt names the context: "Ask about today", "Ask about this week", "Ask about this mail" / "Ask about your mail", "Ask about this lecture", "Ask about this course", "Ask about this note", "Ask about the selection" / "Ask about your lectures"; after a question in this opening of the panel "Ask a follow-up…". ↩ sends (text or files alone; the context as it is at ↩, Review's playhead through `refine`), ⌥↩ and ⇧↩ add a line and carry a list on (`ComposerLines`: "1. " / "1) " numbered on with the items after it renumbered, "- ", "* ", "• " the same bullet, at the line's indentation; an empty item ends the list), Esc clears the text and files, then closes the panel. ⌘V pastes a copied file or a screenshot (PNG; TIFF is converted to PNG) as a tile: a local key monitor while the composer has focus (macOS), text pastes as text. Never blocks: typing works while the agent answers.
- **Drop**: a drop on the panel (compact or expanded) of files the accept rule takes rings the panel in the accent (2 pt) and attaches them (at most 5 per message, the rest left out silently); anything else (a ZIP, Keynote, audio) gets no ring and a forbidden proposal, so the window's import keeps it. Refused files (too large, too many pages, not UTF-8) are dropped without a word and logged.
- **Launcher** (`AgentPanelLauncher`): `.sidebarFooter` is a borderless `bubble.left`, secondary, tinted (accent) while the panel is open; `.floating` is a 32 pt interactive glass circle; help "Show Chat" / "Hide Chat". Both toggle the panel. Absent without the panel.
- **Keys**: ⌘J Show Chat / Hide Chat (a ⌘ key equivalent: works while typing), ⌥⌘J Expand Chat / Shrink Chat, both in View after the sidebar items. The composer's focus is `\.isAgentComposerFocused` and folded into `\.isSearchFieldFocused`, so every screen's plain keys stand down while the student types to the agent.

## M7: the iPhone's sheet and the relay

```swift
public struct AgentSheet: View {                                   // agent panel mockup §7
    public static let smallHeight: CGFloat = 356
    public init(context: AgentContext, launch: AgentSheetLaunch = AgentSheetLaunch())
}
public struct AgentSheetLaunch: Hashable, Sendable {                // renders: detent (.small/.large), conversationID, newChat, exchanges (small), draft, now
    public init(detent: Detent = .small, conversationID: AgentConversation.ID? = nil, newChat: Bool = false, exchanges: Range<Int>? = nil, draft: String = "", now: Date? = nil)
}
extension AgentPanelActions {
    public static func relay(services: StudyServices, isAvailable: Bool, device: String = AgentRequest.iPhone) -> AgentPanelActions
}
```

- **The sheet** (`AgentSheet.swift`): two detents, small 356 pt (the newest exchange, `model.shown` as the compact panel: what was asked since it opened and at least the latest exchange; Today above stays usable, `presentationBackgroundInteraction(.enabled(upThrough:))`) and large (the whole conversation; Today dimmed). The content surface (`Color.contentBackground`) at both heights (`presentationBackground`), the system drag indicator. Title row 44 pt: the conversation's title as the same history menu as the panel (`AgentTitleMenu`, 17 pt semibold, chevron 11): recent conversations by day, New Chat, Memory… (`ChatMemorySheet`). No ⤢ or Close: the detents and the swipe do that.
- **Thread**: `AgentThreadView(style: .sheet)` (the whole conversation at both heights), the panel's rows at the sheet's sizes (`AgentThreadMetrics.sheet` in `\.agentThreadMetrics`: words 15 pt, bubbles radius 18/18/5/18 at most 280 wide, padding 7/13, photos 72×54 radius 12, file tiles 34 pt at 13 pt, the context line 12, 14 between entries, padding 2/18/12). The Mac's panel keeps `AgentThreadMetrics.panel` (its values unchanged). After the stored exchanges the sheet shows the **phone's open questions** (`agent_request` of the conversation, `PanelThread.openRequests`): a request whose message the Mac stored (the same words, sent after it was asked, 5 min of clock skew allowed) is the exchange's; every other one shows as the student's bubble with its files (`RequestFileTile`: a thumbnail from the row's bytes, a PDF's pages, a text file's size) and the skeleton line (pending, running, or answered before its turns synced), or **"Not answered"** (secondary warning triangle) with the reason under it (no hover on the phone; also for a failed stored exchange). The message just sent is the pending bubble until its request row lands (`PendingPanelMessage.sentAt`).
- **Composer** (`SheetComposer`, mockup §7 `.s-comp`): files waiting as the panel's tiles (× always shown on iOS), then [paperclip: a 38 pt circle on `QuietFill`, a menu Photo Library (`photo`, `PhotosPicker`, images only, up to the five-file room), Take Photo (`camera`, `UIImagePickerController` full screen, JPEG 0.85; only where `isSourceTypeAvailable(.camera)`), Choose File… (`folder`, `fileImporter` with the panel's types) | the field: 38 pt, radius 19, a 0.5 pt ring on the content surface, 15 pt, 1–6 lines, the prompt as the panel names it ("Ask about today", then "Ask a follow-up…") | Send `arrow.up.circle.fill` 26 pt accent inside the field, only with words or a file]. **Paste works in the field**: on iOS the field is a `UITextView` (`PastingTextField`) that offers Paste for a photo, a screenshot or a PDF on the pasteboard (metadata only until the student pastes) and turns them into tiles (`AgentItemProviders`); text pastes as text. A message may go while earlier ones wait for the Mac (they queue there); one hand-over at a time. The same accept rule and limits as the Mac (`AgentAttachment`).
- **The relay** (`AgentRelay.swift`): `send` reads the attached files' bytes from the phone's BlobStore into `agent_request_file` rows and writes the request (`AgentRequestRepository.submit`, device `iphone`, the context, the trimmed words) and returns the conversation's id. **New chats: the phone writes the empty `app` conversation row itself** (state `finished`, the title from the first words or the first file's name, ≤ 60, `course_id` from the context; `model` empty) and the request names it; a submit that fails deletes that row again. Why: `AgentRuntime.send` answers a conversation without turns like a new one (it starts a new Claude Code session, `--session-id`, while the conversation has no assistant turn, and the first turn gets the memory, catalog and context blocks as `start` would), so a follow-up asked before the Mac answers goes to the same conversation and the history menu has the new chat at once; with `conversation_id` NULL two questions of one new chat would become two conversations. (The pickup still handles a NULL request: `send(to: nil)` starts one and `finish` names it.) `stop` and `undoChange` do nothing on the phone (the Mac runs and undoes); `cancelTask` cancels the task's row (the Mac's queue follows `agent_task` and stops it); `liveReply` streams nothing.

## Answers and citations (M5, kept)

`ChatCitation.pieces` of the answer text; each marker is checked against rows (`CitationRows`: lectures, their decks' page counts, their recordings) and against the web pages named in the conversation's tool results (`ChatTranscript.webPages`). Shown only when: the key names exactly one lecture; a slide is a page of its deck; a moment lies in the recording; a web URL's host + path occurs in a tool result. Otherwise the marker is removed and logged once per marker and rule (`lecture_unknown`, `lecture_ambiguous`, `slide_no_deck`, `slide_outside_deck`, `moment_unknown_recording`, `moment_outside_recording`, `web_not_in_tool_results`; `change_marker` only in the old chat, which does not draw change rows). Chips are link runs of the answer's one `Text`, drawn by `AnswerChipRenderer`: slide "S13" secondary on the quiet fill, moment "37:59" accent on accent soft, web `globe` + domain. "L2 · " before lecture chips only when the answer cites more than one lecture, or one other than the lecture its exchange was asked about. A slide opens `.lecture(id, ReviewTarget(page:))`, a moment plays from there, a web chip opens the browser. Markdown links are removed. An answer with chips is not selectable. The user turn's `<context …>`, `<catalog …>`, `<task_result …>`, `<memory>` and `<mail …>` blocks are never shown as the student's words (`ChatTranscript.isContextBlock`); a turn of files alone is a message with tiles only.

## Metrics

| | |
|---|---|
| Compact | 336 wide; 12 from the window's trailing and bottom edges; radius 14; title row 38; thread ≤ window/2 − 110 (≥ 80), 40 pt fade; surface #f8f8fa / #222225; ring 0.5 separator; shadow black 22 % r 20 y 12 |
| Expanded | column min 300 / ideal 380 (kept; at most the room) / max 560; header 52 (toolbar items: title ≤ 200, flexible space, ⤡, Close); hairline under it |
| Thread | padding compact 2/14/12, expanded 14/16/14; spacing 12; bubble ≤ 250 / 264; context line 11 tertiary, glyph 10.5 |
| Change row | title 13 medium; summary 12 secondary (times mono 11.5); glyph 11 tertiary; time mono 11 tertiary; padding 5/8; hover QuietFill radius 8 |
| Composer | radius 12; min 36; paperclip 28; Send/Stop 19 light in 28 (the place kept); field 13 pt, 1–8 lines; outer padding compact 0/8/8, expanded 0/12/12 |
| Tiles | composer 40 high, radius 10 (image 40×40); sent 28 high, radius 8 (image 44×28); thumbnails downsampled with ImageIO to 48 pt × scale off the main actor |
| Task line | 11.5 secondary, 6 above the composer; list popover 300 wide |
| Launcher | footer borderless glyph; floating 32 glass circle, 12 from the window's bottom-left |

## Checklist (ma/b; resume from the first open box)

- [x] 1. ChatUI → the panel: `AgentPanel.swift` (modifier, model, compact, expanded, snapshot), `AgentPanelView.swift` (title row, history menu, send), `AgentThread.swift` (thread, exchanges, answers, task results, tile flow), `AgentChangeList.swift`, `AgentAttachments.swift` (tiles, thumbnails, drop, ⌘V), `AgentComposer.swift` (composer, task line), `AgentPanelLauncher.swift` (launcher, commands); old chat deprecated.
- [x] 2. Review: inspector back to "This slide | Whole lecture" (`ReviewInspectorTab` without `.tutor`, no `TutorPane`, no `.chatCommand`, no `isComposingChat`); `.agentContext(.lecture…, refine: playhead)`; the inspector, its header item and Show Inspector yield while `\.agentPanelExpanded`; `ReviewActions.isEditingText` reads `\.isAgentComposerFocused`.
- [x] 3. CalendarUI: the composer, `ComposerModel`, `ConversationObserver` and the dashed preview (`WeekPlan.Preview`, `PreviewPill`, `PreviewMark`) are gone; [+] and Calendar ▸ New Deadline call `\.openAgentPanel()`; `.agentContext(.calendar, week, item/session)`; the Deadlines inspector (and Show Inspector) yield while expanded; the detail popover names `timeChange` "Moved to Tue 20 Oct, 12:15" and `extraSession` "Extra session" like room changes; the footer Undo also takes back a session change applied on its own (`CalendarData.appliedSources`: item sources with a live `agent_change`).
- [x] 4. CoursesUI: `CourseSettingsView` without `showsChat` and its `ChatToolbarItem`; Today publishes `.agentContext(.today)`; `Packages/Courses/Package.swift` no longer depends on ChatUI.
- [x] 5. MailUI: a session change (`isSessionChange`) that is done reads "In Calendar" with Undo while its source stands (`inCalendar(undoable: true)`).
- [x] 6. This README.
- [x] Build: one `taskpolicy -b swift build -j 4` of all five packages (one scratch package depending on ChatUI, ReviewUI, CalendarUI, CoursesUI and MailUI), macOS.
- [x] Off-screen renders (a scratch package hosting `AgentPanelSnapshot` in an off-screen `NSHostingView`, `cacheDisplay`, on a `cp -c` clone of `.data/parity/ma/library`; kept, uncommitted, in the worktree's `.build/ma-b-renders/` with the tool's source in `tool/`): `ma-review-compact` (§1), `ma-review-compact-rest`, `ma-calendar-expanded` (§3, the 7 change rows), `ma-today-files` (§4, sent tiles), `ma-today-files-capped` (half-window cap, faded top), `ma-today-files-composer` (§4, composer tiles), light and dark.

## Requests for the integrator

1. **Wiring (plan §8.2).**
   - `SocratesApp`: `.commands { AgentPanelCommands() }` instead of `ChatCommands()`.
   - `RootView`: on the `NavigationSplitView` (outside its `.toolbar`, INSIDE the app's `.environment(\.isSearchFieldFocused, …)`):
     ```swift
     .agentPanel(context: agentContext, launch: launch.panel, floatingLauncher: columnVisibility == .detailOnly)
     ```
     with `agentContext` from RootView's own state: Today `.today`; Mail `AgentContext(screen: .mail, mailScope: scope.name, mailMessageID: mailSelection)`; Search `AgentContext(screen: .search, query:, selection: <the selected hits' ChatSource>)`; Notes `AgentContext(screen: .notes, courseID:, noteID:)`; a course `AgentContext(screen: .course, courseID: id, courseScreen: "lectures" | "slides" | "notes" | "settings")`; a lecture `AgentContext(screen: .lecture, lectureID: id)` (Review refines it). Also `.agentPanelContextReader()` on the detail column's root (Review's and Calendar's `.agentContext` may not cross the split view's column boundary otherwise; it is harmless when they do).
   - `SidebarView`'s footer: `AgentPanelLauncher()` next to the Settings gear (both footers: [semester … launcher gear] and [+ New Course … semester launcher]).
   - `\.agentPanelActions` on the main window (inert on iOS and without Claude Code):
     ```swift
     AgentPanelActions(
         isAvailable: model.claudeAvailability?.isReady == true,
         pausedUntil: model.claudeAvailability?.status?.pausedUntil,
         send: { text, context, files, id in try await appAgent.send(text, context: context, attachments: files, to: id) },
         stop: { id in await appAgent.stop(id) },
         liveReply: { id in /* map appAgent.liveReplies(id) to ChatLiveReply as before */ },
         cancelTask: { id in await appAgent.cancelTask(id) },
         undoChange: { id in try await appAgent.undo(id) },
         retry: { id in try await appAgent.retry(id) },          // errors as AgentSendFailure
         contextLine: { context in await appAgent.contextLine(for: context).map { AgentContextLine(glyph: $0.glyph, label: $0.label) } }
     )
     ```
   - Remove: every `.chatInspector`, `ChatToolbarItem`, `@SceneStorage("chat.shown")`, `CourseChat`, `showsChat:` (DetailView, RootView, `CourseSettingsView(showsChat:)` no longer exists), `\.chatActions` (then `ChatActions`, `ChatPanel`, `.chatCommand`, `ChatInspector`, `ChatPane`, `ChatCommands` can be deleted from ChatUI), `\.reviewInspectorTab, .tutor` (the case is gone; `ParityMode.Launch.reviewInspectorTab` and `showsChat`).
   - `DeadlineActions.undo` and MailUI's found-row Undo → `AppAgent.undo(sourceID:)` (session changes through the log, else `DeadlineMemory`): Calendar's popover footer and Mail's "In Calendar" row now offer Undo for session changes applied on their own. `DeadlineActions.preview` / `.submit` are no longer used by CalendarUI.
2. **ParityMode** (`ParityMode.Launch`): `panel: AgentPanelLaunch` (closed by default; compact / expanded with `conversationID`, `exchanges` and `now` for the shots) and pass it to `.agentPanel(context:launch:)`. Shots (plan §8.3): `ma-review` (DC L2 slide 12, `AgentPanelLaunch(mode: .compact, conversationID: <Weekend plan>, exchanges: 0..<1)`), `ma-calendar` (Week 43, compact, same conversation, no exchanges: title row + composer), `ma-calendar-expanded` (`mode: .expanded`, Weekend plan: two context lines, the S13 chip, the 7 change rows), `ma-today-files` (Today, compact, `conversationID: <QEMU on the M3>, exchanges: 0..<1`; and/or `newChat: true, attachments: <the turn's PDF and script>` for mockup §4's composer). `--now 2026-10-17T10:40`.
3. **StudyUI promotions** (when you touch it): `Fill2` into StudyUI (`PanelSurface`, the inspector's opaque surface #f8f8fa / #222225, is StudyUI's since panes; CaptureUI keeps a private `Color.inspectorBackground` of the same values).
4. **Calendar's [+] without Claude Code**: `\.openAgentPanel` is a no-op then, so [+] does nothing. If that should hide [+], give `OpenAgentPanelAction` an `isAvailable` (StudyUI) and CalendarUI will read it.
5. **Not wired here**: a screen's bottom inset of the compact panel's height (mockup §1/§4 "the column below it keeps a bottom inset of its height"): only the toasts move up (`\.overlayInsets`). If wanted, publish the compact panel's height in StudyUI and let Review's inspector and Today's list read it.

6. **M7, the iPhone** (plan §7.2): `\.agentPanelActions` on the phone = `.relay(services: services, isAvailable: cloudSync?.isRunning ?? false)` (false today: no Apple Development identity, so sync is off and the sheet stays hidden). The shell (Phone) presents `AgentSheet`; nothing else to wire. `NSCameraUsageDescription` in the iOS Info.plist for Take Photo (Phone README). Renders: `AgentSheetLaunch(detent: .small / .large, conversationID: <F1 on the board>, now:)` through `PhoneShell(agentLaunch:)` with `AgentPanelActions(isAvailable: true)`.
7. **Undo on the phone**: a change row's popover Undo throws there (the change log is the Mac's). If wanted, relay it like the questions (an `agent_change` undo request) later; nothing shows it as unavailable now.

## Design notes for the integrator (DESIGN rows, as built)

- **M7, 1.3 agent panel row "the iPhone sheet"**: built (`AgentSheet`), hidden until sync (no bubble, nothing disabled). Remove "the iPhone sheet" from the row "not built yet".
- **M7, 8.6 (add a bullet "On the iPhone")**: "A sheet with two heights over the shell (the header's bubble opens it): small 356 pt with the newest exchange (Today stays usable above it), large with the whole conversation (Today dimmed); the content surface at both heights; the title row's menu as the panel's (17 pt); the thread rows at 15 pt (bubbles radius 18/18/5/18, photos 72×54); the composer [paperclip 38 pt circle: Photo Library, Take Photo (only with a camera), Choose File… | the 38 pt field, Send inside it]; Paste of a photo, screenshot or PDF in the field. A question goes to the Mac (an `agent_request` row through iCloud sync) and shows as the student's bubble with the skeleton line until the Mac's answer arrives; one that could not be answered reads 'Not answered' with the reason under it. Questions queue up: the next may go while one waits."
- **decisions rows**: "The phone's agent questions are rows (`agent_request`), never model calls on the phone: the Mac answers them one at a time through the panel's own send." / "A new chat on the phone writes its empty `app` conversation row (the Mac's runtime starts a new Claude Code session for a conversation without an assistant turn), so its follow-ups stay in it." / "The phone's files ride in `agent_request_file.data` (blobs do not sync); the Mac files them into its BlobStore when it answers."

- **1.2 Screen status**: "Agent panel (ma) — built in ChatUI: compact + expanded, launcher, commands; Review/Calendar/Today publish their context; the chat inspectors, Review's Tutor tab and Calendar's composer are gone (app wiring §8.2)".
- **1.3 Overrides per mockup (agent-panel-mockups.html)**: the toolbar bubble → ONE launcher in the left sidebar's footer, floating 32 pt glass at the bottom-left while the sidebar is collapsed (approved change); expanded = the window's full-height right sidebar, resizable 300–560 (approved change); compact = a window overlay 12 pt from the window's bottom-trailing corner (not inside a 336 column), movable by its title row, the place kept per window; the title row has ⤢ AND Close (`xmark`, "Hide Chat"); history days: "Today", "Yesterday", the weekday within the week ("Tuesday"), then "Tue 13 Oct" (the mockup writes "Tue 13 Oct" at three days); the prompt names the context and turns to "Ask a follow-up…" only after a question in the same opening (renders of stored conversations show the context prompt, as the mockup); sent file tiles carry "3 pages" / the size after the name; the change row's popover is `SourceTrailPopover` (sender, short quote, time chip, Undo), not the mockup's sender + subject line; undone change rows are struck through in tertiary; the task line is text only, its list a popover. Not built: the screens' bottom inset under the compact panel, the "p. 2" chip into a sent PDF, Calendar's dashed preview from the panel's text, the panel in Live's window, the iPhone sheet (M7).
- **6.2 Sidebar footer**: [semester … `bubble.left` gear] (the launcher before the gear; tinted while the panel is open; help Show Chat / Hide Chat); on a course's screen [+ New Course … semester `bubble.left`]. While the sidebar is collapsed the launcher floats at the window's bottom-left (32 pt glass, 12 from the edges).
- **6.3 Toolbar**: no chat buttons anywhere (Today's and Mail's Show Chat, Search's Tutor toggle and the course screens' Show Chat are gone). Calendar keeps [‹ Today ›] [+]; [+] opens the agent panel (compact, composer focused).
- **6.4 Inspector**: Review ("This slide | Whole lecture"), Calendar (Deadlines). The agent panel expanded is the window's full-height trailing column (header 52 pt level with the toolbar, the title menu + ⤡ + Close; 300–560, width kept); on Review and Calendar it takes their inspector's place (their Show Inspector hides too) until ⤡ / ⌥⌘J; on Today, Mail, Search, Notes and a course the content narrows. Never two inspectors.
- **6.5 Popovers, toasts**: change rows open the source popover on a 350 ms rest; the task line's list is a popover; toasts stay above the compact panel while it sits in its corner (`\.overlayInsets`).
- **6.8 Keys**: View ▸ Show Chat / Hide Chat ⌘J (every screen of the main window, also while typing), Expand Chat / Shrink Chat ⌥⌘J; only with Claude Code. Calendar ▸ New Deadline opens the panel. In the composer: ↩ sends, ⌥↩ new line, ⌘V pastes a file or screenshot, Esc clears and then closes. Review's (and every screen's) plain keys stand down while the composer has focus (`\.isAgentComposerFocused`, folded into `\.isSearchFieldFocused`). The M3.5/M5 rows (Show Chat on Today/Mail/a course/Search, ⌃⌘I toggling the chat, Review's Show Chat opening the Tutor tab) go.
- **8.3 Calendar**: the Deadlines inspector ends with its last row (no composer, no dashed preview in the grid); [+] opens the panel; the detail popover names a time change "Moved to Tue 20 Oct, 12:15" and an extra session "Extra session" like room changes ("Moved to Room 5", "Cancelled"), and its footer Undo also takes back session changes the agent applied on its own.
- **8.6 → "The agent panel"** (replace the section): see "What it draws" above (compact, expanded, title menu, thread, context lines, file tiles, task results, change rows, task line, composer, drop, launcher, keys, states).
- **9 Strings**: "Show Chat", "Hide Chat", "Expand Chat", "Shrink Chat", "New Chat", "Memory…", "Today", "Yesterday" (+ weekday names), "Ask about today", "Ask about this week", "Ask about this mail", "Ask about your mail", "Ask about this lecture", "Ask about this course", "Ask about this note", "Ask about the selection", "Ask about your lectures", "Ask a follow-up…", "2 tasks running", "1 task running", "1 task waiting", "N tasks waiting", "Cancel", "3 pages" / "1 page", "Attach", "Send", "Stop", "Remove", "Paused until 17:20", "Not answered", Calendar's "Moved to Tue 20 Oct, 12:15", "Extra session". The change summaries ("Added · Mon 19 Oct, 12:00", "Moved to Room 5 · Mon 19 Oct", …) are written by AppAgent into `agent_change.summary`; the panel only sets their times in mono.

## md: the document bank (workstream B)

- Prompts on the Documents screen: "Ask about this document" (`AgentContext.documentID` set) / "Ask about your documents".
- `[[doc 3f2a9c1e p12]]` / `[[doc 3f2a9c1e]]` chips (`DocumentCitations.swift`): checked against the `document` rows (`CitationRows.documents`: the key names exactly one document, the page is within its `page_count`; else dropped as `document_unknown`, `document_ambiguous`, `document_page_outside`); web's shape with `doc.on.doc`: "p. 12", without a page the title clipped to 24; help the title (on the run of text holding the chip); opens `.documents(id, page:)`.
- The paperclip also offers Word, ODT, RTF and Pages (`.document` attachments, tile `doc.richtext` + size).
- Requests and design notes: `Packages/Documents/README-UI.md`.

## Panes: the Mac's chat (the side panes milestone)

On the Mac the chat is the small floating chat or the window's Agent pane, never both; the pane
host (the app's `Panes` package) owns the pane, ChatUI only draws what goes in it. iOS keeps the
compact overlay, the expanded `.inspector` and the iPhone's sheet as before.

- **The model is the app's.** `AgentPanelModel(launch:panes:)` is a public handle the app keeps per
  window (made with the window's `PaneHostModel.control` on the Mac) and hands to `.agentPanel(model:context:floatingLauncher:)`, `AgentPane`,
  `AgentPaneAccessory` and `AgentMiniChat`, so the draft, files and conversation survive Expand and
  Shrink and one conversation is never on screen twice. The shown and send contexts are the
  model's (`appContext`, set by `.agentPanel`, with the screen's publication merged over it).
- **Modes.** Mac: closed or compact; whether the Agent pane is open is the model's
  `panes.isOpen(.agent)`. `isMiniShown` is compact with the pane closed: the small chat is
  hidden, never closed, while the pane is open (and while the chat is not offered: the app
  presents it only with `AgentPanelActions.isAvailable`).
  `AgentPanelLaunch(.expanded)` starts compact on the Mac (the render opens the pane through its
  layout).
- **Keys.** ⌘J shows or hides the small chat (also while typing); with the Agent pane open it puts
  the caret in the pane's composer, and pressed again gives the keyboard back to the screen
  (the menu reads Show Chat / Hide Chat accordingly). ⌥⌘J is Expand Chat
  (`panes.open(.agent, true)`; the small chat hides with its draft) and, while the pane is
  open, Shrink Chat (the pane closes, the small chat shows). `\.openAgentPanel(expanded:)` follows
  the same rules. Esc in the pane's composer clears the text and files, then gives the screen the
  keyboard; it never closes the pane. In the small chat Esc works as before.
- **Caret requests.** `focusComposer()` and the release are requests the composer of the chat on
  screen takes once (`composerRequest`), so a hidden small chat never takes the caret from the
  pane, and opening a pane by its toggle never moves focus. Each composer reports its own focus
  (`focusedComposer`, by style), so the one fading out (the pane's, the small chat's) never clears
  the caret the other just took.
- **The small chat** (`AgentMiniChat`): the 38 pt title row whose free part drags the floating
  panel (`\.floatingPanelMover`, grab pointer), the thread, the task line and the composer. It hugs
  its content (the panel caps it at half the window; the thread honours the height offered) until
  the student resizes the panel (`\.floatingPanelFrame.height`; from the resize's first frame),
  then fills it; the toasts' room moves once, when a resize ends. The surface, ring,
  shadow and 336 pt width are the floating panel's. Toasts stay above it while
  `\.floatingPanelFrame?.sitsInCorner`.
- **The Agent pane** (`AgentPane`): no header (the pane host's carries `AgentPaneAccessory`), file
  drops, a 720 pt centred measure while `\.paneIsMaximized`.
- **Memory…** sets `model.showsMemory`; `.agentPanel` presents the sheet (no sheet starts in a pane
  or the floating panel).
- **Removed on the Mac:** the `.inspector` column and its sizing (`PanelColumnSizer`,
  `AgentPanelLayout`, `AgentPanelRoom`, `columnFits`, `measured`, `columnMax`, `windowWidth`,
  `room`, `fitColumn`, `measureColumn`, `expandedChanged`), the compact overlay (`CompactPanelHost`,
  `PanelMove`, `PanelPlacement`, `PanelBounds`, `agent.panel.position`), `agent.panel.width` and the
  toolbar header. Kept: `\.agentPanelExpanded` (iOS), `AgentPanelSnapshot`,
  `agentPanelContextReader()`.
- **Live resize.** Answers' tables and code keep their width while `\.isLiveResizing`.
