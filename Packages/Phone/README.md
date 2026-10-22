# Phone

The iPhone's shell (M7; mockups 09 and 16, agent panel mockup §7, DESIGN 6.7, 8.5). Depends on StudyCore, StudyUI, ChatUI (the agent sheet) and Recorder's `RecorderContract` (the Record slot shows the recorder's phase; the contract only, no recorder). The app passes the screens in: Today is CoursesUI's `TodayView` (its phone layout at a compact width), Courses, Calendar and Mail the existing iOS screens; Record presents Recorder's `RecorderScreen`. Compiles on macOS (a plain tab view with Record over it); the look is iOS. No automated test suite at present; verified by building and by the integrator's simulator shots.

## Entry points

```swift
public enum PhoneTab: String, Hashable, Sendable, CaseIterable {   // landed; + title, systemImage
    case today, courses, calendar, mail
    public var title: String          // "Today", "Courses", "Calendar", "Mail" (also the large title)
    public var systemImage: String    // sun.max, books.vertical, calendar, tray
}
public struct PhoneShell<Today, Courses, Calendar, Mail>: View {
    public init(selection: Binding<PhoneTab>,
                recordingPhase: RecorderSnapshot.Phase?,     // the recorder's snapshot phase; nil: nothing records
                record: @escaping () -> Void,
                search: (() -> Void)? = nil,                 // the header's search button (nil: none)
                agentLaunch: AgentSheetLaunch? = nil,        // renders: the sheet open from the start
                @ViewBuilder today:, courses:, calendar:, mail:)
}
```

## What it draws

- **Tab bar**: iOS 26's floating system tab bar, Today `sun.max`, Courses `books.vertical`, Calendar `calendar`, Mail `tray`. **Record** is the bar's separate circular slot beside it (iOS 26 draws a `.search`-role tab there, glass): a red `circle.fill` (the record dot, mockup `i-record`) labelled "Record", a red `waveform` labelled "Recording" while a recording runs (recording or stopping), `pause.fill` in the secondary colour labelled "Paused" while it is paused. It renders the recorder's snapshot phase and works out nothing itself. Choosing it never selects it (the selection binding swallows it) and calls `record`, which opens the recorder (a new recording or the one running). The red glyph is a `UIImage` with `.alwaysOriginal` rendering (a tab bar draws template glyphs otherwise).
- **Each tab** is its own `NavigationStack` with the tab's large title (`.toolbarTitleDisplayMode(.large)`; a screen's own `.navigationTitle` or `.largeTitle` toolbar item wins: Today's date line over "Today"). The header's trailing toolbar group: Search (`magnifyingglass`, when `search` is given) and the agent bubble (`bubble.left`, "Show Chat"; tinted while the sheet is open), only while `\.agentPanelActions.isAvailable`. On iOS 26 they are the bar's glass buttons.
- **The agent sheet** (`AgentSheet`, ChatUI) is presented over the whole shell (the small detent covers the tab bar, mockup §7) with the context of the tab on screen: what its screen publishes (`.agentContext`; Today: `.today`) merged over the tab's own (`.today`, `.other` for Courses, `.calendar`, `.mail`). Without `isAvailable` there is no bubble and no sheet, nothing disabled.

## Checklist (M7 B; resume from the first open box)

- [x] 1. `PhoneShell`: tab bar, the Record slot, a stack per tab with the large title, search and the bubble, the sheet; macOS compiles.
- [x] 2. Today at compact width (CoursesUI `Today*.swift`, CoachUI `PlanHero` / `HeroCard` / `PhoneHeroButton`).
- [x] 3. Phone rounds (Coach `CoachEngine(services:)`, CoachUI `PracticeView` at compact width; no practice exams on the phone).
- [x] 4. `AgentSheet` + `AgentPanelActions.relay` (ChatUI).
- [x] 5. AppAgent's pickup of the phone's questions (`AgentRequestPickup`).
- [x] 6. READMEs (this one; ChatUI, Coach, AppAgent additions).

## Requests for the integrator

1. **The iPhone's root** (plan §7.2), on the phone idiom only (`UIDevice.current.userInterfaceIdiom == .phone`; the iPad keeps the split view):
   ```swift
   PhoneShell(selection: $phoneTab, recordingPhase: recorder.snapshot?.phase, record: { showsRecorder = true },
              search: { /* present Search; nil hides the button */ }) {
       TodayView(record: { showsRecorder = true })      // the phone layout at compact width
   } courses: { /* the existing iOS course list */ }
     calendar: { /* CalendarUI's screen */ }
     mail: { /* MailUI's screen */ }
   .fullScreenCover(isPresented: $showsRecorder) { RecorderScreen(recorder: recorder) }
   .environment(\.agentPanelActions, .relay(services: services, isAvailable: cloudSync?.isRunning ?? false))
   ```
   Do not wrap the tabs' screens in another `NavigationStack` (the shell gives each one). `\.openDestination` on the phone: `.today` / `.calendar` / `.mail(…)` select their tab (and dismiss a round's cover), `.practice(id)` presents the round full screen (Coach README), `.lecture(…)` pushes Review in the current tab's stack (or is left out until the phone has Review).
2. **Info.plist (iOS)**: `NSCameraUsageDescription` (the sheet's Take Photo opens the camera; without the key iOS ends the app when the camera opens). Photo Library uses `PhotosPicker` (no permission). Paste needs none.
3. **Parity route `sheet`** (plan §7.2): `PhoneShell(…, agentLaunch: AgentSheetLaunch(detent: .small, conversationID: <"F1 on the board" c3c20d6f-7ef6-4c0c-9647-361af6fa3784>, exchanges: 0..<1, now: Fri 23 Oct 2026 12:47))` (mockup §7 small: the photo question) and `AgentSheetLaunch(detent: .large, conversationID: <the same>, now: Fri 23 Oct 2026 12:49)`, with `\.agentPanelActions` = `AgentPanelActions(isAvailable: true)` (renders only: the real phone uses `.relay`). Route `today`: the shell with `TodayView(now: Fri 23 Oct 2026 12:47)` (mockup 16 left; `\.studyCoach` = `CoachEngine(services:)` so Start shows).
4. **Check in the simulator shot**: that the Record slot's glyph is red (if the tab bar still templates it, it shows in the label colour; tell B) and that the search-role slot does not morph the bar when tapped (the selection never becomes it).

## Design notes for the integrator (DESIGN rows, as built)

- **1.2**: "iPhone recorder, Live Activity, iPhone Today (09)": Phone's `PhoneShell` built (tab bar, Record slot, stacks, header bubble, the sheet); Today at compact width built (CoursesUI). "iPhone travel day (16)": the plan card and the round at compact width built (CoachUI).
- **1.3, row 09 / 16 (new)**: the header's search and bubble are the navigation bar's trailing glass buttons (the bar row above the large title), not 38 pt fill circles beside the title (native components; the large title collapses to the inline title when scrolled). The Record button is the tab bar's separate circular (search-role) slot: glass, a red dot; while recording a red waveform; while paused a secondary `pause.fill` ("Paused").
- **1.3, agent panel row "the iPhone sheet"**: built (ChatUI `AgentSheet`), presented from the shell's bubble; hidden (no bubble, nothing disabled) until iCloud sync runs (`AgentPanelActions.relay(isAvailable:)`).
- **6.7**: add "The iPhone's root is `PhoneShell` (Phone): the floating tab bar Today, Courses, Calendar, Mail with Record as its separate circular slot; each tab a navigation stack with a large title and the header's search and agent bubble. Touch targets at least 44 pt (the bar's buttons, Coming up rows ≥ 44, answer rows 52, Start 50)."
- **8.5 Today**: replace with "Today (phone, 16 with 8.1 and section 4): the date line 'Friday 23 October · 25 min planned' (13 semibold secondary, capitals, the digits in SF Mono) over the large title 'Today' (the bar's large title item; 'Today' inline when scrolled); the hero card (radius 22, padding 16/16/14): eyebrow 13, title 26 bold, meta 15, the one filled button the whole width under the thumb (50 pt capsule, 17 semibold), 'Then read J&M §4.9 · 15 min' centred under it (13); 'Coming up' (17 semibold) over one card (radius 20) of rows [4 pt bar or 10 pt ring | title 15 semibold over the 13 pt gloss (the amber star for exam admission), the source glyph after the last line | the day (15) over the time (SF Mono 12.5)], hairlines from 36 pt; the mail line at 15 pt. A tap opens a row's source popover (a reply row opens the mail); a long press its menu."
- **decisions rows**: "The iPhone's shell: Record is the tab bar's separate circular slot (iOS 26's search-role tab, never selected), not an overlay: the system bar keeps its own width and glass." / "The phone's header buttons are toolbar items, the large title the bar's own (Today's date line through the `.largeTitle` toolbar placement)."
