import SwiftUI

/// What the Calendar screen in the key window can do right now, published as a focused scene
/// value for `CalendarCommands` (docs/DESIGN.md §6.8 command pattern). Everything is off while
/// text is typed (the composer, the window's search field).
struct CalendarActions {
    var isEditingText: Bool
    var hasProposal: Bool
    var goToToday: () -> Void
    var previousWeek: () -> Void
    var nextWeek: () -> Void
    var confirm: () -> Void
    var discard: () -> Void
    var newDeadline: () -> Void

    var keys: Bool { !isEditingText }
    var weekEnabled: Bool { !isEditingText }
    var proposalEnabled: Bool { hasProposal && !isEditingText }
}

extension FocusedValues {
    /// The Calendar screen in the key window, if any.
    @Entry var calendarScreen: CalendarActions?
}

/// The Calendar menu: Go to Today (⌘T), Previous Week (⌘←), Next Week (⌘→), Confirm (⌘↩) and
/// Discard (⌘⌫) of the selected or first proposal, New Deadline (no key: focuses the composer).
/// Keys attach only while Calendar is focused and nothing is being typed, so ⌘← and ⌘⌫ keep
/// working in text fields.
///
///     WindowGroup { … }.commands { CalendarCommands() }
public struct CalendarCommands: Commands {
    @FocusedValue(\.calendarScreen) private var calendar

    public init() {}

    public var body: some Commands {
        let keys = calendar?.keys ?? false
        CommandMenu("Calendar") {
            Button("Go to Today") { calendar?.goToToday() }
                .keyboardShortcut(keys ? KeyboardShortcut("t", modifiers: [.command]) : nil)
                .disabled(calendar?.weekEnabled != true)
            Button("Previous Week") { calendar?.previousWeek() }
                .keyboardShortcut(keys ? KeyboardShortcut(.leftArrow, modifiers: [.command]) : nil)
                .disabled(calendar?.weekEnabled != true)
            Button("Next Week") { calendar?.nextWeek() }
                .keyboardShortcut(keys ? KeyboardShortcut(.rightArrow, modifiers: [.command]) : nil)
                .disabled(calendar?.weekEnabled != true)
            Divider()
            Button("Confirm") { calendar?.confirm() }
                .keyboardShortcut(keys ? KeyboardShortcut(.return, modifiers: [.command]) : nil)
                .disabled(calendar?.proposalEnabled != true)
            Button("Discard") { calendar?.discard() }
                .keyboardShortcut(keys ? KeyboardShortcut(.delete, modifiers: [.command]) : nil)
                .disabled(calendar?.proposalEnabled != true)
            Divider()
            Button("New Deadline") { calendar?.newDeadline() }
                .disabled(calendar == nil)
        }
    }
}
