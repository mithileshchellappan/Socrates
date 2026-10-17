import Foundation
import StudyCore
import StudyUI
import SwiftUI

/// What the Mail screen asks the app to do. The screen reads rows itself (`@FetchAll`) and writes
/// nothing with an outside effect: the app wires these to the sync engine and sender (`Mail`),
/// mail intelligence (`MailIntelligence`) and session edits (`Courses`). Frozen in M2
/// (docs/plan-m2.md §2.5); add members only with a default.
///
/// Defaults do nothing (previews, snapshots, iOS before the library syncs).
public struct MailActions: Sendable {
    /// Fetch new mail now (Get Mail).
    public var syncNow: @Sendable () async -> Void
    /// Read / unread, stored here at once and on the server by the next sync.
    public var setSeen: @Sendable ([MailMessage.ID], Bool) async throws -> Void
    public var setFlagged: @Sendable (MailMessage.ID, Bool) async throws -> Void
    /// Moves a message to the Archive mailbox.
    public var archive: @Sendable (MailMessage.ID) async throws -> Void
    /// The student's correction of where a message belongs; the router learns a rule from it.
    public var route: @Sendable (MailMessage.ID, MailRoute) async throws -> Void
    /// Starts the agent drafting a reply: returns the draft at once (state `generating`), its
    /// text streams into the row.
    public var draftReply: @Sendable (MailMessage.ID) async throws -> MailDraft.ID
    /// Stops the agent writing into a draft (the student discarded it or wants to write alone).
    public var stopDrafting: @Sendable (MailDraft.ID) async -> Void
    /// Sends a draft. Only the Send button calls this.
    public var send: @Sendable (MailDraft.ID) async throws -> Void
    /// Undo of what one source added (the item leaves the list and the calendar).
    public var undo: @Sendable (TrackedItemSource.ID) async throws -> Void
    /// Takes an Undo back.
    public var restore: @Sendable (TrackedItemSource.ID) async throws -> Void
    /// Add to Calendar for an item that did not go in on its own.
    public var addToCalendar: @Sendable (TrackedItem.ID) async throws -> Void
    /// Confirm of a room change or cancellation: applied to the lecture session, then settled.
    public var confirmProposal: @Sendable (TrackedItem.ID) async throws -> Void
    public var discardProposal: @Sendable (TrackedItem.ID) async throws -> Void
    /// A local file for an attachment (decoded on first use), to open, Quick Look or drag.
    public var openAttachment: @Sendable (MailAttachment.ID) async throws -> URL
    /// Messages matching `query` in `scope`, best first (the toolbar search field on Mail).
    public var search: @Sendable (String, MailScope) async throws -> [MailMessage.ID]
    /// Logs in to IMAP and SMTP with `account` and `password` without sending anything (account
    /// settings). Throws a readable error; the password is never stored by this call.
    public var verifyAccount: @Sendable (MailAccount, String) async throws -> Void

    public init(
        syncNow: @escaping @Sendable () async -> Void = {},
        setSeen: @escaping @Sendable ([MailMessage.ID], Bool) async throws -> Void = { _, _ in },
        setFlagged: @escaping @Sendable (MailMessage.ID, Bool) async throws -> Void = { _, _ in },
        archive: @escaping @Sendable (MailMessage.ID) async throws -> Void = { _ in },
        route: @escaping @Sendable (MailMessage.ID, MailRoute) async throws -> Void = { _, _ in },
        draftReply: @escaping @Sendable (MailMessage.ID) async throws -> MailDraft.ID = { _ in throw MailActionUnavailable() },
        stopDrafting: @escaping @Sendable (MailDraft.ID) async -> Void = { _ in },
        send: @escaping @Sendable (MailDraft.ID) async throws -> Void = { _ in throw MailActionUnavailable() },
        undo: @escaping @Sendable (TrackedItemSource.ID) async throws -> Void = { _ in },
        restore: @escaping @Sendable (TrackedItemSource.ID) async throws -> Void = { _ in },
        addToCalendar: @escaping @Sendable (TrackedItem.ID) async throws -> Void = { _ in },
        confirmProposal: @escaping @Sendable (TrackedItem.ID) async throws -> Void = { _ in },
        discardProposal: @escaping @Sendable (TrackedItem.ID) async throws -> Void = { _ in },
        openAttachment: @escaping @Sendable (MailAttachment.ID) async throws -> URL = { _ in throw MailActionUnavailable() },
        search: @escaping @Sendable (String, MailScope) async throws -> [MailMessage.ID] = { _, _ in [] },
        verifyAccount: @escaping @Sendable (MailAccount, String) async throws -> Void = { _, _ in throw MailActionUnavailable() }
    ) {
        self.syncNow = syncNow
        self.setSeen = setSeen
        self.setFlagged = setFlagged
        self.archive = archive
        self.route = route
        self.draftReply = draftReply
        self.stopDrafting = stopDrafting
        self.send = send
        self.undo = undo
        self.restore = restore
        self.addToCalendar = addToCalendar
        self.confirmProposal = confirmProposal
        self.discardProposal = discardProposal
        self.openAttachment = openAttachment
        self.search = search
        self.verifyAccount = verifyAccount
    }
}

/// An action the app has not wired (previews, a device without the sync engine).
public struct MailActionUnavailable: Error, Hashable, Sendable {
    public init() {}
}

extension EnvironmentValues {
    /// The Mail screen's actions; the app installs the real ones.
    @Entry public var mailActions = MailActions()
}
