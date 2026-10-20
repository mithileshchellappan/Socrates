import Foundation
import StudyCore

// The package's own view of IMAP and SMTP. `SwiftMailConnector` implements it over SwiftMail; the
// tests implement it with scripted fakes, so the sync engine, the sender and the verifier run
// offline. Mailbox paths here are always decoded (modified UTF-7 is the connector's business).

// MARK: - Endpoints and credentials

/// Where a connection goes.
public struct MailEndpoint: Hashable, Sendable, CustomStringConvertible {
    public var host: String
    public var port: Int
    public var security: MailSecurity

    public init(host: String, port: Int, security: MailSecurity) {
        self.host = host
        self.port = port
        self.security = security
    }

    public var description: String { "\(host):\(port) (\(security.rawValue))" }
}

/// A login. The password is read from the Keychain right before a connection opens and is never
/// stored, logged or printed: every textual representation of this value is redacted.
public struct MailCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var description: String { "MailCredentials(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension MailAccount {
    /// The IMAP server (Exampleton: imap.students.example.org:993, TLS).
    public var imapEndpoint: MailEndpoint { MailEndpoint(host: imapHost, port: imapPort, security: imapSecurity) }

    /// The submission server (Exampleton: smtp.students.example.org:587, STARTTLS).
    public var smtpEndpoint: MailEndpoint { MailEndpoint(host: smtpHost, port: smtpPort, security: smtpSecurity) }

    /// Tried only when `smtpEndpoint` cannot be reached (Exampleton: smtp.example.org:465, TLS).
    public var smtpFallbackEndpoint: MailEndpoint? {
        guard let host = smtpFallbackHost, !host.isEmpty, let port = smtpFallbackPort else { return nil }
        return MailEndpoint(host: host, port: port, security: smtpFallbackSecurity ?? .tls)
    }
}

// MARK: - Errors

/// Why a mail connection or command failed, in words the student can read. Never carries a
/// password; server replies are trimmed and only shown in the app (logged privately).
public enum MailTransportError: Error, Hashable, Sendable, LocalizedError {
    /// The host could not be reached (DNS, refused, no network, connect timeout).
    case unreachable(host: String)
    /// TLS (or STARTTLS) could not be established.
    case tlsFailed(host: String)
    /// The server rejected the account name or password.
    case authenticationFailed(host: String)
    /// No password is stored for the account.
    case noPassword
    /// The server lacks something the app needs.
    case missingCapability(String)
    /// The connection dropped or timed out mid-session.
    case connectionLost(host: String)
    /// The server refused a command (IMAP NO/BAD, SMTP 4xx/5xx), with its reply.
    case refused(String)
    /// The SMTP server stopped answering after the message was handed over; it may or may not
    /// have been accepted.
    case unconfirmed(String)

    /// Errors after which the engine must not log in again on its own (an account can lock).
    public var isAuthentication: Bool {
        switch self {
        case .authenticationFailed, .noPassword: true
        default: false
        }
    }

    /// Errors worth retrying later with back-off.
    public var isTransient: Bool {
        switch self {
        case .unreachable, .connectionLost, .tlsFailed: true
        default: false
        }
    }

    /// The server cannot take a password login at all: retrying on a timer changes nothing, so
    /// the engine stops like after a refused login (until the account is saved again).
    public var isLoginUnsupported: Bool {
        if case .missingCapability(let name) = self { return name == "password login" }
        return false
    }

    /// The server answered NO or BAD to one command: the session itself is still good.
    public var isRefusal: Bool {
        if case .refused = self { return true }
        return false
    }

    /// The case alone, for the log: never a host, a server reply or an address.
    public var kind: String {
        switch self {
        case .unreachable: "unreachable"
        case .tlsFailed: "tls"
        case .authenticationFailed: "authentication"
        case .noPassword: "noPassword"
        case .missingCapability(let name): "missingCapability(\(name))"
        case .connectionLost: "connectionLost"
        case .refused: "refused"
        case .unconfirmed: "unconfirmed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unreachable(let host): "Can’t reach \(host)."
        case .tlsFailed(let host): "A secure connection to \(host) failed."
        case .authenticationFailed: "The account name or password is wrong."
        case .noPassword: "No password is saved for this account."
        case .missingCapability(let name): "The mail server does not support \(name)."
        case .connectionLost(let host): "The connection to \(host) was lost."
        case .refused(let reply): reply.isEmpty ? "The mail server refused." : "The mail server refused: \(reply)"
        case .unconfirmed(let reply):
            reply.isEmpty ? "The mail server did not confirm the message." : "The mail server did not confirm the message: \(reply)"
        }
    }

    /// Trims a server reply for display: one line, at most 200 characters.
    static func trimmed(_ reply: String) -> String {
        let line = reply
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }
}

// MARK: - IMAP

/// Standard IMAP flags as the server spells them (keywords are passed through as they are).
public enum IMAPFlag {
    public static let seen = "\\Seen"
    public static let answered = "\\Answered"
    public static let flagged = "\\Flagged"
    public static let deleted = "\\Deleted"
    public static let draft = "\\Draft"
    public static let recent = "\\Recent"

    /// Compares flags the way IMAP does (system flags are case-insensitive).
    static func normalized(_ flag: String) -> String {
        flag.hasPrefix("\\") ? flag.lowercased() : flag
    }

    static func contains(_ flags: Set<String>, _ flag: String) -> Bool {
        let wanted = normalized(flag)
        return flags.contains { normalized($0) == wanted }
    }
}

/// One mailbox from LIST (path decoded from modified UTF-7).
public struct IMAPFolder: Hashable, Sendable {
    public var path: String
    public var delimiter: String?
    /// Attributes as the server spells them: "\\Noselect", "\\HasChildren", "\\Sent", "\\Archive", …
    public var attributes: Set<String>

    public init(path: String, delimiter: String? = nil, attributes: Set<String> = []) {
        self.path = path
        self.delimiter = delimiter
        self.attributes = attributes
    }

    public var isSelectable: Bool {
        !attributes.contains { $0.caseInsensitiveCompare("\\Noselect") == .orderedSame || $0.caseInsensitiveCompare("\\NonExistent") == .orderedSame }
    }

    func hasAttribute(_ name: String) -> Bool {
        attributes.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// The state SELECT reports.
public struct IMAPSelection: Hashable, Sendable {
    public var uidValidity: UInt32
    public var uidNext: UInt32?
    public var messageCount: Int
    /// HIGHESTMODSEQ (CONDSTORE/QRESYNC servers).
    public var highestModSeq: UInt64?

    public init(uidValidity: UInt32, uidNext: UInt32? = nil, messageCount: Int = 0, highestModSeq: UInt64? = nil) {
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.messageCount = messageCount
        self.highestModSeq = highestModSeq
    }
}

/// SELECT … (QRESYNC …): what changed since a checkpoint.
public struct IMAPResync: Hashable, Sendable {
    public var selection: IMAPSelection
    /// UIDs expunged since the checkpoint (VANISHED (EARLIER) and live VANISHED).
    public var vanished: Set<UInt32>
    /// Full flag sets of messages whose flags changed since the checkpoint.
    public var changedFlags: [UInt32: Set<String>]

    public init(selection: IMAPSelection, vanished: Set<UInt32> = [], changedFlags: [UInt32: Set<String>] = [:]) {
        self.selection = selection
        self.vanished = vanished
        self.changedFlags = changedFlags
    }
}

/// UID SEARCH criteria the sync uses.
public enum IMAPSearch: Hashable, Sendable {
    /// Every message.
    case all
    /// INTERNALDATE on or after this day (IMAP SINCE).
    case since(CalendarDay)
    /// UIDs in the range (UID SEARCH UID a:b).
    case uids(ClosedRange<UInt32>)
    /// Messages whose Message-ID header contains this id (HEADER Message-ID).
    case messageID(String)
}

/// FLAGS, INTERNALDATE and RFC822.SIZE of one message.
public struct IMAPSummary: Hashable, Sendable {
    public var uid: UInt32
    public var flags: Set<String>
    public var internalDate: Date?
    public var size: Int

    public init(uid: UInt32, flags: Set<String> = [], internalDate: Date? = nil, size: Int = 0) {
        self.uid = uid
        self.flags = flags
        self.internalDate = internalDate
        self.size = size
    }
}

/// One leaf of BODYSTRUCTURE (for messages too large to fetch whole).
public struct IMAPBodyPart: Hashable, Sendable {
    /// IMAP section, "1", "2.1".
    public var section: String
    /// "text/plain", lower-cased.
    public var mimeType: String
    public var charset: String?
    /// "base64", "quoted-printable", "7bit", …
    public var encoding: String?
    public var disposition: String?
    public var fileName: String?
    public var contentID: String?
    public var size: Int

    public init(
        section: String, mimeType: String, charset: String? = nil, encoding: String? = nil, disposition: String? = nil,
        fileName: String? = nil, contentID: String? = nil, size: Int = 0
    ) {
        self.section = section
        self.mimeType = mimeType
        self.charset = charset
        self.encoding = encoding
        self.disposition = disposition
        self.fileName = fileName
        self.contentID = contentID
        self.size = size
    }
}

/// COPYUID / APPENDUID (UIDPLUS): where messages landed.
public struct IMAPCopyResult: Hashable, Sendable {
    public var uidValidity: UInt32
    /// Source UID → destination UID (for APPEND: 0 → the new UID).
    public var mapping: [UInt32: UInt32]

    public init(uidValidity: UInt32, mapping: [UInt32: UInt32]) {
        self.uidValidity = uidValidity
        self.mapping = mapping
    }
}

public enum IMAPStoreOperation: Hashable, Sendable {
    case add
    case remove
}

/// Something IDLE reported. Any change means "look again"; `bye` ends the session.
public enum IMAPIdleEvent: Hashable, Sendable {
    case exists(Int)
    case expunge
    case flagsChanged
    case other
    case bye

    public var isChange: Bool {
        switch self {
        case .exists, .expunge, .flagsChanged: true
        case .other, .bye: false
        }
    }
}

/// One logged-in IMAP connection. Commands run one at a time; implementations are actors.
public protocol IMAPSession: Sendable {
    /// Capabilities after login, upper-cased ("IDLE", "QRESYNC", "MOVE", "UIDPLUS", "AUTH=PLAIN").
    func capabilities() async -> Set<String>
    /// ENABLE; returns what the server enabled.
    func enable(_ capabilities: [String]) async throws -> Set<String>
    func listMailboxes() async throws -> [IMAPFolder]
    func createMailbox(_ path: String) async throws
    func select(_ path: String) async throws -> IMAPSelection
    /// SELECT with QRESYNC from a checkpoint (needs `enable(["QRESYNC"])` first).
    func select(_ path: String, resyncFrom uidValidity: UInt32, modSeq: UInt64) async throws -> IMAPResync
    /// UID SEARCH in the selected mailbox.
    func search(_ criteria: IMAPSearch) async throws -> [UInt32]
    /// UID FETCH (FLAGS INTERNALDATE RFC822.SIZE).
    func fetchSummaries(_ uids: [UInt32]) async throws -> [IMAPSummary]
    /// UID FETCH (FLAGS).
    func fetchFlags(_ uids: [UInt32]) async throws -> [UInt32: Set<String>]
    /// UID FETCH BODY.PEEK[] (never sets \Seen).
    func fetchRaw(_ uid: UInt32) async throws -> Data
    func fetchStructure(_ uid: UInt32) async throws -> [IMAPBodyPart]
    /// UID FETCH BODY.PEEK[section], still transfer-encoded. "HEADER" for the header block.
    func fetchSection(_ uid: UInt32, section: String) async throws -> Data
    func store(_ uids: [UInt32], flags: Set<String>, _ operation: IMAPStoreOperation) async throws
    /// UID MOVE (RFC 6851); throws `missingCapability("MOVE")` without it.
    func move(_ uids: [UInt32], to path: String) async throws -> IMAPCopyResult?
    func copy(_ uids: [UInt32], to path: String) async throws -> IMAPCopyResult?
    /// UID EXPUNGE of exactly these UIDs (UIDPLUS); a plain EXPUNGE without UIDPLUS.
    func expunge(_ uids: [UInt32]) async throws
    func append(_ message: Data, to path: String, flags: Set<String>, date: Date?) async throws -> IMAPCopyResult?
    /// Selects `path` and stays in IDLE (renewed by the session) until `logout()`. The stream ends
    /// when the connection is lost.
    func idle(_ path: String) async throws -> AsyncStream<IMAPIdleEvent>
    func logout() async
}

// MARK: - SMTP

/// One logged-in SMTP submission connection.
public protocol SMTPSession: Sendable {
    /// MAIL FROM / RCPT TO / DATA with `message` as it is (CRLF line endings).
    func send(_ message: Data, from sender: String, to recipients: [String]) async throws
    func close() async
}

// MARK: - Connector

/// Opens logged-in IMAP and SMTP connections: `SwiftMailConnector` in the app, fakes in tests.
public protocol MailConnector: Sendable {
    /// Connects (TLS) and logs in (AUTH=PLAIN when offered, else LOGIN; one attempt).
    func openIMAP(_ endpoint: MailEndpoint, credentials: MailCredentials) async throws -> any IMAPSession
    /// Connects (STARTTLS or TLS), EHLO, AUTH (one attempt).
    func openSMTP(_ endpoint: MailEndpoint, credentials: MailCredentials) async throws -> any SMTPSession
}

extension MailConnector {
    /// SMTP on the account's server, and on the fallback only when the first cannot be reached
    /// (never after an authentication or TLS failure).
    func openSubmission(for account: MailAccount, credentials: MailCredentials) async throws -> any SMTPSession {
        do {
            return try await openSMTP(account.smtpEndpoint, credentials: credentials)
        } catch MailTransportError.unreachable(let host) {
            guard let fallback = account.smtpFallbackEndpoint, fallback != account.smtpEndpoint else {
                throw MailTransportError.unreachable(host: host)
            }
            Log.mail.info("SMTP \(account.smtpEndpoint.description, privacy: .public) unreachable; trying the fallback")
            return try await openSMTP(fallback, credentials: credentials)
        }
    }
}
