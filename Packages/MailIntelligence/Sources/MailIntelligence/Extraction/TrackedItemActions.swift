import Deadlines
import Foundation
import StudyCore

/// What Confirm of a session proposal must change on the session (the app applies it through
/// Courses' `CourseSchedule` before `settle(_:confirmed: true)`).
public enum SessionChange: Hashable, Sendable {
    /// Move the session to `room`.
    case room(LectureSession.ID, String)
    /// Cancel the session.
    case cancel(LectureSession.ID)
}

/// The reader's buttons on what mail added: Undo / restore of a source, Add to Calendar for an
/// item whose date the quote did not confirm, and Confirm / Discard of a session proposal.
/// Undo, Restore and Add to Calendar act through the deadline memory (`Deadlines.DeadlineMemory`,
/// the one write path for tracked items); proposals settle through StudyCore's repository. The
/// calendar mirror follows `in_calendar` on its own (`onChange` lets the app sync at once).
public struct TrackedItemActions: Sendable {
    let services: StudyServices
    let now: @Sendable () -> Date
    let memory: DeadlineMemory

    public init(
        services: StudyServices,
        now: @escaping @Sendable () -> Date = { Date() },
        onChange: @escaping @Sendable () async -> Void = {}
    ) {
        self.services = services
        self.now = now
        memory = DeadlineMemory(services: services, now: now, onChange: onChange)
    }

    var repository: TrackedItemRepository { TrackedItemRepository(store: services.records) }

    /// Undo of what one source did: an item it added is dismissed and leaves the calendar (a later
    /// mail repeating it does not bring it back); a change it made is put back.
    @discardableResult
    public func undo(_ sourceID: TrackedItemSource.ID) async throws -> TrackedItem? {
        try await memory.undo(sourceID)
    }

    /// Takes an Undo back.
    @discardableResult
    public func restore(_ sourceID: TrackedItemSource.ID) async throws -> TrackedItem? {
        try await memory.restore(sourceID)
    }

    /// Add to Calendar (an item whose date was not confirmed by its quote, or that was taken out).
    /// Only an open item with a due date can go in; returns nil otherwise.
    @discardableResult
    public func addToCalendar(_ itemID: TrackedItem.ID) async throws -> TrackedItem? {
        try await memory.addToCalendar(itemID)
    }

    /// What Confirm of an open proposal changes; nil when the item is no open proposal or its
    /// session is gone.
    public func sessionChange(for itemID: TrackedItem.ID) async throws -> SessionChange? {
        guard let item = try await services.records.fetch(TrackedItem.self, id: itemID),
              item.status == .open, item.kind.isSessionProposal,
              let sessionID = item.lectureSessionID,
              try await services.records.fetch(LectureSession.self, id: sessionID) != nil
        else { return nil }
        if item.kind == .cancellation { return .cancel(sessionID) }
        guard let room = item.room?.trimmingCharacters(in: .whitespacesAndNewlines), !room.isEmpty else { return nil }
        return .room(sessionID, room)
    }

    /// Settles a proposal: Confirm (after the app applied `sessionChange(for:)`) or Discard.
    @discardableResult
    public func settle(_ itemID: TrackedItem.ID, confirmed: Bool) async throws -> TrackedItem? {
        try await repository.resolveProposal(itemID, confirmed: confirmed)
    }
}
