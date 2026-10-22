import Foundation
import Observation

/// What the Calendar screen shares with its Deadlines pane (the Mac's side pane is drawn in
/// another hosting view and reads the screen only through this object): the week's rows, the
/// minute, the selection and what the pane's rows ask the screen to do. The selection lives here
/// alone; the grid reads it too.
@MainActor
@Observable
final class CalendarPaneState {
    var data = CalendarData()
    var now: Date
    var selection: CalendarSelection?
    /// Set with the rows and the minute they were made for (their `trail` reads those rows); nil
    /// until the screen's first update.
    var handlers: InspectorHandlers?

    init(now: Date, selection: CalendarSelection?) {
        self.now = now
        self.selection = selection
    }

    /// The screen's rows or minute changed.
    func update(data: CalendarData, now: Date, handlers: InspectorHandlers) {
        self.data = data
        self.now = now
        self.handlers = handlers
    }
}
