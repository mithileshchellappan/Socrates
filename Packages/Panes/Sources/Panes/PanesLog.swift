#if os(macOS)
import os
import StudyCore

/// The host's logs: layouts read and written, the room decisions, the floating panel.
enum PanesLog {
    static let host = Log.logger(category: "panes")
    static let layout = Log.logger(category: "panes-layout")
    static let floating = Log.logger(category: "panes-floating")
}
#endif
