import Foundation
import StudyCore

/// Sends drafts. Only the Send button calls `send` (the agent has no path here: MailIntelligence
/// does not depend on this package).
///
/// Send is a state machine over `mail_draft.state`: draft/failed → sending (the Message-ID is
/// assigned before SMTP starts) → sent, or → failed with a readable reason. Pressing Send twice
/// sends once. After the server accepted the message, a copy goes to Sent with \Seen and the
/// replied message gets \Answered; if that fails, the sync engine saves the copy later. A draft
/// found `sending` at launch is looked up in Sent and never sent again on its own.
public actor MailSender {
    private let services: StudyServices
    private let connector: any MailConnector
    private let clock: MailClock
    /// Drafts this sender is sending right now (recovery leaves them alone).
    private var inFlight: Set<MailDraft.ID> = []

    public init(services: StudyServices, connector: any MailConnector = SwiftMailConnector(), clock: MailClock = MailClock()) {
        self.services = services
        self.connector = connector
        self.clock = clock
    }

    private var records: RecordStore { RecordStore(database: services.database, now: clock.now) }

    /// Sends the draft over SMTP (587 STARTTLS with the uni account name; 465 TLS only when 587
    /// cannot be reached). Returns quietly when the draft is already sending or sent.
    public func send(_ draftID: MailDraft.ID) async throws {
        let drafts = MailDraftRepository(store: records)
        guard let current = try await records.fetch(MailDraft.self, id: draftID) else { throw MailSendError.draftNotFound }
        switch current.state {
        case .sending, .sent: return
        case .generating: throw MailSendError.notReady
        case .draft, .failed: break
        }
        guard let account = try await records.fetch(MailAccount.self, id: current.accountID) else { throw MailSendError.noAccount }
        let recipients = Self.recipients(of: current)
        guard !recipients.isEmpty else { throw MailSendError.noRecipients }
        if let invalid = recipients.first(where: { !Self.isPlausibleAddress($0) }) { throw MailSendError.invalidAddress(invalid) }
        let password = try services.secrets.secret(for: account.passwordKey)
        guard let password, !password.isEmpty else { throw MailTransportError.noPassword }

        let started = clock.now()
        let senderAddress = account.emailAddress
        guard let draft = try await drafts.transition(draftID, from: [.draft, .failed], to: .sending, { draft in
            if draft.rfcMessageID.isEmpty { draft.rfcMessageID = MessageComposer.newMessageID(for: senderAddress) }
            draft.sendStartedAt = started
            draft.error = nil
        }) else {
            return   // another Send got there first
        }
        inFlight.insert(draftID)
        defer { inFlight.remove(draftID) }

        let bytes = MessageComposer.compose(draft, from: account.sender, date: started, messageID: draft.rfcMessageID)
        let credentials = MailCredentials(username: account.username, password: password)
        do {
            let smtp = try await connector.openSubmission(for: account, credentials: credentials)
            do {
                try await smtp.send(bytes, from: account.emailAddress, to: recipients)
                await smtp.close()
            } catch {
                await smtp.close()
                throw error
            }
        } catch {
            let reason = Self.readable(error)
            Log.mail.error("Send failed: \(String(describing: error), privacy: .private)")
            try await drafts.transition(draftID, from: [.sending], to: .failed) { $0.error = reason }
            throw error
        }

        let sentAt = clock.now()
        guard let sent = try await drafts.transition(draftID, from: [.sending], to: .sent, { draft in
            draft.sentAt = sentAt
            draft.error = nil
        }) else { return }
        Log.mail.info("Message sent")
        await afterSend(sent, account: account, credentials: credentials)
    }

    /// Launch: drafts left `sending` by a crash are looked up in Sent by Message-ID: found →
    /// sent; not found (or not checkable) → failed. Never sent again on their own.
    public func recoverInterruptedSends() async {
        let drafts = MailDraftRepository(store: records)
        guard let interrupted = try? await drafts.drafts(in: [.sending]), !interrupted.isEmpty else { return }
        var sessions: [MailAccount.ID: any IMAPSession] = [:]
        for draft in interrupted where !inFlight.contains(draft.id) {
            let found = await isInSent(draft, sessions: &sessions)
            switch found {
            case true?:
                let stamp = clock.now()
                _ = try? await drafts.transition(draft.id, from: [.sending], to: .sent) { draft in
                    draft.sentAt = draft.sendStartedAt ?? stamp
                    draft.sentCopySavedAt = stamp
                    draft.error = nil
                }
            case false?:
                _ = try? await drafts.transition(draft.id, from: [.sending], to: .failed) { $0.error = "Not sent." }
            case nil:
                _ = try? await drafts.transition(draft.id, from: [.sending], to: .failed) {
                    $0.error = "Sending was interrupted; it is not known whether the message went out."
                }
            }
        }
        for session in sessions.values { await session.logout() }
    }

    // MARK: - Private

    /// True when a copy with the draft's Message-ID is in Sent (local rows first, then the
    /// server); nil when the server could not be asked.
    private func isInSent(_ draft: MailDraft, sessions: inout [MailAccount.ID: any IMAPSession]) async -> Bool? {
        guard !draft.rfcMessageID.isEmpty else { return false }
        let rfcID = draft.rfcMessageID
        let accountID = draft.accountID
        let local = try? await services.database.read { db in
            let sentIDs = try Mailbox.where { $0.accountID.eq(accountID) && $0.role.eq(MailboxRole?.some(.sent)) }.select(\.id).fetchAll(db)
            return try MailMessage.where { $0.mailboxID.in(sentIDs) && $0.rfcMessageID.eq(rfcID) }.fetchCount(db)
        }
        if (local ?? 0) > 0 { return true }
        do {
            guard let account = try await records.fetch(MailAccount.self, id: accountID),
                  let sent = try await MailboxRepository(store: records).mailbox(role: .sent, accountID: accountID) else { return nil }
            let session: any IMAPSession
            if let open = sessions[accountID] {
                session = open
            } else {
                guard let password = try services.secrets.secret(for: account.passwordKey), !password.isEmpty else { return nil }
                session = try await connector.openIMAP(
                    account.imapEndpoint, credentials: MailCredentials(username: account.username, password: password)
                )
                sessions[accountID] = session
            }
            _ = try await session.select(sent.path)
            return !(try await session.search(.messageID(rfcID))).isEmpty
        } catch {
            Log.mail.error("Could not check Sent for an interrupted send: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    /// The Sent copy (with \Seen) and \Answered on the replied message. Failures are left to the
    /// sync engine (`sent_copy_saved_at` stays empty; the flag stays pending).
    private func afterSend(_ draft: MailDraft, account: MailAccount, credentials: MailCredentials) async {
        let stamp = clock.now()
        // The replied message is answered here at once; `onlyAnswered`: it had no other local
        // change waiting, so the server gets just \Answered (a \Seen another client set stays).
        var original: (row: MailMessage, onlyAnswered: Bool)?
        if let originalID = draft.mailMessageID {
            original = try? await services.database.write { db in
                guard let before = try MailMessage.find(originalID).fetchOne(db) else { return nil }
                try MailMessage.where { $0.id.eq(originalID) && !$0.isAnswered }
                    .update { $0.isAnswered = true; $0.flagsChangedAt = Date?.some(stamp); $0.updatedAt = stamp }
                    .execute(db)
                guard let after = try MailMessage.find(originalID).fetchOne(db) else { return nil }
                return (after, before.flagsChangedAt == nil)
            }
        }
        do {
            let session = try await connector.openIMAP(account.imapEndpoint, credentials: credentials)
            do {
                if let sent = try await MailboxRepository(store: records).mailbox(role: .sent, accountID: account.id) {
                    try await SentCopy.save(draft, account: account, sent: sent, session: session, services: services, now: clock.now)
                }
                if case let (row, onlyAnswered)? = original, row.flagsChangedAt != nil, row.moveToMailboxID == nil,
                   let uid = row.uid.flatMap({ UInt32(exactly: $0) }),
                   let mailbox = try await records.fetch(Mailbox.self, id: row.mailboxID) {
                    _ = try await session.select(mailbox.path)
                    if onlyAnswered {
                        try await session.store([uid], flags: [IMAPFlag.answered], .add)
                    } else {
                        try await FlagState.push([row], session: session)
                    }
                    try await MailSyncStore(services: services, now: clock.now).markFlagsPushed([row])
                }
                await session.logout()
            } catch {
                await session.logout()
                throw error
            }
        } catch {
            Log.mail.error("Saving the Sent copy failed; the next sync retries: \(String(describing: error), privacy: .private)")
        }
    }

    static func recipients(of draft: MailDraft) -> [String] {
        var seen: Set<String> = []
        return (draft.to + draft.cc + draft.bcc)
            .map { $0.address.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func isPlausibleAddress(_ address: String) -> Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasSuffix(".") else { return false }
        return !address.contains { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "," || $0 == "\"" }
    }

    static func readable(_ error: any Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return "The message could not be sent."
    }
}

/// Why Send did not start.
public enum MailSendError: Error, Hashable, Sendable, LocalizedError {
    case draftNotFound
    /// The agent is still writing.
    case notReady
    case noRecipients
    case noAccount
    case invalidAddress(String)

    public var errorDescription: String? {
        switch self {
        case .draftNotFound: "The draft is no longer there."
        case .notReady: "The reply is still being written."
        case .noRecipients: "Add a recipient."
        case .noAccount: "Set up the mail account first."
        case .invalidAddress(let address): "“\(address)” is not a valid address."
        }
    }
}
