import Foundation
import StudyCore

/// Checks account settings before they are saved (Settings ▸ Accounts): logs in to IMAP
/// (capabilities IDLE and UIDPLUS) and to SMTP (EHLO, STARTTLS, AUTH), then logs out. Sends
/// nothing and stores nothing; the caller saves the password to the Keychain only afterwards.
public struct MailAccountVerifier: Sendable {
    private let connector: any MailConnector

    public init(connector: any MailConnector = SwiftMailConnector()) {
        self.connector = connector
    }

    /// Throws a readable error (`MailAccountError`, `MailTransportError`): unreachable host,
    /// authentication failed, TLS failed, missing capability.
    public func verify(_ account: MailAccount, password: String) async throws {
        guard !account.username.trimmingCharacters(in: .whitespaces).isEmpty else { throw MailAccountError.missingAccountName }
        guard MailSender.isPlausibleAddress(account.emailAddress) else { throw MailAccountError.invalidAddress }
        guard !password.isEmpty else { throw MailTransportError.noPassword }
        let credentials = MailCredentials(username: account.username, password: password)

        let imap = try await connector.openIMAP(account.imapEndpoint, credentials: credentials)
        let capabilities = await imap.capabilities()
        await imap.logout()
        for needed in ["IDLE", "UIDPLUS"] where !capabilities.contains(needed) {
            throw MailTransportError.missingCapability(needed)
        }

        let smtp = try await connector.openSubmission(for: account, credentials: credentials)
        await smtp.close()
    }
}

/// Settings that cannot work, found before any connection.
public enum MailAccountError: Error, Hashable, Sendable, LocalizedError {
    case missingAccountName
    case invalidAddress

    public var errorDescription: String? {
        switch self {
        case .missingAccountName: "Enter the uni account name."
        case .invalidAddress: "Enter the mail address."
        }
    }
}
