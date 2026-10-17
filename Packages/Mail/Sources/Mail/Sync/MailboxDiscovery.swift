import Foundation
import StudyCore

/// Mailbox roles from LIST: SPECIAL-USE attributes first, then names (English and German).
enum MailboxDiscovery {
    /// Roles whose messages are synced.
    static let syncedRoles: [MailboxRole] = [.inbox, .sent, .archive]

    static let fallbackNames: [MailboxRole: [String]] = [
        .sent: ["sent", "gesendet", "sent items", "sent messages", "sent mail", "gesendete objekte", "gesendete elemente", "gesendete nachrichten"],
        .archive: ["archive", "archiv", "archives"],
        .drafts: ["drafts", "entwürfe", "entwuerfe", "draft"],
        .trash: ["trash", "papierkorb", "deleted items", "deleted messages", "gelöschte elemente", "gelöschte objekte", "bin"],
        .junk: ["junk", "spam", "junk e-mail", "junk-e-mail", "junk email", "unerwünscht"],
    ]

    static let specialUse: [MailboxRole: String] = [
        .sent: "\\Sent", .archive: "\\Archive", .drafts: "\\Drafts", .trash: "\\Trash", .junk: "\\Junk",
    ]

    /// The role each folder path gets (one folder per role).
    static func roles(for folders: [IMAPFolder]) -> [String: MailboxRole] {
        var roles: [String: MailboxRole] = [:]
        let selectable = folders.filter(\.isSelectable)
        if let inbox = selectable.first(where: { $0.path.caseInsensitiveCompare("INBOX") == .orderedSame }) {
            roles[inbox.path] = .inbox
        }
        for role in [MailboxRole.sent, .archive, .drafts, .trash, .junk] {
            let taken = Set(roles.keys)
            if let attribute = specialUse[role],
               let folder = selectable.first(where: { $0.hasAttribute(attribute) && !taken.contains($0.path) }) {
                roles[folder.path] = role
                continue
            }
            let names = fallbackNames[role] ?? []
            // Prefer a top-level folder, then one directly under INBOX.
            let candidates = selectable
                .filter { !taken.contains($0.path) && names.contains(lastComponent($0).lowercased()) }
                .sorted { depth($0) < depth($1) }
            if let folder = candidates.first { roles[folder.path] = role }
        }
        return roles
    }

    static func lastComponent(_ folder: IMAPFolder) -> String {
        guard let delimiter = folder.delimiter, !delimiter.isEmpty else { return folder.path }
        return folder.path.components(separatedBy: delimiter).last ?? folder.path
    }

    static func depth(_ folder: IMAPFolder) -> Int {
        guard let delimiter = folder.delimiter, !delimiter.isEmpty else { return 0 }
        return folder.path.components(separatedBy: delimiter).count - 1
    }
}
