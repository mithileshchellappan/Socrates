import StudyCore
import SwiftUI
import os

/// A Lecture menu command the notes publish while they have focus (docs/DESIGN.md 6.8's pattern):
/// Ask… (⌘K) and Highlight / Remove Highlight (⇧⌘E). The app's Lecture menu binds them with
/// `@FocusedValue(\.lectureNotesAsk)` and `@FocusedValue(\.lectureNotesHighlight)`; they are
/// absent (nil) when the notes do not have focus, so the keys are free elsewhere.
public struct LectureNotesCommand: Sendable {
    /// The item's title ("Ask…", "Highlight", "Remove Highlight").
    public let title: String
    /// False without a selection (or, for Ask, without Claude Code).
    public let isEnabled: Bool
    private let action: @MainActor @Sendable () -> Void

    public init(title: String, isEnabled: Bool, action: @escaping @MainActor @Sendable () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }

    @MainActor
    public func callAsFunction() {
        action()
    }

    /// The keys the Lecture menu shows: Ask… ⌘K, Highlight ⇧⌘E.
    public static let askShortcut = KeyboardShortcut("k", modifiers: .command)
    public static let highlightShortcut = KeyboardShortcut("e", modifiers: [.command, .shift])
}

extension FocusedValues {
    /// Ask… (⌘K) on the selected passage of a lecture's notes.
    @Entry public var lectureNotesAsk: LectureNotesCommand?
    /// Highlight / Remove Highlight (⇧⌘E) on the selected passage of a lecture's notes.
    @Entry public var lectureNotesHighlight: LectureNotesCommand?
}

/// Retry on a lecture's Summary (its recording's line): the lecture's failed transcriptions
/// queued again and the study pass's failed units run again with a fresh budget, in a task the
/// app owns. The app installs it as `\.lectureNotesRetry` (Mac); nil in renders.
public struct LectureNotesRetryAction: Sendable {
    private let action: @MainActor @Sendable (Lecture.ID) -> Void

    public init(_ action: @escaping @MainActor @Sendable (Lecture.ID) -> Void) {
        self.action = action
    }

    @MainActor
    public func callAsFunction(_ lectureID: Lecture.ID) {
        action(lectureID)
    }
}

/// Write Again on a lecture's Summary (the page's ⋯, the failure line, Review's Summary): the
/// app's one action (`NotesWriteAgain`: Retry of a blocked recording, then
/// `LectureNotesRepository.writeAgain`), run in a task the app owns; `done` gets what it did on
/// the main actor (the screen registers its Undo). The app installs it as
/// `\.lectureNotesWriteAgain`; nil in renders.
public struct LectureNotesWriteAgainAction: Sendable {
    public typealias Done = @MainActor @Sendable (WriteAgainOutcome) -> Void
    private let action: @MainActor @Sendable (Lecture.ID, NotesInstruction, @escaping Done) -> Void

    public init(_ action: @escaping @MainActor @Sendable (Lecture.ID, NotesInstruction, @escaping Done) -> Void) {
        self.action = action
    }

    @MainActor
    public func callAsFunction(_ lectureID: Lecture.ID, _ instruction: NotesInstruction, done: @escaping Done) {
        action(lectureID, instruction, done)
    }
}

extension EnvironmentValues {
    /// Retry of a lecture's recording on its way into the Summary (`LectureNotesRetryAction`).
    @Entry public var lectureNotesRetry: LectureNotesRetryAction?

    /// Write Again of a lecture's Summary (`LectureNotesWriteAgainAction`).
    @Entry public var lectureNotesWriteAgain: LectureNotesWriteAgainAction?

    /// Claude Code is not available on this Mac: the app's readable sentence ("Claude Code is not
    /// installed."), which a lecture whose notes are not written yet shows as its one line under
    /// the outline. Nil: available, or unknown (renders).
    @Entry public var lectureNotesUnavailable: String?

    /// The notes page and Review's Summary tab queue a lecture's first notes when they open
    /// (`LectureNotesRepository.queueIfNeeded`). Off in renders (parity, snapshots): opening a
    /// screen there never writes.
    @Entry public var lectureNotesQueuesOnOpen = true
}

enum StudyPageLog {
    static let logger = Log.logger(category: "lecture-notes")
}
