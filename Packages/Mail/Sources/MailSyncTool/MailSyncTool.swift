import Foundation
import Mail
import Security
import StudyCore

/// Dev CLI for the opt-in live check against the Exampleton servers (run by the student, never by
/// agents or tests). Reads the uni password from the app's Keychain item (Settings ▸ Accounts),
/// never from the command line or the environment. Sends nothing.
///
///     swift run --package-path Packages/Mail mail-sync check [--username NAME]
///     swift run --package-path Packages/Mail mail-sync sync [--username NAME] [--days 7] [--library .data/mail-live]
@main
struct MailSyncTool {
    static let usage = """
        usage: mail-sync check [--username NAME] [--address ALIAS]
               mail-sync sync  [--username NAME] [--address ALIAS] [--days N] [--library DIR]

        check  logs in to IMAP and SMTP (Exampleton servers), lists capabilities and mailboxes; sends nothing
        sync   syncs the last N days (default 7) of INBOX, Sent and Archive into a throwaway library
               (default .data/mail-live, which must be new, empty or written by this tool)

        The password is the app's Keychain item uni-password.<username>; the username defaults to
        the only such item. Nothing is sent, ever.
        """

    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first, ["check", "sync"].contains(command) else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            exit(2)
        }
        arguments.removeFirst()
        do {
            let options = try Options(arguments)
            switch command {
            case "check": try await check(options)
            default: try await sync(options)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            FileHandle.standardError.write(Data("error: \(message)\n".utf8))
            exit(1)
        }
    }

    struct Options {
        var username: String?
        var address: String?
        var days = 7
        var library = URL(filePath: ".data/mail-live", directoryHint: .isDirectory)

        init(_ arguments: [String]) throws {
            var index = 0
            func value() throws -> String {
                index += 1
                guard index < arguments.count else { throw ToolError.usage }
                return arguments[index]
            }
            while index < arguments.count {
                switch arguments[index] {
                case "--username": username = try value()
                case "--address": address = try value()
                case "--days": days = Int(try value()) ?? 7
                case "--library": library = URL(filePath: try value(), directoryHint: .isDirectory)
                default: throw ToolError.usage
                }
                index += 1
            }
        }
    }

    enum ToolError: Error, LocalizedError {
        case usage
        case noPassword
        case ambiguousUsername([String])
        case unsafeLibrary(String)

        var errorDescription: String? {
            switch self {
            case .usage: MailSyncTool.usage
            case .noPassword: "No uni password in the Keychain. Save the account in the app (Settings ▸ Accounts) first."
            case .ambiguousUsername(let names): "Several uni passwords in the Keychain (\(names.joined(separator: ", "))); pass --username."
            case .unsafeLibrary(let path): "\(path) is not a new, empty or mail-sync library; pick another --library."
            }
        }
    }

    static func account(_ options: Options) throws -> (MailAccount, KeychainSecretStore) {
        let secrets = KeychainSecretStore()
        let username: String
        if let given = options.username {
            username = given
        } else {
            let stored = LiveKeychain.uniUsernames()
            guard let only = stored.first else { throw ToolError.noPassword }
            guard stored.count == 1 else { throw ToolError.ambiguousUsername(stored) }
            username = only
        }
        let account = MailAccount(
            displayName: "", emailAddress: options.address ?? "\(username)@students.example.org", username: username,
            syncSince: CalendarDay(Date(), in: MailClock.berlin).adding(days: -options.days)
        )
        guard secrets.hasSecret(for: account.passwordKey) else { throw ToolError.noPassword }
        return (account, secrets)
    }

    static func check(_ options: Options) async throws {
        let (account, secrets) = try account(options)
        guard let password = try secrets.secret(for: account.passwordKey) else { throw ToolError.noPassword }
        let connector = SwiftMailConnector()
        let credentials = MailCredentials(username: account.username, password: password)
        print("IMAP \(account.imapEndpoint)")
        let imap = try await connector.openIMAP(account.imapEndpoint, credentials: credentials)
        print("  logged in; capabilities: \(await imap.capabilities().sorted().joined(separator: " "))")
        for folder in try await imap.listMailboxes() {
            print("  \(folder.path)  \(folder.attributes.sorted().joined(separator: " "))")
        }
        await imap.logout()
        print("SMTP \(account.smtpEndpoint)")
        try await MailAccountVerifier(connector: connector).verify(account, password: password)
        print("  IMAP and SMTP login OK; nothing was sent.")
    }

    static func sync(_ options: Options) async throws {
        let (account, secrets) = try account(options)
        let root = options.library.standardizedFileURL
        try prepareLibrary(root)
        let paths = AppPaths(root: root)
        try paths.createDirectories()
        let services = StudyServices(
            paths: paths, database: try StudyDatabase.open(at: paths.database), blobs: BlobStore(root: paths.blobs), secrets: secrets
        )
        if try await MailAccountRepository(store: services.records).current() == nil {
            try await services.records.save(account)
        }
        var configuration = MailSyncConfiguration()
        configuration.usesIdle = false
        let engine = MailSyncEngine(services: services, onNewMail: { ids in print("  +\(ids.count) messages") }, configuration: configuration)
        let started = Date()
        await engine.start()
        await engine.stop()
        let stored = try await MailAccountRepository(store: services.records).current()
        if let error = stored?.lastError { print("sync failed: \(error)") }
        for mailbox in try await MailboxRepository(store: services.records).mailboxes(accountID: account.id) where mailbox.isSynced {
            let mailboxID = mailbox.id
            let count = try await services.database.read { db in try MailMessage.where { $0.mailboxID.eq(mailboxID) }.fetchCount(db) }
            print("\(mailbox.path) (\(mailbox.role?.rawValue ?? "-")): \(count) messages, UIDVALIDITY \(mailbox.uidValidity ?? 0), last UID \(mailbox.lastUID), HIGHESTMODSEQ \(mailbox.highestModSeq.map(String.init) ?? "-")")
        }
        print(String(format: "done in %.1f s; library %@; nothing was sent.", Date().timeIntervalSince(started), root.path(percentEncoded: false)))
    }

    /// Only a new or empty folder, or one this tool wrote, and never the app's real library.
    static func prepareLibrary(_ root: URL) throws {
        let manager = FileManager.default
        let marker = root.appending(path: ".mail-sync-library")
        if let live = try? AppPaths.live(), live.root.standardizedFileURL == root { throw ToolError.unsafeLibrary(root.path(percentEncoded: false)) }
        if manager.fileExists(atPath: root.path(percentEncoded: false)) {
            let contents = (try? manager.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
            guard contents.isEmpty || manager.fileExists(atPath: marker.path(percentEncoded: false)) else {
                throw ToolError.unsafeLibrary(root.path(percentEncoded: false))
            }
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: marker)
    }
}

/// Lists the app's uni password items (names only, never values).
enum LiveKeychain {
    static func uniUsernames() -> [String] {
        var names: Set<String> = []
        for dataProtection in [true, false] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Log.subsystem,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecUseDataProtectionKeychain as String: dataProtection,
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { continue }
            for item in items {
                if let account = item[kSecAttrAccount as String] as? String, account.hasPrefix("uni-password.") {
                    names.insert(String(account.dropFirst("uni-password.".count)))
                }
            }
        }
        return names.sorted()
    }
}
