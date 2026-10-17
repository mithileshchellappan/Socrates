import Foundation
import StudyCore
import SwiftUI

/// What Today and Calendar ask the app to do with deadlines, proposals, sessions and the "New
/// deadline" composer (docs/plan-m3.md §2.3). The screens read rows themselves (`@FetchAll`,
/// `FetchKeyRequest`) and change nothing with an outside effect on their own: the app wires these
/// to the deadline memory and the agent (package `Agent`), session edits (`Courses`) and the
/// calendar mirror. Frozen in M3; add members only with a default.
///
/// Defaults do nothing (previews, snapshots, a device without the agent): `preview` finds
/// nothing, `submit` reports `.notUnderstood`.
public struct DeadlineActions: Sendable {
    /// Undo of what one source did on its own: an item it added leaves the list and the calendar;
    /// a change it made (`previous`) is put back.
    public var undo: @Sendable (TrackedItemSource.ID) async throws -> Void
    /// Takes an Undo back.
    public var restore: @Sendable (TrackedItemSource.ID) async throws -> Void
    /// Mark as Done: the item leaves the lists and the calendar.
    public var complete: @Sendable (TrackedItem.ID) async throws -> Void
    /// Delete Deadline: dismissed, out of the lists and the calendar (extraction will not bring it back).
    public var remove: @Sendable (TrackedItem.ID) async throws -> Void
    /// Add to Calendar for a dated item that did not go in on its own.
    public var addToCalendar: @Sendable (TrackedItem.ID) async throws -> Void
    /// Confirm of a room change or cancellation: applied to the session, then settled.
    public var confirmProposal: @Sendable (TrackedItem.ID) async throws -> Void
    public var discardProposal: @Sendable (TrackedItem.ID) async throws -> Void
    /// Cancel Session / Restore Session (a session's context menu).
    public var cancelSession: @Sendable (LectureSession.ID) async throws -> Void
    public var restoreSession: @Sendable (LectureSession.ID) async throws -> Void
    /// The composer's local parse of the typed text at `now` (no network, fast; nil when it names
    /// no date). The screen calls it as the text changes and draws the result dashed.
    public var preview: @Sendable (String, Date) async -> DeadlineDraft?
    /// ↩ or the send glyph in the composer.
    public var submit: @Sendable (String, Date) async throws -> DeadlineSubmission

    public init(
        undo: @escaping @Sendable (TrackedItemSource.ID) async throws -> Void = { _ in },
        restore: @escaping @Sendable (TrackedItemSource.ID) async throws -> Void = { _ in },
        complete: @escaping @Sendable (TrackedItem.ID) async throws -> Void = { _ in },
        remove: @escaping @Sendable (TrackedItem.ID) async throws -> Void = { _ in },
        addToCalendar: @escaping @Sendable (TrackedItem.ID) async throws -> Void = { _ in },
        confirmProposal: @escaping @Sendable (TrackedItem.ID) async throws -> Void = { _ in },
        discardProposal: @escaping @Sendable (TrackedItem.ID) async throws -> Void = { _ in },
        cancelSession: @escaping @Sendable (LectureSession.ID) async throws -> Void = { _ in },
        restoreSession: @escaping @Sendable (LectureSession.ID) async throws -> Void = { _ in },
        preview: @escaping @Sendable (String, Date) async -> DeadlineDraft? = { _, _ in nil },
        submit: @escaping @Sendable (String, Date) async throws -> DeadlineSubmission = { _, _ in .notUnderstood }
    ) {
        self.undo = undo
        self.restore = restore
        self.complete = complete
        self.remove = remove
        self.addToCalendar = addToCalendar
        self.confirmProposal = confirmProposal
        self.discardProposal = discardProposal
        self.cancelSession = cancelSession
        self.restoreSession = restoreSession
        self.preview = preview
        self.submit = submit
    }
}

extension EnvironmentValues {
    /// Today's and Calendar's actions; the app installs the real ones.
    @Entry public var deadlineActions = DeadlineActions()
}
