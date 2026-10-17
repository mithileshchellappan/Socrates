import Foundation
import Mail
import StudyCore

// A scripted mail server for tests and the offline end-to-end run (`tools/EndToEnd` m2-e2e):
// IMAP (Dovecot-like: UIDPLUS, MOVE, QRESYNC, SPECIAL-USE, IDLE) and SMTP submission in memory,
// reached through `FakeConnector`, the package's `MailConnector`. Never touches the network.


/// A scripted in-memory IMAP server (Dovecot-like: UIDPLUS, MOVE, QRESYNC, SPECIAL-USE, IDLE).
/// Sessions from `FakeConnector` share it; tests change it as "another client" or "the server"
/// would, and read `log` to see which commands the engine sent.
public actor FakeIMAPServer {
    public struct Message: Sendable {
        public var uid: UInt32
        public var raw: Data
        public var flags: Set<String>
        public var internalDate: Date
        public var modSeq: UInt64
        public var messageID: String
    }

    public struct Folder: Sendable {
        public var path: String
        public var attributes: Set<String>
        public var uidValidity: UInt32
        public var uidNext: UInt32 = 1
        public var messages: [Message] = []
        /// Expunged UIDs with the modseq of the expunge (QRESYNC VANISHED).
        public var expunged: [(uid: UInt32, modSeq: UInt64)] = []
    }

    public let password: String
    public var capabilities: Set<String> = ["IMAP4REV1", "IDLE", "UIDPLUS", "MOVE", "ENABLE", "QRESYNC", "CONDSTORE", "SPECIAL-USE", "AUTH=PLAIN"]
    public let delimiter = "/"
    public private(set) var folders: [Folder] = []
    private var modSeq: UInt64 = 10
    private var nextValidity: UInt32 = 1_000

    /// Commands as the engine sent them ("SELECT INBOX", "UID MOVE 3 Archive", …).
    public private(set) var log: [String] = []
    /// UIDs fetched with BODY.PEEK[], in order (per folder path).
    public private(set) var rawFetches: [(path: String, uid: UInt32)] = []
    public private(set) var loginAttempts = 0
    /// The next opens fail with this error (count, error).
    private var connectFailures: (count: Int, error: MailTransportError)?
    /// BODY.PEEK[] of these (path, UID) fails with the error, every time.
    private var rawFailures: [String: MailTransportError] = [:]
    /// Scripted BODYSTRUCTURE and sections (path, UID).
    private var structures: [String: (parts: [IMAPBodyPart], sections: [String: Data])] = [:]
    private var idleContinuations: [UUID: AsyncStream<IMAPIdleEvent>.Continuation] = [:]

    public init(password: String, folders: [(path: String, attributes: Set<String>)] = [("INBOX", []), ("Sent", ["\\Sent"])]) {
        self.password = password
        var validity: UInt32 = 1_000
        self.folders = folders.map { folder in
            validity += 1
            return Folder(path: folder.path, attributes: folder.attributes, uidValidity: validity)
        }
        self.nextValidity = validity
    }

    // MARK: - Test controls

    public func addFolder(_ path: String, attributes: Set<String> = []) {
        nextValidity += 1
        folders.append(Folder(path: path, attributes: attributes, uidValidity: nextValidity))
    }

    public func setCapabilities(_ capabilities: Set<String>) { self.capabilities = capabilities }

    public func failNextConnects(_ count: Int, with error: MailTransportError) { connectFailures = (count, error) }

    /// Every whole fetch of `uid` fails with `error` (nil: works again).
    public func failRawFetches(uid: UInt32, in path: String = "INBOX", with error: MailTransportError?) {
        rawFailures["\(path)/\(uid)"] = error
    }

    /// BODYSTRUCTURE of `uid` and the (transfer-encoded) contents of its sections.
    public func setStructure(_ parts: [IMAPBodyPart], sections: [String: Data], uid: UInt32, in path: String = "INBOX") {
        structures["\(path)/\(uid)"] = (parts, sections)
    }

    /// Delivers a message; returns its UID.
    @discardableResult
    public func deliver(_ raw: Data, to path: String = "INBOX", flags: Set<String> = [], date: Date) -> UInt32 {
        guard let index = folders.firstIndex(where: { $0.path == path }) else { return 0 }
        modSeq += 1
        let uid = folders[index].uidNext
        folders[index].uidNext += 1
        folders[index].messages.append(Message(uid: uid, raw: raw, flags: flags, internalDate: date, modSeq: modSeq, messageID: Self.messageID(of: raw)))
        return uid
    }

    /// Another client changed flags.
    public func setFlags(_ flags: Set<String>, uid: UInt32, in path: String = "INBOX") {
        guard let folder = folders.firstIndex(where: { $0.path == path }),
              let message = folders[folder].messages.firstIndex(where: { $0.uid == uid }) else { return }
        modSeq += 1
        folders[folder].messages[message].flags = flags
        folders[folder].messages[message].modSeq = modSeq
    }

    /// Another client expunged a message.
    public func expungeExternally(uid: UInt32, in path: String = "INBOX") {
        guard let folder = folders.firstIndex(where: { $0.path == path }) else { return }
        modSeq += 1
        folders[folder].messages.removeAll { $0.uid == uid }
        folders[folder].expunged.append((uid, modSeq))
    }

    /// The server renumbered the mailbox (new UIDVALIDITY, new UIDs), optionally dropping messages.
    public func renumber(_ path: String, dropping messageIDs: Set<String> = []) {
        guard let index = folders.firstIndex(where: { $0.path == path }) else { return }
        nextValidity += 1
        var folder = folders[index]
        folder.uidValidity = nextValidity
        folder.expunged = []
        var uid: UInt32 = 500
        folder.messages = folder.messages.filter { !messageIDs.contains($0.messageID) }.map { message in
            var copy = message
            uid += 1
            copy.uid = uid
            return copy
        }
        folder.uidNext = uid + 1
        folders[index] = folder
    }

    public func notifyIdle(_ event: IMAPIdleEvent) {
        for continuation in idleContinuations.values { continuation.yield(event) }
    }

    public var idleListeners: Int { idleContinuations.count }

    public func folder(_ path: String) -> Folder? { folders.first { $0.path == path } }

    public func flags(uid: UInt32, in path: String = "INBOX") -> Set<String>? {
        folder(path)?.messages.first { $0.uid == uid }?.flags
    }

    public func clearLog() {
        log = []
        rawFetches = []
    }

    // MARK: - Session plumbing

    public func login(_ credentials: MailCredentials) throws -> Bool {
        loginAttempts += 1
        if let failure = connectFailures, failure.count > 0 {
            connectFailures = failure.count > 1 ? (failure.count - 1, failure.error) : nil
            throw failure.error
        }
        guard credentials.password == password else { throw MailTransportError.authenticationFailed(host: "imap.example.org") }
        return true
    }

    private func index(_ path: String) throws -> Int {
        guard let index = folders.firstIndex(where: { $0.path == path }) else { throw MailTransportError.refused("NO Mailbox doesn't exist: \(path)") }
        return index
    }

    private func highestModSeq(_ folder: Folder) -> UInt64? {
        guard capabilities.contains("CONDSTORE") || capabilities.contains("QRESYNC") else { return nil }
        return max(folder.messages.map(\.modSeq).max() ?? 1, folder.expunged.map(\.modSeq).max() ?? 1)
    }

    private func selection(_ folder: Folder) -> IMAPSelection {
        IMAPSelection(uidValidity: folder.uidValidity, uidNext: folder.uidNext, messageCount: folder.messages.count, highestModSeq: highestModSeq(folder))
    }

    public func list() -> [IMAPFolder] {
        log.append("LIST")
        return folders.map { IMAPFolder(path: $0.path, delimiter: delimiter, attributes: $0.attributes) }
    }

    public func create(_ path: String) throws {
        log.append("CREATE \(path)")
        guard !folders.contains(where: { $0.path == path }) else { throw MailTransportError.refused("NO Mailbox exists") }
        addFolder(path)
    }

    public func select(_ path: String) throws -> IMAPSelection {
        log.append("SELECT \(path)")
        return selection(folders[try index(path)])
    }

    public func resync(_ path: String, validity: UInt32, modSeq: UInt64) throws -> IMAPResync {
        log.append("SELECT \(path) (QRESYNC (\(validity) \(modSeq)))")
        let folder = folders[try index(path)]
        guard folder.uidValidity == validity else { return IMAPResync(selection: selection(folder)) }
        var changed: [UInt32: Set<String>] = [:]
        for message in folder.messages where message.modSeq > modSeq { changed[message.uid] = message.flags }
        let vanished = Set(folder.expunged.filter { $0.modSeq > modSeq }.map(\.uid))
        return IMAPResync(selection: selection(folder), vanished: vanished, changedFlags: changed)
    }

    public func search(_ path: String?, _ criteria: IMAPSearch) throws -> [UInt32] {
        let folder = folders[try index(path ?? "")]
        let uids = folder.messages.map(\.uid)
        switch criteria {
        case .all:
            log.append("UID SEARCH ALL")
            return uids
        case .since(let day):
            log.append("UID SEARCH SINCE \(day)")
            let start = day.start(in: MailClock.berlin)
            return folder.messages.filter { $0.internalDate >= start }.map(\.uid)
        case .uids(let range):
            log.append("UID SEARCH UID \(range.lowerBound):\(range.upperBound == UInt32.max ? "*" : String(range.upperBound))")
            let inRange = uids.filter { range.contains($0) }
            // IMAP: "n:*" with n above every UID still matches the highest UID.
            if inRange.isEmpty, range.upperBound == UInt32.max, let highest = uids.max() { return [highest] }
            return inRange
        case .messageID(let id):
            log.append("UID SEARCH HEADER Message-ID \(id)")
            return folder.messages.filter { $0.messageID.contains(id) }.map(\.uid)
        }
    }

    public func summaries(_ path: String?, _ uids: [UInt32]) throws -> [IMAPSummary] {
        log.append("UID FETCH \(uids.map(String.init).joined(separator: ",")) (FLAGS INTERNALDATE RFC822.SIZE)")
        let folder = folders[try index(path ?? "")]
        return folder.messages.filter { uids.contains($0.uid) }.map {
            IMAPSummary(uid: $0.uid, flags: $0.flags, internalDate: $0.internalDate, size: $0.raw.count)
        }
    }

    public func fetchFlags(_ path: String?, _ uids: [UInt32]) throws -> [UInt32: Set<String>] {
        log.append("UID FETCH \(uids.count) (FLAGS)")
        let folder = folders[try index(path ?? "")]
        var result: [UInt32: Set<String>] = [:]
        for message in folder.messages where uids.contains(message.uid) { result[message.uid] = message.flags }
        return result
    }

    public func raw(_ path: String?, _ uid: UInt32) throws -> Data {
        let folder = folders[try index(path ?? "")]
        guard let message = folder.messages.first(where: { $0.uid == uid }) else { throw MailTransportError.refused("NO No such message") }
        rawFetches.append((folder.path, uid))
        if let failure = rawFailures["\(folder.path)/\(uid)"] { throw failure }
        return message.raw
    }

    public func structure(_ path: String?, _ uid: UInt32) throws -> [IMAPBodyPart] {
        let folder = folders[try index(path ?? "")]
        log.append("UID FETCH \(uid) (BODYSTRUCTURE)")
        guard let scripted = structures["\(folder.path)/\(uid)"] else { throw MailTransportError.refused("not scripted") }
        return scripted.parts
    }

    /// A section of a scripted structure, or "HEADER": the message's header block.
    public func section(_ path: String?, _ uid: UInt32, _ section: String) throws -> Data {
        let folder = folders[try index(path ?? "")]
        log.append("UID FETCH \(uid) (BODY.PEEK[\(section)])")
        if section.uppercased() == "HEADER" {
            guard let raw = folder.messages.first(where: { $0.uid == uid })?.raw else { throw MailTransportError.refused("NO No such message") }
            let bytes = [UInt8](raw)
            for index in bytes.indices where bytes[index] == 0x0A {
                let next = bytes.index(after: index)
                if next < bytes.endIndex, bytes[next] == 0x0A { return Data(bytes[...next]) }
                if next + 1 < bytes.endIndex, bytes[next] == 0x0D, bytes[next + 1] == 0x0A { return Data(bytes[...(next + 1)]) }
            }
            return raw
        }
        guard let data = structures["\(folder.path)/\(uid)"]?.sections[section] else { throw MailTransportError.refused("not scripted") }
        return data
    }

    public func store(_ path: String?, _ uids: [UInt32], _ flags: Set<String>, _ operation: IMAPStoreOperation) throws {
        log.append("UID STORE \(uids.map(String.init).joined(separator: ",")) \(operation == .add ? "+" : "-")FLAGS (\(flags.sorted().joined(separator: " ")))")
        let index = try index(path ?? "")
        modSeq += 1
        for position in folders[index].messages.indices where uids.contains(folders[index].messages[position].uid) {
            if operation == .add {
                folders[index].messages[position].flags.formUnion(flags)
            } else {
                folders[index].messages[position].flags.subtract(flags)
            }
            folders[index].messages[position].modSeq = modSeq
        }
    }

    public func copy(_ path: String?, _ uids: [UInt32], to destination: String, removing: Bool) throws -> IMAPCopyResult? {
        log.append("UID \(removing ? "MOVE" : "COPY") \(uids.map(String.init).joined(separator: ",")) \(destination)")
        if removing, !capabilities.contains("MOVE") { throw MailTransportError.missingCapability("MOVE") }
        let source = try index(path ?? "")
        let target = try index(destination)
        var mapping: [UInt32: UInt32] = [:]
        for message in folders[source].messages where uids.contains(message.uid) {
            modSeq += 1
            var copy = message
            copy.uid = folders[target].uidNext
            copy.modSeq = modSeq
            folders[target].uidNext += 1
            folders[target].messages.append(copy)
            mapping[message.uid] = copy.uid
        }
        if removing {
            modSeq += 1
            for uid in mapping.keys { folders[source].expunged.append((uid, modSeq)) }
            folders[source].messages.removeAll { mapping[$0.uid] != nil }
        }
        return capabilities.contains("UIDPLUS") ? IMAPCopyResult(uidValidity: folders[target].uidValidity, mapping: mapping) : nil
    }

    public func expunge(_ path: String?, _ uids: [UInt32]) throws {
        log.append("UID EXPUNGE \(uids.map(String.init).joined(separator: ","))")
        let index = try index(path ?? "")
        modSeq += 1
        let gone = folders[index].messages.filter { uids.contains($0.uid) && $0.flags.contains { $0.lowercased() == IMAPFlag.deleted.lowercased() } }.map(\.uid)
        for uid in gone { folders[index].expunged.append((uid, modSeq)) }
        folders[index].messages.removeAll { gone.contains($0.uid) }
    }

    public func append(_ data: Data, to path: String, flags: Set<String>, date: Date?) throws -> IMAPCopyResult? {
        log.append("APPEND \(path) (\(flags.sorted().joined(separator: " ")))")
        let index = try index(path)
        let uid = deliver(data, to: path, flags: flags, date: date ?? Date())
        return capabilities.contains("UIDPLUS") ? IMAPCopyResult(uidValidity: folders[index].uidValidity, mapping: [0: uid]) : nil
    }

    public func startIdle(_ id: UUID, _ path: String) throws -> AsyncStream<IMAPIdleEvent> {
        log.append("IDLE \(path)")
        _ = try index(path)
        let (stream, continuation) = AsyncStream<IMAPIdleEvent>.makeStream()
        idleContinuations[id] = continuation
        return stream
    }

    public func endIdle(_ id: UUID) {
        idleContinuations.removeValue(forKey: id)?.finish()
    }

    public static func messageID(of raw: Data) -> String {
        let text = String(decoding: raw.prefix(8_192), as: UTF8.self)
        for line in text.components(separatedBy: "\n") where line.lowercased().hasPrefix("message-id:") {
            return line.dropFirst("message-id:".count).trimmingCharacters(in: CharacterSet(charactersIn: " <>\r"))
        }
        return ""
    }
}

/// One logged-in connection to a `FakeIMAPServer`.
public actor FakeIMAPSession: IMAPSession {
    private let server: FakeIMAPServer
    private var selected: String?
    private let id = UUID()
    public private(set) var loggedOut = false

    public init(server: FakeIMAPServer) {
        self.server = server
    }

    public func capabilities() async -> Set<String> { await server.capabilities }

    public func enable(_ capabilities: [String]) async throws -> Set<String> {
        let offered = await server.capabilities
        return Set(capabilities.filter { offered.contains($0) })
    }

    public func listMailboxes() async throws -> [IMAPFolder] { await server.list() }

    public func createMailbox(_ path: String) async throws { try await server.create(path) }

    public func select(_ path: String) async throws -> IMAPSelection {
        let selection = try await server.select(path)
        selected = path
        return selection
    }

    public func select(_ path: String, resyncFrom uidValidity: UInt32, modSeq: UInt64) async throws -> IMAPResync {
        let result = try await server.resync(path, validity: uidValidity, modSeq: modSeq)
        selected = path
        return result
    }

    public func search(_ criteria: IMAPSearch) async throws -> [UInt32] { try await server.search(selected, criteria) }

    public func fetchSummaries(_ uids: [UInt32]) async throws -> [IMAPSummary] { try await server.summaries(selected, uids) }

    public func fetchFlags(_ uids: [UInt32]) async throws -> [UInt32: Set<String>] { try await server.fetchFlags(selected, uids) }

    public func fetchRaw(_ uid: UInt32) async throws -> Data { try await server.raw(selected, uid) }

    public func fetchStructure(_ uid: UInt32) async throws -> [IMAPBodyPart] { try await server.structure(selected, uid) }

    public func fetchSection(_ uid: UInt32, section: String) async throws -> Data { try await server.section(selected, uid, section) }

    public func store(_ uids: [UInt32], flags: Set<String>, _ operation: IMAPStoreOperation) async throws {
        try await server.store(selected, uids, flags, operation)
    }

    public func move(_ uids: [UInt32], to path: String) async throws -> IMAPCopyResult? {
        try await server.copy(selected, uids, to: path, removing: true)
    }

    public func copy(_ uids: [UInt32], to path: String) async throws -> IMAPCopyResult? {
        try await server.copy(selected, uids, to: path, removing: false)
    }

    public func expunge(_ uids: [UInt32]) async throws { try await server.expunge(selected, uids) }

    public func append(_ message: Data, to path: String, flags: Set<String>, date: Date?) async throws -> IMAPCopyResult? {
        try await server.append(message, to: path, flags: flags, date: date)
    }

    public func idle(_ path: String) async throws -> AsyncStream<IMAPIdleEvent> {
        selected = path
        return try await server.startIdle(id, path)
    }

    public func logout() async {
        loggedOut = true
        await server.endIdle(id)
    }
}

/// A scripted SMTP submission server: records every transaction.
public actor FakeSMTPServer {
    public struct Transaction: Sendable {
        public var endpoint: MailEndpoint
        public var from: String
        public var to: [String]
        public var data: Data
    }

    public let password: String
    public private(set) var transactions: [Transaction] = []
    public private(set) var opened: [MailEndpoint] = []
    public var unreachableHosts: Set<String> = []
    /// The next MAIL FROM … DATA is refused with this reply.
    public var refusal: String?
    /// The next MAIL FROM … DATA fails with this error after the message was handed over.
    public var failure: MailTransportError?

    public init(password: String) {
        self.password = password
    }

    public func setUnreachable(_ hosts: Set<String>) { unreachableHosts = hosts }
    public func setRefusal(_ reply: String?) { refusal = reply }
    public func setFailure(_ error: MailTransportError?) { failure = error }

    public func open(_ endpoint: MailEndpoint, _ credentials: MailCredentials) throws {
        opened.append(endpoint)
        if unreachableHosts.contains(endpoint.host) { throw MailTransportError.unreachable(host: endpoint.host) }
        guard credentials.password == password else { throw MailTransportError.authenticationFailed(host: endpoint.host) }
    }

    public func send(_ endpoint: MailEndpoint, _ data: Data, from: String, to: [String]) throws {
        if let refusal {
            self.refusal = nil
            throw MailTransportError.refused(refusal)
        }
        transactions.append(Transaction(endpoint: endpoint, from: from, to: to, data: data))
        if let failure {
            self.failure = nil
            throw failure
        }
    }
}

public struct FakeSMTPSession: SMTPSession {
    public let server: FakeSMTPServer
    public let endpoint: MailEndpoint

    public init(server: FakeSMTPServer, endpoint: MailEndpoint) {
        self.server = server
        self.endpoint = endpoint
    }

    public func send(_ message: Data, from sender: String, to recipients: [String]) async throws {
        try await server.send(endpoint, message, from: sender, to: recipients)
    }

    public func close() async {}
}

/// Opens fake sessions; never touches the network.
public struct FakeConnector: MailConnector {
    public let imap: FakeIMAPServer
    public let smtp: FakeSMTPServer

    public init(imap: FakeIMAPServer, smtp: FakeSMTPServer) {
        self.imap = imap
        self.smtp = smtp
    }

    public func openIMAP(_ endpoint: MailEndpoint, credentials: MailCredentials) async throws -> any IMAPSession {
        _ = try await imap.login(credentials)
        return FakeIMAPSession(server: imap)
    }

    public func openSMTP(_ endpoint: MailEndpoint, credentials: MailCredentials) async throws -> any SMTPSession {
        try await smtp.open(endpoint, credentials)
        return FakeSMTPSession(server: smtp, endpoint: endpoint)
    }
}

