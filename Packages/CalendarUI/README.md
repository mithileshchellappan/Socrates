# CalendarUI

Calendar & deadlines (PRD #36, #37; mockup 06; docs/DESIGN.md §8.3): the week grid, the inspector "Deadlines" with proposal cards and the "New deadline" composer, the Calendar menu and the sidebar's calendar checkboxes. Workstream C of M3. Depends on StudyCore, StudyUI and Courses (`Courses`, `CalendarSync`). Reads rows itself; every effect goes through StudyUI's `DeadlineActions` (`\.deadlineActions`), navigation through `\.openDestination`, other calendars through `\.foreignCalendars`.

No automated test suite at present; verified by building and rendering.

## Public surface

```swift
public struct CalendarScreen: View { public init(week: CalendarDay? = nil, now: Date? = nil) }   // title, toolbar items, inspector
public struct CalendarCommands: Commands { public init() }                                       // the Calendar menu
public struct CalendarSidebarSection: View { public init() }                                     // Sections for the sidebar List
@MainActor @Observable public final class CalendarVisibility { public init(defaults: UserDefaults = .standard) }
extension EnvironmentValues {
    public var calendarVisibility: CalendarVisibility?                // nil: Socrates shown, no other calendar
    public var foreignCalendars: (any ForeignCalendarSource)?          // nil: no other calendars
}
// CalendarSync (package Courses)
public protocol ForeignCalendarSource: Sendable {
    func foreignCalendars() async -> ForeignCalendarList                // own account title + other calendars
    func foreignEvents(calendarIDs: [String], from: Date, to: Date) async -> [ForeignEvent]
}
extension CalendarMirror: ForeignCalendarSource                        // read-only over its CalendarStore
public struct ForeignCalendar, ForeignEvent, ForeignCalendarList        // id/title/sourceTitle/colorHex; title/start/end/all-day
CalendarInfo.colorHex                                                   // new, default "#8e8e93"; EventKitCalendarStore fills it
// StudyUI
public struct ProposalCard<Source: View>: View                          // DESIGN §5.3
```

## Behaviour

- **Data**: one `FetchKeyRequest` per week (`CalendarRequest`): courses, sessions overlapping the week (+ the lecture filed for each), open due items and events due in the week, open session proposals from today, open due items from today (inspector), the sessions those are tied to, and their source trails (`TrackedItemRepository.trails(itemIDs:in:)`). The "Socrates" EventKit calendar is never read back. A week switch keeps drawing the loaded week until the next one's rows land (no empty frame).
- **Toolbar**: `.screenTitle("October 2026", subtitle: "Week 43")` ("Oct – Nov 2026" across months, "Dec 2026 – Jan 2027" across years; ISO 8601 week), [‹ Today ›] as one group, [+] (focuses the composer, showing the inspector first when hidden), Show Inspector only while it is hidden (⌃⌘I toggles it through the system `InspectorCommands`). No search field.
- **Grid** (`WeekPlan`, pure): gutter 44, header 40, all-day row 28 (it grows when a day has several pills), 56 pt per hour over the whole day, opened at 08:00 (`ScrollPosition`), Sat/Sun 36 wide on `QuietFill`, mono hour labels, 0.5 pt lines, the now line in today's column, today's date in the accent. Sessions show "DC Lecture 3" / "DC Exercise" (short name), the mono range and the room; cancelled ones struck through; an open room change or cancellation as a dashed tag inside ("Room 5?", "Cancelled?"). Overlapping blocks share the column in lanes. Due items (deadline, exercise, exam) and events: all-day or due at 23:59 → pill; a timed event that is no session (an exam review) → a one-hour block labelled with its start; else a 2 pt line, a dot on the column's edge and a tag (the title, one line). Events tied to a session are that session (not drawn twice); announcements are not drawn. The composer's parse draws dashed (line + hollow dot + tag above, or a dashed pill), only in its own week. Selection: a click on a session, event block, tag or pill selects it (filled in its course colour; a tag's inspector row on `QuietFill`) and opens its detail popover (`CalendarDetail`, DESIGN §8.3; Esc closes); double-click or ↩ opens the session's lecture, else its course; context menu Cancel Session / Restore Session (an event block: Add to Calendar, Delete); hovering an item with sources opens `SourceTrailPopover` (the item's detail as its header, the green check when in the calendar, Undo), which a click turns into the detail (`gridPopover`, one popover per item). Other calendars' events draw like sessions in the calendar's colour, without hit testing.
- **Inspector**: header "Deadlines" (13 semibold, level with the toolbar; a toolbar item the column's width in the window, as Review). `ProposalCard`s first ("Move to Room 5?" / "DC Lecture 4, Tue 20 Oct only"; the first card's Confirm is the screen's one filled button); then due items from today, soonest first: course dot, title (+ the amber "Exam admission" chip for `relevance == .examAdmission`), the `SourceTrailButton`, and one line "Mon 19 Oct, 23:59 · SN seminar" (the clock in SF Mono). Undo shows while the row is hovered or selected, for the newest active source that added it on its own (`calendar_added`) or changed it (`previous`). Context menu: Mark as Done, Add to Calendar (when not in the calendar), Delete. Clicking a row selects it and moves the grid to its week.
- **Composer**: pinned under a hairline; the local parse (`preview`) after 150 ms of rest; ↩ or the send glyph → `submit`: `.added` and `.agent(id)` clear the field, `.agent` keeps the dashed parse while that `agent_conversation` is `running` (`@FetchOne`), `.notUnderstood` and errors keep the text. Esc clears.
- **Keys** (`CalendarCommands`, DESIGN §6.8 pattern): Go to Today ⌘T, Previous / Next Week ⌘← / ⌘→, Confirm ⌘↩ / Discard ⌘⌫ (the selected proposal, or the selected session's, else the first), New Deadline (no key). Every key detaches while the composer or the window's search field has focus. No collision with the M2 `menus.txt`.
- **Other calendars**: `CalendarSidebarSection` lists one section per account (as Calendar.app), the app's own calendar's account first ("iCloud"; "Calendars" without access) with "Socrates" (unchecked hides the library's sessions, items and proposal tags in the grid; the inspector stays) and that account's other calendars (checkbox tinted with the calendar's colour); then the other accounts. `CalendarVisibility` keeps the choice in `UserDefaults` (per device). `CalendarMirror`'s source filters out its own calendar (the remembered one, or one titled like it), only reads (`access`, `calendars`, `sources`, `defaultSourceID`, `events`), never asks for access, and returns nothing without full access.
- **Snapshots**: the internal `\.calendarChrome = .snapshot` lays the toolbar and the inspector out inline (layout only; Calendar has no glass of its own).

## Requests for the integrator

Handled in the M3 integration: 1–5 (the window search field is gone on Calendar; the sidebar section is re-created on `EKEventStoreChanged` and after access was asked for; `Color.contentBackground` is StudyUI's; `06-calendar` is in snapshot mode as `calendar?week=2026-10-19`). Not needed: 6. Fixed at integration in `CalendarScreen`: the grid's frame has `minWidth: 0` (its measured width had become the window's minimum, a growing loop), and the body opens at 08:00 once the scroll view has its real height, without a legacy scroller. The list as written:

1. **Detail**: `.calendar` → `CalendarScreen()` (it sets its own `.screenTitle`, toolbar items and `.inspector`), with `\.deadlineActions` wired (plan §6.4), `\.studyServices`, SQLiteData's default database, `\.isSearchFieldFocused`, `\.foreignCalendars` = the app's `CalendarMirror` on the Mac (nil on iOS until M7), `\.calendarVisibility` = one `CalendarVisibility()` kept by the app (the same instance for the sidebar). Drop the window's search field on Calendar (DESIGN §6.3).
2. **Sidebar**: `CalendarSidebarSection()` inside the sidebar `List` after the Courses section while `.calendar` is selected, with the same `\.foreignCalendars` and `\.calendarVisibility` in its environment. It loads the calendars on appear; re-creating it on `EKEventStoreChanged` (or when access is granted) refreshes the list.
3. **Commands**: `.commands { CalendarCommands() }`; re-check `menus.txt` (⌘T, ⌘←/⌘→, ⌘↩, ⌘⌫).
4. **StudyUI**: promote `Color.calendarContent` (CalendarUI, internal: `textBackgroundColor` / `systemBackground`) to the one `Color.contentBackground` of DESIGN §7.3 and use it here. `SourceTrail.swift` line 336 has the Sendable warning this package fixed for its own popover (annotate the Undo closure `@MainActor @Sendable`).
5. **App snapshot / parity**: add `06-calendar` (a sample library's week 43) to the snapshot run.
6. Opening Calendar at a given week from elsewhere: `CalendarScreen(week:)` keeps its own state afterwards; give it `.id(week)` when a route should move it.

No schema request: CalendarUI only reads; every write goes through `DeadlineActions`.
