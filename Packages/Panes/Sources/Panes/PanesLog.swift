#if os(macOS)
import os
import StudyCore

/// The panes' logs: the room decisions (a pane waiting for the sidebar, opening maximized), the
/// layouts read and written, the floating panel kept inside the window.
enum PanesLog {
    static let host = Log.logger(category: "panes")
    static let layout = Log.logger(category: "panes-layout")
    static let floating = Log.logger(category: "panes-floating")
}
#endif
