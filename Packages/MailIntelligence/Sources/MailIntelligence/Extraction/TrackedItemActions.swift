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
/// Writes go through StudyCore's repositories (each one transaction); the calendar mirror
/// follows `in_calendar` on its own.
public struct TrackedItemActions: Sendable {
    let services: StudyServices
    let now: @Sendable () -> Date

    public init(services: StudyServices, now: @escaping @Sendable () -> Date = { Date() }) {
        self.services = services
        self.now = now
    }

    var repository: TrackedItemRepository { TrackedItemRepository(store: services.records) }

    /// Undo of what one source added: the item is dismissed and leaves the calendar. A later mail
    /// repeating it does not bring it back.
    @discardableResult
    public func undo(_ sourceID: TrackedItemSource.ID) async throws -> TrackedItem? {
        try await repository.undo(sourceID: sourceID, at: now())
    }

    /// Takes an Undo back.
    @discardableResult
    public func restore(_ sourceID: TrackedItemSource.ID) async throws -> TrackedItem? {
        try await repository.restore(sourceID: sourceID)
    }

    /// Add to Calendar (an item whose date was not confirmed by its quote, or that was taken out).
    /// Only an open item with a due date can go in; returns nil otherwise.
    @discardableResult
    public func addToCalendar(_ itemID: TrackedItem.ID) async throws -> TrackedItem? {
        guard let item = try await services.records.fetch(TrackedItem.self, id: itemID),
              item.status == .open, item.dueAt != nil, !item.kind.isSessionProposal
        else { return nil }
        if item.inCalendar { return item }
        return try await repository.setInCalendar(itemID, true)
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
