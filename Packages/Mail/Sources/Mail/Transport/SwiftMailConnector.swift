import Foundation
import struct NIOIMAPCore.Capability
import struct NIOIMAPCore.ModificationSequenceValue
import StudyCore
import SwiftMail

// The only file that imports SwiftMail. `StudyCore.Mailbox` and `SwiftMail.Mailbox` clash here,
// so both are always qualified. Passwords pass through to SwiftMail's login calls and nowhere
// else; errors are mapped to `MailTransportError` without the server's raw description where it
// could echo credentials.

/// The production connector: SwiftMail over TLS (IMAP 993 implicit TLS; SMTP 587 STARTTLS or
/// 465 TLS). One attempt per login: never retried here.
public struct SwiftMailConnector: MailConnector {
    public init() {}

    public func openIMAP(_ endpoint: MailEndpoint, credentials: MailCredentials) async throws -> any IMAPSession {
        let server = IMAPServer(host: endpoint.host, port: endpoint.port, transportSecurity: endpoint.security.transport)
        do {
            try await server.connect()
        } catch {
            try? await server.disconnect()
            throw Self.connectError(error, host: endpoint.host)
        }
        do {
            let offered = try await server.fetchCapabilities().map(Self.name)
            if offered.contains("AUTH=PLAIN") {
                try await server.authenticatePlain(username: credentials.username, password: credentials.password)
            } else {
                try await server.login(username: credentials.username, password: credentials.password)
            }
        } catch {
            try? await server.disconnect()
            throw Self.loginError(error, host: endpoint.host)
        }
        let capabilities = (try? await server.fetchCapabilities()).map { Set($0.map(Self.name)) } ?? []
        return SwiftMailIMAPSession(server: server, host: endpoint.host, capabilities: capabilities)
    }

    public func openSMTP(_ endpoint: MailEndpoint, credentials: MailCredentials) async throws -> any SMTPSession {
        let server = SMTPServer(host: endpoint.host, port: endpoint.port, transportSecurity: endpoint.security.transport)
        do {
            try await server.connect()
        } catch {
            try? await server.disconnect()
            throw Self.connectError(error, host: endpoint.host)
        }
        do {
            try await server.login(username: credentials.username, password: credentials.password)
        } catch {
            try? await server.disconnect()
            throw Self.loginError(error, host: endpoint.host)
        }
        return SwiftMailSMTPSession(server: server, host: endpoint.host)
    }

    // MARK: - Error mapping

    static func name(_ capability: Capability) -> String {
        (capability.value.map { "\(capability.name)=\($0)" } ?? capability.name).uppercased()
    }

    static func isTLSError(_ error: any Error) -> Bool {
        let type = String(reflecting: Swift.type(of: error))
        return type.contains("NIOSSL") || type.contains("BoringSSL")
    }

    static func connectError(_ error: any Error, host: String) -> MailTransportError {
        if let mapped = error as? MailTransportError { return mapped }
        if isTLSError(error) { return .tlsFailed(host: host) }
        if case SMTPError.tlsFailed = error { return .tlsFailed(host: host) }
        return .unreachable(host: host)
    }

    static func loginError(_ error: any Error, host: String) -> MailTransportError {
        if isTLSError(error) { return .tlsFailed(host: host) }
        switch error {
        case IMAPError.loginFailed(let reason), IMAPError.authFailed(let reason):
            // Dovecot answers [UNAVAILABLE] / [INUSE] for temporary trouble, not a wrong password.
            let upper = reason.uppercased()
            if upper.contains("UNAVAILABLE") || upper.contains("INUSE") { return .connectionLost(host: host) }
            return .authenticationFailed(host: host)
        case SMTPError.authenticationFailed:
            return .authenticationFailed(host: host)
        case SMTPError.tlsFailed:
            return .tlsFailed(host: host)
        case IMAPError.unsupportedAuthMechanism:
            return .missingCapability("password login")
        case IMAPError.connectionFailed, IMAPError.timeout, SMTPError.connectionFailed:
            return .connectionLost(host: host)
        default:
            return .connectionLost(host: host)
        }
    }

    static func commandError(_ error: any Error, host: String) -> MailTransportError {
        if let mapped = error as? MailTransportError { return mapped }
        if isTLSError(error) { return .connectionLost(host: host) }
        switch error {
        case IMAPError.authFailed, IMAPError.loginFailed:
            return .authenticationFailed(host: host)
        case IMAPError.connectionFailed, IMAPError.timeout, IMAPError.greetingFailed:
            return .connectionLost(host: host)
        case IMAPError.commandNotSupported(let reason):
            return .missingCapability(MailTransportError.trimmed(reason))
        case let error as IMAPError:
            return .refused(MailTransportError.trimmed(error.description))
        case is CancellationError:
            return .connectionLost(host: host)
        default:
            // NIO channel errors (closed, reset, …).
            return .connectionLost(host: host)
        }
    }
}

extension MailSecurity {
    fileprivate var transport: MailTransportSecurity {
        self == .startTLS ? .startTLS : .implicitTLS
    }
}

// MARK: - IMAP

actor SwiftMailIMAPSession: IMAPSession {
    private let server: IMAPServer
    private let host: String
    private var capabilitySet: Set<String>
    private var idleTask: Task<Void, Never>?

    /// IDLE is re-issued this often (RFC 2177: at least every 29 minutes).
    static let idleRenewal: Duration = .seconds(25 * 60)

    init(server: IMAPServer, host: String, capabilities: Set<String>) {
        self.server = server
        self.host = host
        self.capabilitySet = capabilities
    }

    private func run<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw SwiftMailConnector.commandError(error, host: host)
        }
    }

    private static func encode(_ path: String) -> String { ModifiedUTF7.encode(path) }

    private static func uidSet(_ uids: [UInt32]) -> UIDSet { UIDSet(uids.map { UID($0) }) }

    private static func flagNames(_ flags: [Flag]) -> Set<String> {
        Set(flags.map { flag in
            switch flag {
            case .seen: IMAPFlag.seen
            case .answered: IMAPFlag.answered
            case .flagged: IMAPFlag.flagged
            case .deleted: IMAPFlag.deleted
            case .draft: IMAPFlag.draft
            case .custom(let name): name
            }
        })
    }

    private static func flags(_ names: Set<String>) -> [Flag] {
        names.sorted().map { name in
            switch IMAPFlag.normalized(name) {
            case IMAPFlag.normalized(IMAPFlag.seen): .seen
            case IMAPFlag.normalized(IMAPFlag.answered): .answered
            case IMAPFlag.normalized(IMAPFlag.flagged): .flagged
            case IMAPFlag.normalized(IMAPFlag.deleted): .deleted
            case IMAPFlag.normalized(IMAPFlag.draft): .draft
            default: .custom(name)
            }
        }
    }

    private static func selection(_ selection: SwiftMail.Mailbox.Selection) -> IMAPSelection {
        IMAPSelection(
            uidValidity: selection.uidValidity.value,
            uidNext: selection.uidNext.value == 0 ? nil : selection.uidNext.value,
            messageCount: selection.messageCount,
            highestModSeq: selection.highestModSequence.map { UInt64($0) }
        )
    }

    private static func copyResult(_ copy: CopyUID?) -> IMAPCopyResult? {
        guard let copy else { return nil }
        var mapping: [UInt32: UInt32] = [:]
        for pair in copy.mapping { mapping[pair.source.value] = pair.destination.value }
        return IMAPCopyResult(uidValidity: copy.destinationUIDValidity.value, mapping: mapping)
    }

    func capabilities() async -> Set<String> { capabilitySet }

    func enable(_ capabilities: [String]) async throws -> Set<String> {
        try await run {
            let enabled = try await server.enable(capabilities.map { Capability($0) })
            return Set(enabled.map(SwiftMailConnector.name))
        }
    }

    func listMailboxes() async throws -> [IMAPFolder] {
        try await run {
            let all = try await server.listMailboxes()
            var special: [String: SwiftMail.Mailbox.Info.Attributes] = [:]
            if capabilitySet.contains("SPECIAL-USE"), let flagged = try? await server.listSpecialUseMailboxes() {
                for info in flagged { special[info.name, default: []].formUnion(info.attributes) }
            }
            return all.map { info in
                IMAPFolder(
                    path: ModifiedUTF7.decode(info.name),
                    delimiter: info.hierarchyDelimiter,
                    attributes: Self.attributeNames(info.attributes.union(special[info.name] ?? []))
                )
            }
        }
    }

    private static func attributeNames(_ attributes: SwiftMail.Mailbox.Info.Attributes) -> Set<String> {
        let names: [(SwiftMail.Mailbox.Info.Attributes, String)] = [
            (.noSelect, "\\Noselect"), (.hasChildren, "\\HasChildren"), (.hasNoChildren, "\\HasNoChildren"),
            (.archive, "\\Archive"), (.drafts, "\\Drafts"), (.flagged, "\\Flagged"), (.junk, "\\Junk"),
            (.sent, "\\Sent"), (.trash, "\\Trash"), (.inbox, "\\Inbox"), (.all, "\\All"),
        ]
        return Set(names.compactMap { attributes.contains($0.0) ? $0.1 : nil })
    }

    func createMailbox(_ path: String) async throws {
        try await run { try await server.createMailbox(Self.encode(path)) }
    }

    func select(_ path: String) async throws -> IMAPSelection {
        try await run { Self.selection(try await server.selectMailbox(Self.encode(path))) }
    }

    func select(_ path: String, resyncFrom uidValidity: UInt32, modSeq: UInt64) async throws -> IMAPResync {
        try await run {
            let result = try await server.selectMailbox(
                Self.encode(path),
                resyncingFrom: UIDValidity(uidValidity),
                modificationSequence: ModificationSequenceValue(modSeq)
            )
            var vanished = Set(result.vanishedEarlier.toArray().map(\.value))
            vanished.formUnion(result.vanished.toArray().map(\.value))
            var changed: [UInt32: Set<String>] = [:]
            for (uid, flags) in result.changedFlags { changed[uid.value] = Self.flagNames(flags) }
            return IMAPResync(selection: Self.selection(result.selection), vanished: vanished, changedFlags: changed)
        }
    }

    func search(_ criteria: IMAPSearch) async throws -> [UInt32] {
        try await run {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = MailClock.berlin
            let result: ExtendedSearchResult<UID>
            switch criteria {
            case .all:
                result = try await server.extendedSearch(criteria: [.all], calendar: calendar)
            case .since(let day):
                result = try await server.extendedSearch(criteria: [.since(day.start(in: MailClock.berlin))], calendar: calendar)
            case .uids(let range):
                result = try await server.extendedSearch(
                    identifierSet: UIDSet(UID(range.lowerBound)...UID(range.upperBound)), criteria: [.all], calendar: calendar
                )
            case .messageID(let id):
                result = try await server.extendedSearch(criteria: [.header("Message-ID", id)], calendar: calendar)
            }
            return (result.all?.toArray().map(\.value) ?? []).sorted()
        }
    }

    func fetchSummaries(_ uids: [UInt32]) async throws -> [IMAPSummary] {
        guard !uids.isEmpty else { return [] }
        return try await run {
            let infos = try await server.fetchMessageInfosBulk(using: Self.uidSet(uids), options: [.flags, .internalDate, .size])
            return infos.compactMap { info in
                guard let uid = info.uid?.value else { return nil }
                return IMAPSummary(uid: uid, flags: Self.flagNames(info.flags), internalDate: info.internalDate, size: info.size ?? 0)
            }
        }
    }

    func fetchFlags(_ uids: [UInt32]) async throws -> [UInt32: Set<String>] {
        guard !uids.isEmpty else { return [:] }
        return try await run {
            let infos = try await server.fetchMessageInfosBulk(using: Self.uidSet(uids), options: [.flags])
            var flags: [UInt32: Set<String>] = [:]
            for info in infos { if let uid = info.uid?.value { flags[uid] = Self.flagNames(info.flags) } }
            return flags
        }
    }

    func fetchRaw(_ uid: UInt32) async throws -> Data {
        try await run { try await server.fetchRawMessage(identifier: UID(uid)) }
    }

    func fetchStructure(_ uid: UInt32) async throws -> [IMAPBodyPart] {
        try await run {
            try await server.fetchStructure(UID(uid)).map { part in
                IMAPBodyPart(
                    section: part.section.description,
                    mimeType: part.contentType.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "",
                    charset: part.declaredCharset,
                    encoding: part.encoding?.lowercased(),
                    disposition: part.disposition?.lowercased(),
                    fileName: part.filename,
                    contentID: part.contentId,
                    size: part.size ?? 0
                )
            }
        }
    }

    func fetchSection(_ uid: UInt32, section: String) async throws -> Data {
        guard section.uppercased() == "HEADER" else {
            return try await run { try await server.fetchPart(section: Section(section), of: UID(uid)) }
        }
        // SwiftMail has no public BODY.PEEK[HEADER]; rebuild the header block from ENVELOPE and
        // the parsed full header (used only for messages too large to fetch whole).
        return try await run {
            guard let info = try await server.fetchMessageInfo(for: UID(uid), options: [.envelope, .fullHeader]) else {
                throw MailTransportError.refused("No such message")
            }
            var lines: [String] = []
            func add(_ name: String, _ value: String?) {
                guard let value, !value.isEmpty else { return }
                lines.append("\(name): \(value)")
            }
            add("From", info.fromAddresses.map(\.description).joined(separator: ", "))
            add("Reply-To", info.replyToAddresses.map(\.description).joined(separator: ", "))
            add("To", info.toAddresses.map(\.description).joined(separator: ", "))
            add("Cc", info.ccAddresses.map(\.description).joined(separator: ", "))
            add("Subject", info.subject)
            add("Date", info.date.map(MessageComposer.dateHeader))
            add("Message-ID", info.messageId?.description)
            add("In-Reply-To", info.inReplyTo?.description)
            add("References", info.references?.map(\.description).joined(separator: " "))
            for field in info.additionalHeaderFields ?? [] { add(field.name, field.value) }
            return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        }
    }

    func store(_ uids: [UInt32], flags: Set<String>, _ operation: IMAPStoreOperation) async throws {
        guard !uids.isEmpty, !flags.isEmpty else { return }
        try await run {
            try await server.store(flags: Self.flags(flags), on: Self.uidSet(uids), operation: operation == .add ? .add : .remove)
        }
    }

    func move(_ uids: [UInt32], to path: String) async throws -> IMAPCopyResult? {
        try await run {
            Self.copyResult(try await server.move(messages: Self.uidSet(uids), to: Self.encode(path), fallback: .disabled))
        }
    }

    func copy(_ uids: [UInt32], to path: String) async throws -> IMAPCopyResult? {
        try await run { Self.copyResult(try await server.copy(messages: Self.uidSet(uids), to: Self.encode(path))) }
    }

    func expunge(_ uids: [UInt32]) async throws {
        try await run {
            if await server.supportsUIDPlus {
                try await server.expunge(messages: Self.uidSet(uids))
            } else {
                try await server.expunge()
            }
        }
    }

    func append(_ message: Data, to path: String, flags: Set<String>, date: Date?) async throws -> IMAPCopyResult? {
        try await run {
            let result = try await server.append(
                rawMessage: String(decoding: message, as: UTF8.self), to: Self.encode(path), flags: Self.flags(flags), internalDate: date
            )
            guard let validity = result.uidValidity, let uid = result.firstUID else { return nil }
            return IMAPCopyResult(uidValidity: validity.value, mapping: [0: uid.value])
        }
    }

    func idle(_ path: String) async throws -> AsyncStream<IMAPIdleEvent> {
        let server = server
        _ = try await run { try await server.selectMailbox(Self.encode(path)) }
        let (stream, continuation) = AsyncStream<IMAPIdleEvent>.makeStream()
        idleTask?.cancel()
        idleTask = Task {
            defer { continuation.finish() }
            while !Task.isCancelled {
                let events: AsyncStream<IMAPServerEvent>
                do {
                    events = try await server.idle()
                } catch {
                    return
                }
                let renewal = Task<Bool, Never> {
                    do {
                        try await Task.sleep(for: Self.idleRenewal)
                    } catch {
                        return false
                    }
                    try? await server.done()
                    return true
                }
                for await event in events {
                    let mapped = Self.idleEvent(event)
                    continuation.yield(mapped)
                    if mapped == .bye {
                        renewal.cancel()
                        return
                    }
                }
                renewal.cancel()
                // The stream ended: our DONE (renew) or a lost connection (end).
                guard await renewal.value else { return }
            }
        }
        return stream
    }

    private static func idleEvent(_ event: IMAPServerEvent) -> IMAPIdleEvent {
        switch event {
        case .exists(let count): .exists(count)
        case .expunge, .vanished: .expunge
        case .fetch, .fetchUID, .flags: .flagsChanged
        case .bye: .bye
        case .recent, .alert, .capability: .other
        }
    }

    func logout() async {
        if let idleTask {
            idleTask.cancel()
            try? await server.done()
            self.idleTask = nil
        }
        try? await server.logout()
        try? await server.disconnect()
    }
}

// MARK: - SMTP

actor SwiftMailSMTPSession: SMTPSession {
    private let server: SMTPServer
    private let host: String

    init(server: SMTPServer, host: String) {
        self.server = server
        self.host = host
    }

    func send(_ message: Data, from sender: String, to recipients: [String]) async throws {
        do {
            try await server.sendRawMessage(
                message, from: EmailAddress(address: sender), to: recipients.map { EmailAddress(address: $0) }
            )
        } catch let error as SMTPSendError {
            let reply = error.response.map { "\($0.code) \($0.message)" } ?? ""
            switch error.acceptance {
            case .ambiguous:
                throw MailTransportError.unconfirmed(MailTransportError.trimmed(reply))
            case .notAccepted where error.response == nil:
                throw MailTransportError.connectionLost(host: host)
            default:
                throw MailTransportError.refused(MailTransportError.trimmed(reply.isEmpty ? error.description : reply))
            }
        } catch let error as SMTPError {
            switch error {
            case .connectionFailed: throw MailTransportError.connectionLost(host: host)
            case .messageTooLarge: throw MailTransportError.refused("The message is too large.")
            case .invalidEmailAddress: throw MailTransportError.refused("An address is not valid.")
            default: throw MailTransportError.refused(MailTransportError.trimmed(error.description))
            }
        } catch {
            throw SwiftMailConnector.commandError(error, host: host)
        }
    }

    func close() async {
        try? await server.disconnect()
    }
}
