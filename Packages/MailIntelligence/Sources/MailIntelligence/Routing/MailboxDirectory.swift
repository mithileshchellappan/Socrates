import Foundation
import GRDB
import StudyCore

/// Accounts, mailbox roles and the student's own addresses: what tells the student's own mail
/// (Sent, or From one of their addresses) from everyone else's.
struct MailboxDirectory: Sendable {
    var accounts: [MailAccount.ID: MailAccount]
    var roles: [Mailbox.ID: MailboxRole]
    /// Lower-cased addresses the student sends from.
    var ownAddresses: Set<String>

    static func load(_ db: Database) throws -> MailboxDirectory {
        let accounts = try MailAccount.all.fetchAll(db)
        let mailboxes = try Mailbox.all.fetchAll(db)
        var roles: [Mailbox.ID: MailboxRole] = [:]
        for mailbox in mailboxes {
            if let role = mailbox.role { roles[mailbox.id] = role }
        }
        let own = Set(accounts.map(\.sender.normalizedAddress).filter { !$0.isEmpty })
        return MailboxDirectory(
            accounts: Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            roles: roles,
            ownAddresses: own
        )
    }

    static func load(_ database: any DatabaseReader) async throws -> MailboxDirectory {
        try await database.read { db in try load(db) }
    }

    func role(of message: MailMessage) -> MailboxRole? { roles[message.mailboxID] }

    /// Written by the student: in Sent, or from one of their addresses.
    func isOwn(_ message: MailMessage) -> Bool {
        role(of: message) == .sent || ownAddresses.contains(message.from.normalizedAddress)
    }
}

extension Array {
    /// Consecutive slices of at most `size` elements.
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        guard size > 0 else { return [self[...]] }
        return stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
