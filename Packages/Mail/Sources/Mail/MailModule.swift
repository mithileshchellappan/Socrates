import Foundation
import StudyCore

/// University mail transport (workstream A, docs/plan-m2.md §3): IMAP sync, MIME parsing, safe
/// HTML-to-text, SMTP sending. Only `SwiftMailConnector` (to come) imports SwiftMail; everything
/// else works against the package's own connection protocols, so tests run on fakes offline.
/// Logs through `Log.mail`.
public enum MailModule {
    public static let moduleName = "Mail"
}
