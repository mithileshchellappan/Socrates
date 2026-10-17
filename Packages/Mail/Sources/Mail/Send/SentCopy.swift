import Foundation
import StudyCore

/// The copy of a sent message in the Sent mailbox: appended with \Seen unless it is there
/// already (looked up by Message-ID), then recorded on the draft (`sent_copy_saved_at`) and as a
/// Sent row, so the Sent scope shows it before the next sync.
enum SentCopy {
    static func save(
        _ draft: MailDraft, account: MailAccount, sent: Mailbox, session: any IMAPSession, services: StudyServices,
        now: @escaping @Sendable () -> Date
    ) async throws {
        guard !draft.rfcMessageID.isEmpty else { return }
        let selection = try await session.select(sent.path)
        let date = draft.sendStartedAt ?? draft.sentAt ?? now()
        var uid: UInt32?
        let existing = try await session.search(.messageID(draft.rfcMessageID))
        let bytes = MessageComposer.compose(draft, from: account.sender, date: date, messageID: draft.rfcMessageID)
        if let found = existing.last {
            uid = found
        } else {
            let result = try await session.append(bytes, to: sent.path, flags: [IMAPFlag.seen], date: date)
            if let result, result.uidValidity == selection.uidValidity { uid = result.mapping[0] }
        }
        try await record(draft, bytes: bytes, uid: uid, uidValidity: selection.uidValidity, account: account, sent: sent, services: services, now: now)
    }

    /// Stamps the draft and stores the Sent row (unless the sync already has one).
    static func record(
        _ draft: MailDraft, bytes: Data, uid: UInt32?, uidValidity: UInt32, account: MailAccount, sent: Mailbox,
        services: StudyServices, now: @escaping @Sendable () -> Date
    ) async throws {
        let parsed = (try? MIMEParser.parse(bytes)) ?? MIMEParser.assemble(HeaderBlock(), collector: BodyCollector())
        let raw = try services.blobs.put(bytes, fileExtension: "eml")
        let store = RecordStore(database: services.database, now: now)
        let stamp = now()
        let rowUID = (sent.uidValidity == nil || sent.uidValidity == Int64(uidValidity)) ? uid.map(Int64.init) : nil
        let draftID = draft.id
        let rfcID = draft.rfcMessageID
        let sentID = sent.id
        let received = draft.sendStartedAt ?? draft.sentAt ?? stamp
        try await services.database.write { db in
            try MailDraft
                .where { $0.id.eq(draftID) && $0.state.eq(MailDraftState.sent) }
                .update { $0.sentCopySavedAt = Date?.some(stamp); $0.updatedAt = stamp }
                .execute(db)
            let stored = try MailMessage.where { $0.mailboxID.eq(sentID) && $0.rfcMessageID.eq(rfcID) }.fetchCount(db)
            guard stored == 0 else { return }
            if let rowUID, try MailMessage.where({ $0.mailboxID.eq(sentID) && $0.uid.eq(Int64?.some(rowUID)) }).fetchCount(db) > 0 {
                return
            }
            let row = store.stamp(MailMessage(
                accountID: account.id, mailboxID: sentID, uid: rowUID, rfcMessageID: rfcID, inReplyTo: parsed.inReplyTo,
                referenceIDs: parsed.references, threadID: draft.referenceIDs.first ?? (draft.inReplyTo.isEmpty ? rfcID : draft.inReplyTo),
                fromName: account.displayName, fromAddress: account.emailAddress, to: draft.to, cc: draft.cc,
                subject: draft.subject, sentAt: received, receivedAt: received, isSeen: true, size: bytes.count,
                snippet: parsed.snippet, bodyText: parsed.bodyText, rawSHA256: raw.sha256, rawPath: raw.relativePath,
                parseVersion: MIMEParser.version, language: parsed.language,
                createdAt: stamp
            ))
            try MailMessage.upsert { row }.execute(db)
        }
    }
}
