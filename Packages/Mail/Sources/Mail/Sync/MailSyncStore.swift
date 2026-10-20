import Foundation
import StudyCore

/// A fetched message ready to be written: server state, parsed content, stored blobs.
struct PreparedMessage: Sendable {
    var uid: UInt32
    var flags: Set<String>
    var internalDate: Date?
    var size: Int
    var parsed: ParsedMail
    var raw: BlobRef?
    var html: BlobRef?
}

/// The sync's database writes. Every batch of messages is one transaction together with its
/// mailbox checkpoint; flag and move results are conditional column updates, so a change the
/// student makes while the server answers is never lost.
struct MailSyncStore: Sendable {
    let services: StudyServices
    let now: @Sendable () -> Date

    var records: RecordStore { RecordStore(database: services.database, now: now) }
    var database: any DatabaseWriter { services.database }

    // MARK: - Mailboxes

    /// Writes the server's folders: new ones are added, roles and names updated, checkpoints
    /// kept. A local Archive row waiting to be created takes the server's archive folder's path.
    /// Folders gone from the server stop syncing (their rows stay until the account goes).
    func applyFolders(_ folders: [IMAPFolder], accountID: MailAccount.ID) async throws -> [Mailbox] {
        let roles = MailboxDiscovery.roles(for: folders)
        let store = records
        return try await database.write { db in
            var existing = try Mailbox.where { $0.accountID.eq(accountID) }.fetchAll(db)
            var result: [Mailbox] = []
            let serverPaths = Set(folders.map(\.path))

            // A local archive row (created by Archive before the server had one) adopts the
            // server's archive folder.
            if let archivePath = roles.first(where: { $0.value == .archive })?.key,
               !existing.contains(where: { $0.path == archivePath }),
               let index = existing.firstIndex(where: { $0.role == .archive && !serverPaths.contains($0.path) }) {
                existing[index].path = archivePath
            }

            for folder in folders {
                let role = roles[folder.path]
                var mailbox = existing.first { $0.path == folder.path }
                    ?? Mailbox(accountID: accountID, path: folder.path, delimiter: folder.delimiter)
                mailbox.name = MailboxDiscovery.lastComponent(folder)
                mailbox.delimiter = folder.delimiter
                mailbox.role = role
                mailbox.isSynced = role.map(MailboxDiscovery.syncedRoles.contains) ?? false
                let stamped = store.stamp(mailbox)
                try Mailbox.upsert { stamped }.execute(db)
                result.append(stamped)
            }
            for var mailbox in existing where !serverPaths.contains(mailbox.path) {
                // A local Archive waiting for CREATE keeps its role; anything else stops syncing.
                let waitingForCreate = mailbox.role == .archive && mailbox.uidValidity == nil
                    && !roles.values.contains(.archive)
                guard !waitingForCreate else { result.append(mailbox); continue }
                if mailbox.isSynced || mailbox.role != nil {
                    mailbox.isSynced = false
                    mailbox.role = nil
                    let stamped = store.stamp(mailbox)
                    try Mailbox.upsert { stamped }.execute(db)
                    result.append(stamped)
                } else {
                    result.append(mailbox)
                }
            }
            return result
        }
    }

    /// The account's Archive mailbox, created here (role archive, synced) when it has none; the
    /// next pass creates it on the server.
    func archiveMailbox(accountID: MailAccount.ID) async throws -> Mailbox {
        let store = records
        return try await database.write { db in
            if let archive = try Mailbox.where({ $0.accountID.eq(accountID) && $0.role.eq(MailboxRole?.some(.archive)) }).fetchOne(db) {
                return archive
            }
            let all = try Mailbox.where { $0.accountID.eq(accountID) }.fetchAll(db)
            let delimiter = all.compactMap(\.delimiter).first
            // Servers whose folders live under INBOX ("INBOX.Sent") get "INBOX.Archive".
            var path = "Archive"
            if let delimiter, !delimiter.isEmpty {
                let prefix = "INBOX" + delimiter
                let roleFolders = all.filter { $0.role != nil && $0.role != .inbox }
                if !roleFolders.isEmpty, roleFolders.allSatisfy({ $0.path.uppercased().hasPrefix(prefix.uppercased()) }) {
                    path = prefix + "Archive"
                }
            }
            let archive = store.stamp(Mailbox(accountID: accountID, path: path, name: "Archive", delimiter: delimiter, role: .archive, isSynced: true))
            try Mailbox.upsert { archive }.execute(db)
            return archive
        }
    }

    func mailbox(_ id: Mailbox.ID) async throws -> Mailbox? {
        try await records.fetch(Mailbox.self, id: id)
    }

    // MARK: - Checkpoints

    /// UIDVALIDITY changed: every stored UID of the mailbox is void. UIDs become nil (rows are
    /// re-attached by Message-ID as the window is fetched again) and the checkpoint starts over.
    /// `updated_at` of the messages is left alone on purpose: rows that are not found again
    /// before the pass ends are the leftovers it deletes.
    func resetUIDValidity(_ mailbox: Mailbox, to uidValidity: UInt32) async throws -> Mailbox {
        let store = records
        let mailboxID = mailbox.id
        return try await database.write { db in
            try MailMessage.where { $0.mailboxID.eq(mailboxID) }
                .update { $0.uid = Int64?.none }
                .execute(db)
            guard var row = try Mailbox.find(mailboxID).fetchOne(db) else { return mailbox }
            row.uidValidity = Int64(uidValidity)
            row.lastUID = 0
            row.highestModSeq = nil
            row.uidNext = nil
            row.syncedSince = nil
            let stamped = store.stamp(row)
            try Mailbox.upsert { stamped }.execute(db)
            return stamped
        }
    }

    /// Records the end of a mailbox pass: UIDVALIDITY, UIDNEXT, HIGHESTMODSEQ (when changes up
    /// to it were applied), `synced_since` (when the window is complete), `last_synced_at`.
    func finishMailbox(
        _ mailboxID: Mailbox.ID, selection: IMAPSelection, highestModSeq: UInt64?, syncedSince: CalendarDay?, at date: Date
    ) async throws -> Mailbox? {
        let store = records
        return try await database.write { db in
            guard var row = try Mailbox.find(mailboxID).fetchOne(db) else { return nil }
            row.uidValidity = Int64(selection.uidValidity)
            if let uidNext = selection.uidNext { row.uidNext = Int64(uidNext) }
            if let highestModSeq { row.highestModSeq = Int64(clamping: highestModSeq) }
            if let syncedSince { row.syncedSince = syncedSince }
            row.lastSyncedAt = date
            let stamped = store.stamp(row)
            try Mailbox.upsert { stamped }.execute(db)
            return stamped
        }
    }

    /// The window back to `since` is complete: every message of it the server had at SELECT is
    /// stored, and nothing below UIDNEXT outside it is wanted, so new mail is UID > UIDNEXT − 1.
    func completeWindow(_ mailboxID: Mailbox.ID, since: CalendarDay, uidNext: UInt32?) async throws {
        let store = records
        try await database.write { db in
            guard var row = try Mailbox.find(mailboxID).fetchOne(db) else { return }
            row.syncedSince = since
            if let uidNext, uidNext > 0 { row.lastUID = max(row.lastUID, Int64(uidNext) - 1) }
            let stamped = store.stamp(row)
            try Mailbox.upsert { stamped }.execute(db)
        }
    }

    // MARK: - Reads

    /// Rows without a UID (after a UIDVALIDITY change or a move without COPYUID) and no pending
    /// move, oldest first.
    func detachedRows(_ mailboxID: Mailbox.ID) async throws -> [MailMessage] {
        try await database.read { db in
            try MailMessage
                .where { $0.mailboxID.eq(mailboxID) && $0.uid.is(nil) && $0.moveToMailboxID.is(nil) }
                .order(by: \.receivedAt)
                .fetchAll(db)
        }
    }

    func storedUIDs(_ mailboxID: Mailbox.ID) async throws -> Set<UInt32> {
        try await database.read { db in
            let uids = try MailMessage.where { $0.mailboxID.eq(mailboxID) && $0.uid.isNot(nil) }.select(\.uid).fetchAll(db)
            return Set(uids.compactMap { $0.flatMap { UInt32(exactly: $0) } })
        }
    }

    /// Rows with local flag changes not yet on the server.
    func pendingFlags(_ mailboxID: Mailbox.ID) async throws -> [MailMessage] {
        try await database.read { db in
            try MailMessage.where { $0.mailboxID.eq(mailboxID) && $0.uid.isNot(nil) && $0.flagsChangedAt.isNot(nil) }.fetchAll(db)
        }
    }

    /// Rows waiting to be moved out of this mailbox.
    func pendingMoves(_ mailboxID: Mailbox.ID) async throws -> [MailMessage] {
        try await database.read { db in
            try MailMessage.where { $0.mailboxID.eq(mailboxID) && $0.uid.isNot(nil) && $0.moveToMailboxID.isNot(nil) }.fetchAll(db)
        }
    }

    /// Mailboxes (of the account) that have local changes to push.
    func mailboxesWithPendingChanges(accountID: MailAccount.ID) async throws -> Set<Mailbox.ID> {
        try await database.read { db in
            let ids = try MailMessage
                .where { $0.accountID.eq(accountID) && ($0.flagsChangedAt.isNot(nil) || $0.moveToMailboxID.isNot(nil)) }
                .select(\.mailboxID)
                .fetchAll(db)
            return Set(ids)
        }
    }

    // MARK: - Local changes pushed

    /// The server now has these rows' flags: clears `flags_changed_at`, but only where it still
    /// holds the value that was pushed (a newer local change stays pending).
    func markFlagsPushed(_ rows: [MailMessage]) async throws {
        let stamp = now()
        try await database.write { db in
            for row in rows {
                guard let changedAt = row.flagsChangedAt else { continue }
                try MailMessage
                    .where { $0.id.eq(row.id) && $0.flagsChangedAt.eq(Date?.some(changedAt)) }
                    .update { $0.flagsChangedAt = Date?.none; $0.updatedAt = stamp }
                    .execute(db)
            }
        }
    }

    /// Moves the server refused: the rows stay in the mailbox the server has them in.
    func cancelMoves(_ ids: [MailMessage.ID]) async throws {
        let stamp = now()
        try await database.write { db in
            for id in ids {
                try MailMessage.find(id)
                    .update { $0.moveToMailboxID = Mailbox.ID?.none; $0.updatedAt = stamp }
                    .execute(db)
            }
        }
    }

    /// A move done on the server: the row now lives in `destination` with its new UID (nil when
    /// the server gave none; the destination's next sync finds it by Message-ID).
    func recordMove(_ id: MailMessage.ID, to destination: Mailbox.ID, uid: UInt32?) async throws {
        let stamp = now()
        try await database.write { db in
            try MailMessage.find(id)
                .update {
                    $0.mailboxID = destination
                    $0.uid = uid.map(Int64.init)
                    $0.moveToMailboxID = Mailbox.ID?.none
                    $0.updatedAt = stamp
                }
                .execute(db)
        }
    }

    /// Server-side changes: expunged UIDs are deleted; changed flags are written to rows without
    /// pending local changes (local wins). With `highestModSeq` the QRESYNC checkpoint moves
    /// on in the same transaction.
    func applyServerChanges(
        _ mailboxID: Mailbox.ID, vanished: Set<UInt32>, flags: [UInt32: Set<String>], highestModSeq: UInt64?
    ) async throws {
        let stamp = now()
        let store = records
        try await database.write { db in
            if !vanished.isEmpty {
                let uids = vanished.map(Int64.init)
                for chunk in stride(from: 0, to: uids.count, by: 500).map({ Array(uids[$0..<min($0 + 500, uids.count)]) }) {
                    try MailMessage.where { $0.mailboxID.eq(mailboxID) && $0.uid.in(chunk.map { Int64?.some($0) }) }.delete().execute(db)
                }
            }
            if !flags.isEmpty {
                let rows = try MailMessage.where { $0.mailboxID.eq(mailboxID) && $0.uid.isNot(nil) && $0.flagsChangedAt.is(nil) }.fetchAll(db)
                for row in rows {
                    guard let uid = row.uid.flatMap({ UInt32(exactly: $0) }), let serverFlags = flags[uid] else { continue }
                    let state = FlagState(serverFlags)
                    guard state.seen != row.isSeen || state.flagged != row.isFlagged || state.answered != row.isAnswered
                        || state.keywords != row.keywords else { continue }
                    try MailMessage
                        .where { $0.id.eq(row.id) && $0.flagsChangedAt.is(nil) }
                        .update {
                            $0.isSeen = state.seen
                            $0.isFlagged = state.flagged
                            $0.isAnswered = state.answered
                            $0.keywords = #bind(state.keywords)
                            $0.updatedAt = stamp
                        }
                        .execute(db)
                }
            }
            if let highestModSeq, var mailbox = try Mailbox.find(mailboxID).fetchOne(db) {
                mailbox.highestModSeq = Int64(clamping: highestModSeq)
                let stamped = store.stamp(mailbox)
                try Mailbox.upsert { stamped }.execute(db)
            }
        }
    }

    /// Deletes rows of the mailbox that have no UID, no pending move and were not touched since
    /// `cutoff`: messages a complete pass did not find on the server again.
    @discardableResult
    func deleteLeftovers(_ mailboxID: Mailbox.ID, before cutoff: Date) async throws -> Int {
        try await database.write { db in
            try MailMessage
                .where { $0.mailboxID.eq(mailboxID) && $0.uid.is(nil) && $0.moveToMailboxID.is(nil) && $0.updatedAt.lt(cutoff) }
                .delete()
                .execute(db)
            return db.changesCount
        }
    }

    // MARK: - Batches

    /// Writes a batch of fetched messages and the mailbox checkpoint in one transaction. A
    /// message already stored under its UID is skipped (no duplicates); one stored without a
    /// UID (after a UIDVALIDITY change or a move) with the same Message-ID, received within a
    /// day, is re-attached so its id, route, items and drafts survive. The checkpoint does not
    /// pass `lastUIDLimit` (below a message that could not be fetched, so a later pass still
    /// does). Returns the new rows.
    func commitBatch(
        _ messages: [PreparedMessage],
        mailbox: Mailbox,
        accountID: MailAccount.ID,
        uidValidity: UInt32,
        uidNext: UInt32?,
        syncedSince: CalendarDay?,
        lastUIDLimit: UInt32? = nil,
        batchIndex: Int,
        faults: MailSyncFaults
    ) async throws -> [MailMessage.ID] {
        let store = records
        let mailboxID = mailbox.id
        let path = mailbox.path
        let stamp = now()
        return try await database.write { db in
            var inserted: [MailMessage.ID] = []
            for message in messages {
                let uid = Int64(message.uid)
                let exists = try MailMessage.where { $0.mailboxID.eq(mailboxID) && $0.uid.eq(Int64?.some(uid)) }.fetchCount(db) > 0
                if exists { continue }
                let state = FlagState(message.flags)
                let received = message.internalDate ?? message.parsed.date ?? stamp
                let rfcID = message.parsed.messageID

                if !rfcID.isEmpty {
                    let candidates = try MailMessage
                        .where { $0.mailboxID.eq(mailboxID) && $0.uid.is(nil) && $0.rfcMessageID.eq(rfcID) }
                        .fetchAll(db)
                    if let match = candidates.min(by: { abs($0.receivedAt.timeIntervalSince(received)) < abs($1.receivedAt.timeIntervalSince(received)) }),
                       abs(match.receivedAt.timeIntervalSince(received)) <= 86_400 {
                        let keepLocalFlags = match.flagsChangedAt != nil
                        try MailMessage.find(match.id)
                            .update {
                                $0.uid = Int64?.some(uid)
                                $0.receivedAt = received
                                $0.size = message.size
                                if !keepLocalFlags {
                                    $0.isSeen = state.seen
                                    $0.isFlagged = state.flagged
                                    $0.isAnswered = state.answered
                                    $0.keywords = #bind(state.keywords)
                                }
                                $0.updatedAt = stamp
                            }
                            .execute(db)
                        continue
                    }
                }

                var threadID = message.parsed.threadID
                if message.parsed.references.isEmpty, !message.parsed.inReplyTo.isEmpty {
                    let parentID = message.parsed.inReplyTo
                    if let parent = try MailMessage.where({ $0.rfcMessageID.eq(parentID) }).fetchOne(db), !parent.threadID.isEmpty {
                        threadID = parent.threadID
                    }
                }
                let parsed = message.parsed
                let row = store.stamp(MailMessage(
                    accountID: accountID,
                    mailboxID: mailboxID,
                    uid: uid,
                    rfcMessageID: rfcID,
                    inReplyTo: parsed.inReplyTo,
                    referenceIDs: parsed.references,
                    threadID: threadID,
                    fromName: parsed.from?.name ?? "",
                    fromAddress: parsed.from?.address ?? "",
                    replyTo: parsed.replyTo,
                    to: parsed.to,
                    cc: parsed.cc,
                    subject: parsed.subject,
                    sentAt: parsed.date,
                    receivedAt: received,
                    isSeen: state.seen,
                    isFlagged: state.flagged,
                    isAnswered: state.answered,
                    keywords: state.keywords,
                    size: message.size,
                    snippet: parsed.snippet,
                    bodyText: parsed.bodyText,
                    htmlSHA256: message.html?.sha256 ?? "",
                    htmlPath: message.html?.relativePath ?? "",
                    rawSHA256: message.raw?.sha256 ?? "",
                    rawPath: message.raw?.relativePath ?? "",
                    parseVersion: MIMEParser.version,
                    language: parsed.language,
                    listID: parsed.listID,
                    headers: parsed.headers,
                    createdAt: stamp
                ))
                try MailMessage.upsert { row }.execute(db)
                for attachment in parsed.attachments {
                    let record = store.stamp(MailAttachment(
                        mailMessageID: row.id, part: attachment.part, fileName: attachment.fileName, mimeType: attachment.mimeType,
                        size: attachment.size, contentID: attachment.contentID, isInline: attachment.isInline
                    ))
                    try MailAttachment.upsert { record }.execute(db)
                }
                inserted.append(row.id)
            }

            try faults.beforeCheckpoint?(path, batchIndex)

            guard var checkpoint = try Mailbox.find(mailboxID).fetchOne(db) else { return inserted }
            checkpoint.uidValidity = Int64(uidValidity)
            if let highest = messages.map(\.uid).max() {
                checkpoint.lastUID = max(checkpoint.lastUID, Int64(min(highest, lastUIDLimit ?? highest)))
            }
            if let uidNext { checkpoint.uidNext = Int64(uidNext) }
            if let syncedSince { checkpoint.syncedSince = syncedSince }
            let stamped = store.stamp(checkpoint)
            try Mailbox.upsert { stamped }.execute(db)
            return inserted
        }
    }

    // MARK: - Re-parsing

    /// Rows parsed by an older parser that still have their raw message.
    func outdatedRows(limit: Int) async throws -> [MailMessage] {
        let version = MIMEParser.version
        return try await database.read { db in
            try MailMessage.where { $0.parseVersion.lt(version) && $0.rawSHA256.neq("") }.limit(limit).fetchAll(db)
        }
    }

    /// Writes re-derived body columns (column-only).
    func updateParsed(_ id: MailMessage.ID, parsed: ParsedMail, html: BlobRef?) async throws {
        let stamp = now()
        try await database.write { db in
            try MailMessage.find(id)
                .update {
                    $0.bodyText = parsed.bodyText
                    $0.snippet = parsed.snippet
                    $0.language = parsed.language
                    $0.listID = parsed.listID
                    $0.headers = #bind(parsed.headers)
                    $0.htmlSHA256 = html?.sha256 ?? ""
                    $0.htmlPath = html?.relativePath ?? ""
                    $0.parseVersion = MIMEParser.version
                    $0.updatedAt = stamp
                }
                .execute(db)
        }
    }
}

/// The flags a row stores, from a server flag set.
struct FlagState: Hashable, Sendable {
    var seen: Bool
    var flagged: Bool
    var answered: Bool
    var keywords: [String]

    init(_ flags: Set<String>) {
        seen = IMAPFlag.contains(flags, IMAPFlag.seen)
        flagged = IMAPFlag.contains(flags, IMAPFlag.flagged)
        answered = IMAPFlag.contains(flags, IMAPFlag.answered)
        let managed: Set<String> = [IMAPFlag.seen, IMAPFlag.flagged, IMAPFlag.answered, IMAPFlag.recent].map(IMAPFlag.normalized).reduce(into: []) { $0.insert($1) }
        keywords = flags.filter { !managed.contains(IMAPFlag.normalized($0)) }.sorted()
    }

    /// Stores the rows' \Seen, \Flagged and \Answered on the server (the selected mailbox), as
    /// they are here: local wins.
    static func push(_ rows: [MailMessage], session: any IMAPSession) async throws {
        guard !rows.isEmpty else { return }
        let flags: [(String, KeyPath<MailMessage, Bool>)] = [
            (IMAPFlag.seen, \.isSeen), (IMAPFlag.flagged, \.isFlagged), (IMAPFlag.answered, \.isAnswered),
        ]
        for (flag, keyPath) in flags {
            let add = rows.filter { $0[keyPath: keyPath] }.compactMap { $0.uid.flatMap { UInt32(exactly: $0) } }
            let remove = rows.filter { !$0[keyPath: keyPath] }.compactMap { $0.uid.flatMap { UInt32(exactly: $0) } }
            if !add.isEmpty { try await session.store(add.sorted(), flags: [flag], .add) }
            if !remove.isEmpty { try await session.store(remove.sorted(), flags: [flag], .remove) }
        }
    }
}
