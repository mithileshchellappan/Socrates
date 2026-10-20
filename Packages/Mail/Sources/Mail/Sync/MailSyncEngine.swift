import Foundation
import Network
import StudyCore
#if os(macOS)
import CoreServices
#endif

/// Keeps the uni mailboxes (INBOX, Sent, Archive) in the library (docs/plan-m2.md §3).
///
/// A pass logs in, lists mailboxes (roles from SPECIAL-USE, else English/German names; Archive is
/// created on first use), and per mailbox: pushes local flag changes (local wins) and moves,
/// applies the server's flag changes and expunges (QRESYNC when offered, else UID FETCH FLAGS +
/// a UID SEARCH diff), fetches the window (`sync_since`, default 30 days) newest first and new
/// mail in batches of 25, each batch one transaction with its checkpoint. A UIDVALIDITY change
/// re-attaches rows by Message-ID. INBOX is watched with IDLE; everything is polled every 5
/// minutes. Network errors back off from 2 s to 5 min; an authentication failure stops the
/// engine after one attempt until `retry()` (repeated failed logins can lock a uni account).
/// While the Mac has no network (Wi-Fi roaming, sleep and dark wake) no pass runs; one runs a
/// moment after it is back. A short outage is not recorded on the account (its `last_error`),
/// from the third failed pass in a row it is. A command the server refuses (NO/BAD) costs only
/// its mailbox, move, flag change, sent copy or message, never the whole pass; a skipped mailbox or
/// an undone move is still that pass's error (`last_error`, the back-off), never a success.
///
/// The password is read from `services.secrets` right before each login and never kept.
public actor MailSyncEngine {
    /// What the engine is doing.
    public enum State: Hashable, Sendable {
        case stopped
        case running
        /// The server rejected the login (or no password is saved); waits for `retry()`.
        case authenticationFailed
    }

    /// Which mailboxes a pass syncs.
    enum Scope: Hashable, Sendable {
        case all
        case roles(Set<MailboxRole>)

        func union(_ other: Scope) -> Scope {
            switch (self, other) {
            case (.all, _), (_, .all): .all
            case (.roles(let left), .roles(let right)): .roles(left.union(right))
            }
        }

        func includes(_ role: MailboxRole?) -> Bool {
            switch self {
            case .all: true
            case .roles(let roles): role.map(roles.contains) ?? false
            }
        }

        static let inbox = Scope.roles([.inbox])
    }

    private let services: StudyServices
    private let connector: any MailConnector
    private let onNewMail: @Sendable ([MailMessage.ID]) async -> Void
    private let configuration: MailSyncConfiguration
    private let clock: MailClock
    private let faults: MailSyncFaults
    private let store: MailSyncStore

    public private(set) var state: State = .stopped
    /// Consecutive failed passes (network trouble); drives the back-off.
    private(set) var consecutiveFailures = 0
    private var generation = 0
    private var pollTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var idleSession: (any IMAPSession)?
    private var idleSessionToken: UUID?
    private var idleBackoffTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    private var passRunning = false
    private var pendingScope: Scope?
    private var passWaiters: [CheckedContinuation<Void, Never>] = []
    private var pollWaiter: (token: UUID, continuation: CheckedContinuation<Bool, Never>)?
    /// Messages whose download failed, per mailbox: UID → failed attempts. They are fetched after
    /// the others and in parts; after `configuration.fetchAttempts` their headers are stored.
    private var fetchFailures: [Mailbox.ID: [UInt32: Int]] = [:]
    /// The network path is satisfied (`NWPathMonitor`); no pass runs without it.
    private var isOnline = true
    private var pathTask: Task<Void, Never>?
    /// What the pass in progress is doing, for the log ("select inbox", "new mail").
    private var step = "login"
    /// Sent copies the server refused to take this run (tried again after the next launch).
    private var refusedSentCopies: Set<MailDraft.ID> = []
    /// What the server refused in the pass in progress (a mailbox it skipped, moves it undid), in
    /// the student's words: such a pass is recorded as this error, never as a success.
    private var refusals: [String] = []
    /// Mailboxes the pass in progress skipped after a refusal.
    private var skippedMailboxes = 0

    public init(
        services: StudyServices,
        connector: any MailConnector = SwiftMailConnector(),
        onNewMail: @escaping @Sendable ([MailMessage.ID]) async -> Void = { _ in },
        configuration: MailSyncConfiguration = MailSyncConfiguration(),
        clock: MailClock = MailClock()
    ) {
        self.init(services: services, connector: connector, onNewMail: onNewMail, configuration: configuration, clock: clock, faults: MailSyncFaults())
    }

    init(
        services: StudyServices,
        connector: any MailConnector,
        onNewMail: @escaping @Sendable ([MailMessage.ID]) async -> Void,
        configuration: MailSyncConfiguration,
        clock: MailClock,
        faults: MailSyncFaults
    ) {
        self.services = services
        self.connector = connector
        self.onNewMail = onNewMail
        self.configuration = configuration
        self.clock = clock
        self.faults = faults
        self.store = MailSyncStore(services: services, now: clock.now)
    }

    private var records: RecordStore { RecordStore(database: services.database, now: clock.now) }

    // MARK: - Lifecycle

    /// Discovers mailboxes, syncs, and starts IDLE on INBOX and the poll timer. Returns after
    /// the first pass. Does nothing without an enabled account, or while running.
    public func start() async {
        guard state == .stopped else { return }
        state = .running
        generation += 1
        let current = generation
        watchNetwork()
        await performPass(.all)
        guard state == .running, generation == current else { return }
        pollTask = Task { [weak self] in await self?.pollLoop(generation: current) }
        if configuration.usesIdle {
            idleTask = Task { [weak self] in await self?.idleLoop(generation: current) }
        }
    }

    /// Stops polling and IDLE. A pass in progress finishes its current batch.
    public func stop() async {
        state = .stopped
        await tearDownLoops()
    }

    /// One pass over every synced mailbox now (Get Mail; the app also calls it after waking
    /// from sleep). Also restarts a waiting IDLE connection at once.
    public func syncNow() async {
        guard state == .running else { return }
        idleBackoffTask?.cancel()
        await performPass(.all)
    }

    /// Starts again after an authentication failure (the account was saved again) or a stop.
    public func retry() async {
        state = .stopped
        await tearDownLoops()
        consecutiveFailures = 0
        await start()
    }

    private func tearDownLoops() async {
        generation += 1
        pollTask?.cancel()
        idleTask?.cancel()
        pushTask?.cancel()
        idleBackoffTask?.cancel()
        pathTask?.cancel()
        pollTask = nil
        idleTask = nil
        pushTask = nil
        pathTask = nil
        isOnline = true
        resumePoll(token: nil, timedOut: false)
        if let session = idleSession {
            idleSession = nil
            idleSessionToken = nil
            await session.logout()
        }
    }

    private func haltAfterAuthenticationFailure() async {
        state = .authenticationFailed
        await tearDownLoops()
    }

    // MARK: - Network

    /// Follows the network path while the engine runs: passes wait while there is none (no failure
    /// counted, nothing recorded), and one runs a moment after it is back.
    private func watchNetwork() {
        guard pathTask == nil else { return }
        pathTask = Task { [weak self] in
            for await path in NWPathMonitor() {
                guard !Task.isCancelled else { return }
                await self?.pathChanged(online: path.status == .satisfied)
            }
        }
    }

    private func pathChanged(online: Bool) async {
        guard online != isOnline else { return }
        isOnline = online
        guard online else {
            Log.mail.notice("Mail sync waits for the network")
            return
        }
        guard state == .running else { return }
        // DHCP, DNS and an 802.1X Wi-Fi need a moment after the path comes back.
        try? await clock.sleep(.seconds(3))
        guard isOnline, state == .running else { return }
        Log.mail.notice("The network is back; syncing mail")
        idleBackoffTask?.cancel()
        await performPass(.all)
    }

    // MARK: - Local changes

    /// Marks messages read or unread here at once; the server follows shortly.
    public func setSeen(_ ids: [MailMessage.ID], _ seen: Bool) async throws {
        try await MailRepository(store: records).setSeen(ids, seen, at: clock.now())
        schedulePush()
    }

    public func setFlagged(_ id: MailMessage.ID, _ flagged: Bool) async throws {
        try await MailRepository(store: records).setFlagged(id, flagged, at: clock.now())
        schedulePush()
    }

    /// Moves a message to the Archive mailbox (created on the server on first use). The row
    /// leaves the Inbox at once (`move_to_mailbox_id`); the server move follows.
    public func archive(_ id: MailMessage.ID) async throws {
        guard let message = try await MailRepository(store: records).message(id) else { throw MailSyncError.messageNotFound }
        let archive = try await store.archiveMailbox(accountID: message.accountID)
        guard message.mailboxID != archive.id else { return }
        let stamp = clock.now()
        let archiveID = archive.id
        try await services.database.write { db in
            try MailMessage.find(id)
                .update { $0.moveToMailboxID = Mailbox.ID?.some(archiveID); $0.updatedAt = stamp }
                .execute(db)
        }
        schedulePush()
    }

    private func schedulePush() {
        guard state == .running, pushTask == nil else { return }
        let clock = clock
        let delay = configuration.pushDelay
        pushTask = Task { [weak self] in
            do { try await clock.sleep(delay) } catch { return }
            await self?.runScheduledPush()
        }
    }

    private func runScheduledPush() async {
        pushTask = nil
        guard state == .running else { return }
        guard let account = try? await MailAccountRepository(store: records).current(),
              let pending = try? await store.mailboxesWithPendingChanges(accountID: account.id), !pending.isEmpty else { return }
        let mailboxes = (try? await MailboxRepository(store: records).mailboxes(accountID: account.id)) ?? []
        let roles = Set(mailboxes.filter { pending.contains($0.id) }.compactMap(\.role))
        guard !roles.isEmpty else { return }
        await performPass(.roles(roles))
    }

    // MARK: - Attachments

    /// A local file for an attachment, decoded from the raw message (or fetched from the server
    /// for messages too large to keep) into the BlobStore on first use. The returned file has the
    /// attachment's own name (Quick Look, drag to a lecture, smart import).
    public func attachmentFile(_ id: MailAttachment.ID) async throws -> URL {
        guard let attachment = try await records.fetch(MailAttachment.self, id: id) else { throw MailSyncError.attachmentNotFound }
        var blob = attachment.blob
        if blob.map({ !services.blobs.contains($0) }) ?? true {
            guard let message = try await records.fetch(MailMessage.self, id: attachment.mailMessageID) else {
                throw MailSyncError.messageNotFound
            }
            let data: Data
            if let raw = message.raw, services.blobs.contains(raw) {
                data = try MIMEParser.partData(try services.blobs.data(for: raw), part: attachment.part)
            } else {
                data = try await fetchPart(attachment.part, of: message)
            }
            let ext = (attachment.fileName as NSString).pathExtension
            let ref = try services.blobs.put(data, fileExtension: ext)
            let stamp = clock.now()
            try await services.database.write { db in
                try MailAttachment.find(id)
                    .update {
                        $0.blobSHA256 = ref.sha256
                        $0.blobPath = ref.relativePath
                        $0.size = data.count
                        $0.updatedAt = stamp
                    }
                    .execute(db)
            }
            blob = ref
        }
        guard let blob else { throw MailSyncError.attachmentNotFound }
        return try namedFile(for: blob, fileName: attachment.fileName, attachmentID: id)
    }

    private func fetchPart(_ part: String, of message: MailMessage) async throws -> Data {
        guard let uid = message.uid.flatMap({ UInt32(exactly: $0) }),
              let mailbox = try await store.mailbox(message.mailboxID),
              let account = try await records.fetch(MailAccount.self, id: message.accountID) else {
            throw MailSyncError.attachmentNotFound
        }
        let session = try await openSession(account)
        do {
            _ = try await session.select(mailbox.path)
            let structure = try await session.fetchStructure(uid)
            let encoded = try await session.fetchSection(uid, section: part)
            await session.logout()
            let encoding = structure.first { $0.section == part }?.encoding
            return Data(TransferEncoding.decode(Array(encoded)[...], encoding: encoding))
        } catch {
            await session.logout()
            throw error
        }
    }

    /// `<caches>/MailAttachments/<id>/<file name>`, a copy (an APFS clone) of the blob marked as
    /// a mail attachment from the internet, so Gatekeeper asks before anything in it runs (the
    /// blob itself stays unmarked).
    private func namedFile(for blob: BlobRef, fileName: String, attachmentID: MailAttachment.ID) throws -> URL {
        let folder = services.paths.caches
            .appending(path: "MailAttachments", directoryHint: .isDirectory)
            .appending(path: attachmentID.uuidString.lowercased(), directoryHint: .isDirectory)
        let name = MIMEParser.sanitizedFileName(fileName, mimeType: "application/octet-stream")
        var target = folder.appending(path: name, directoryHint: .notDirectory)
        let manager = FileManager.default
        let source = services.blobs.url(for: blob)
        if manager.fileExists(atPath: target.path(percentEncoded: false)) {
            let size = (try? manager.attributesOfItem(atPath: target.path(percentEncoded: false))[.size] as? Int) ?? -1
            let blobSize = (try? manager.attributesOfItem(atPath: source.path(percentEncoded: false))[.size] as? Int) ?? -2
            if size == blobSize, Self.isQuarantined(target) { return target }
            try manager.removeItem(at: target)
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try manager.copyItem(at: source, to: target)
        try Self.quarantine(&target)
        return target
    }

    /// Marks a file as an email attachment from the internet (`com.apple.quarantine`).
    static func quarantine(_ url: inout URL) throws {
        #if os(macOS)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Socrates",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeEmailAttachment as String,
        ]
        try url.setResourceValues(values)
        #endif
    }

    static func isQuarantined(_ url: URL) -> Bool {
        #if os(macOS)
        return (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties) != nil
        #else
        return true
        #endif
    }

    // MARK: - Loops

    private func pollLoop(generation current: Int) async {
        while !Task.isCancelled, state == .running, generation == current {
            let delay = consecutiveFailures > 0 ? configuration.backoff(after: consecutiveFailures) : configuration.pollInterval
            let timedOut = await waitForPoll(timeout: delay)
            guard !Task.isCancelled, state == .running, generation == current else { return }
            guard timedOut else { continue }
            await performPass(.all)
        }
    }

    /// Waits for `timeout`, or until a pass changed the failure state (returns false then).
    private func waitForPoll(timeout: Duration) async -> Bool {
        let token = UUID()
        let clock = clock
        let timer = Task { [weak self] in
            do { try await clock.sleep(timeout) } catch { return }
            await self?.resumePoll(token: token, timedOut: true)
        }
        let timedOut = await withCheckedContinuation { continuation in
            pollWaiter = (token, continuation)
        }
        timer.cancel()
        return timedOut
    }

    private func resumePoll(token: UUID?, timedOut: Bool) {
        guard let waiter = pollWaiter, token == nil || waiter.token == token else { return }
        pollWaiter = nil
        waiter.continuation.resume(returning: timedOut)
    }

    private func idleLoop(generation current: Int) async {
        var failures = 0
        var reconnecting = false
        while !Task.isCancelled, state == .running, generation == current {
            do {
                guard let account = try await MailAccountRepository(store: records).current() else { return }
                let session = try await openSession(account)
                guard state == .running, generation == current, !Task.isCancelled else {
                    await session.logout()
                    return
                }
                guard await session.capabilities().contains("IDLE") else {
                    // No IDLE: INBOX is polled with the rest.
                    await session.logout()
                    return
                }
                let inbox = try await MailboxRepository(store: records).mailbox(role: .inbox, accountID: account.id)?.path ?? "INBOX"
                let events = try await session.idle(inbox)
                let token = UUID()
                idleSession = session
                idleSessionToken = token
                failures = 0
                if reconnecting {
                    // Catch up on what arrived while the connection was down.
                    await performPass(.inbox)
                }
                reconnecting = true
                for await event in events {
                    guard state == .running, generation == current else { break }
                    if event.isChange { await performPass(.inbox) }
                    if event == .bye { break }
                }
                if idleSessionToken == token {
                    idleSession = nil
                    idleSessionToken = nil
                }
                await session.logout()
                guard state == .running, generation == current, !Task.isCancelled else { return }
                Log.mail.info("IDLE connection ended; reconnecting")
                failures += 1
            } catch let error as MailTransportError where error.isAuthentication || error.isLoginUnsupported {
                await recordFailure(error)
                await haltAfterAuthenticationFailure()
                return
            } catch {
                failures += 1
                reconnecting = true
                Log.mail.info("IDLE failed (\(String(describing: type(of: error)), privacy: .public)); backing off")
            }
            guard state == .running, generation == current, !Task.isCancelled else { return }
            let delay = configuration.backoff(after: max(failures, 1))
            let clock = clock
            let sleeper = Task { _ = try? await clock.sleep(delay) }
            idleBackoffTask = sleeper
            await sleeper.value
            idleBackoffTask = nil
        }
    }

    // MARK: - Passes

    /// Runs a pass, or joins the one in progress (its scope is added to a follow-up pass).
    func performPass(_ scope: Scope) async {
        if passRunning {
            pendingScope = pendingScope.map { $0.union(scope) } ?? scope
            await withCheckedContinuation { passWaiters.append($0) }
            return
        }
        passRunning = true
        var next: Scope? = scope
        while let current = next, state == .running {
            pendingScope = nil
            await runPass(current)
            next = pendingScope
        }
        pendingScope = nil
        passRunning = false
        let waiters = passWaiters
        passWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func runPass(_ scope: Scope) async {
        // No network (roaming, sleep, dark wake): nothing to try, nothing to count.
        guard isOnline else { return }
        let accounts = MailAccountRepository(store: records)
        let account: MailAccount
        do {
            guard let current = try await accounts.current() else {
                // No (enabled) account: nothing to sync until the app calls retry().
                state = .stopped
                await tearDownLoops()
                return
            }
            account = current
        } catch {
            Log.mail.error("Mail account could not be read: \(Self.kind(error), privacy: .public)")
            return
        }
        step = "login"
        refusals = []
        skippedMailboxes = 0
        do {
            try await sync(account, scope: scope)
            if let refusal = refusals.first {
                // A mailbox or a move the server refused: the student sees why (the reason in the
                // account's error, no fresh sync time). A skipped mailbox backs the poll off as a
                // failed pass does; a refused move is never tried again, so it does not.
                consecutiveFailures = skippedMailboxes > 0 ? consecutiveFailures + 1 : 0
                let failures = consecutiveFailures
                let count = refusals.count
                Log.mail.error("Mail sync incomplete: \(count, privacy: .public) refused (\(failures, privacy: .public) in a row)")
                _ = try? await accounts.recordSync(account.id, at: clock.now(), error: refusal)
                resumePoll(token: nil, timedOut: false)
                return
            }
            if consecutiveFailures > 0 {
                consecutiveFailures = 0
                resumePoll(token: nil, timedOut: false)
            }
            _ = try? await accounts.recordSync(account.id, at: clock.now(), error: nil)
        } catch let error as MailTransportError where error.isAuthentication || error.isLoginUnsupported {
            Log.mail.error("Mail login refused (\(error.kind, privacy: .public)); sync stops until the account is saved again")
            _ = try? await accounts.recordSync(account.id, at: clock.now(), error: error.localizedDescription)
            await haltAfterAuthenticationFailure()
        } catch {
            consecutiveFailures += 1
            let failures = consecutiveFailures
            let kind = Self.kind(error)
            let failedAt = self.step
            let transient = Self.isTransient(error)
            if transient {
                Log.mail.notice("Mail sync: \(kind, privacy: .public) at \(failedAt, privacy: .public) (\(failures, privacy: .public) in a row)")
            } else {
                Log.mail.error("Mail sync failed: \(kind, privacy: .public) at \(failedAt, privacy: .public) (\(failures, privacy: .public) in a row)")
            }
            // A short outage is not the student's business; from the third failed pass it is.
            if !transient || failures >= 3 {
                _ = try? await accounts.recordSync(account.id, at: clock.now(), error: Self.readable(error))
            }
            resumePoll(token: nil, timedOut: false)
        }
    }

    private func recordFailure(_ error: any Error) async {
        guard let account = try? await MailAccountRepository(store: records).current() else { return }
        _ = try? await MailAccountRepository(store: records).recordSync(account.id, at: clock.now(), error: Self.readable(error))
    }

    static func readable(_ error: any Error) -> String {
        if let error = error as? MailTransportError { return error.localizedDescription }
        if let error = error as? MailSyncError { return error.localizedDescription }
        return "Mail could not be synced."
    }

    /// What failed, for the log: the error's case or type, never its host, reply or content.
    static func kind(_ error: any Error) -> String {
        if let error = error as? MailTransportError { return error.kind }
        if let error = error as? MailSyncError { return "\(error)" }
        if error is CancellationError { return "cancelled" }
        return String(reflecting: type(of: error))
    }

    /// Network trouble worth waiting out (the poll's back-off) rather than reporting at once.
    static func isTransient(_ error: any Error) -> Bool {
        (error as? MailTransportError)?.isTransient ?? false
    }

    private func openSession(_ account: MailAccount) async throws -> any IMAPSession {
        let password = try services.secrets.secret(for: account.passwordKey)
        guard let password, !password.isEmpty else { throw MailTransportError.noPassword }
        return try await connector.openIMAP(account.imapEndpoint, credentials: MailCredentials(username: account.username, password: password))
    }

    private func sync(_ account: MailAccount, scope: Scope) async throws {
        let session = try await openSession(account)
        do {
            try await sync(account, scope: scope, session: session)
            await session.logout()
        } catch {
            await session.logout()
            throw error
        }
    }

    private func sync(_ account: MailAccount, scope: Scope, session: any IMAPSession) async throws {
        let passStart = clock.now()
        let capabilities = await session.capabilities()
        var qresync = false
        if capabilities.contains("QRESYNC"), capabilities.contains("ENABLE") {
            qresync = ((try? await session.enable(["QRESYNC"])) ?? []).contains("QRESYNC")
        }

        step = "list"
        var folders = try await session.listMailboxes()
        var mailboxes = try await store.applyFolders(folders, accountID: account.id)
        let serverPaths = Set(folders.map(\.path))
        var created = false
        step = "create"
        for mailbox in mailboxes where mailbox.isSynced && !serverPaths.contains(mailbox.path) {
            Log.mail.info("Creating the \(mailbox.role?.rawValue ?? "", privacy: .public) mailbox on the server")
            do {
                try await session.createMailbox(mailbox.path)
                created = true
            } catch let error as MailTransportError where error.isRefusal {
                // That mailbox is skipped below (its SELECT is refused); the others still sync.
                Log.mail.error("The server refused to create the \(mailbox.role?.rawValue ?? "", privacy: .public) mailbox")
            }
        }
        if created {
            step = "list"
            folders = try await session.listMailboxes()
            mailboxes = try await store.applyFolders(folders, accountID: account.id)
        }

        let byID = Dictionary(mailboxes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let order: [MailboxRole] = [.inbox, .sent, .archive]
        let synced = mailboxes
            .filter { $0.isSynced && scope.includes($0.role) }
            .sorted { (order.firstIndex(of: $0.role ?? .inbox) ?? 9) < (order.firstIndex(of: $1.role ?? .inbox) ?? 9) }
        for mailbox in synced {
            do {
                try await syncMailbox(mailbox, account: account, session: session, qresync: qresync, mailboxes: byID, passStart: passStart)
            } catch let error as MailTransportError where error.isRefusal {
                // The server refused a command in this mailbox (the session is still good): the
                // other mailboxes sync; this one is tried again next pass, and the pass reports it.
                let role = mailbox.role?.rawValue ?? "a mailbox"
                let failedAt = self.step
                Log.mail.error("Mail sync skipped \(role, privacy: .public): refused at \(failedAt, privacy: .public)")
                let name = mailbox.role == .inbox ? "Inbox" : mailbox.name
                skippedMailboxes += 1
                refusals.append("\(name) couldn’t be synced. \(error.localizedDescription)")
            }
        }
        if scope == .all {
            step = "sent copies"
            try await saveSentCopies(account: account, session: session, mailboxes: mailboxes)
            await reparseOutdated()
        }
    }

    // MARK: - One mailbox

    private func syncMailbox(
        _ initial: Mailbox, account: MailAccount, session: any IMAPSession, qresync: Bool, mailboxes: [Mailbox.ID: Mailbox],
        passStart: Date
    ) async throws {
        var mailbox = initial
        var resync: IMAPResync?
        let selection: IMAPSelection
        step = "select \(mailbox.role?.rawValue ?? "mailbox")"
        if qresync, let validity = mailbox.uidValidity, let modSeq = mailbox.highestModSeq, modSeq > 0,
           let validity32 = UInt32(exactly: validity) {
            let result = try await session.select(mailbox.path, resyncFrom: validity32, modSeq: UInt64(modSeq))
            selection = result.selection
            resync = result
        } else {
            selection = try await session.select(mailbox.path)
        }

        // After a UIDVALIDITY change the window is fetched again from where the old one began, so
        // every stored row can be found again by Message-ID.
        var windowFloor: CalendarDay?
        if let stored = mailbox.uidValidity, stored != Int64(selection.uidValidity) {
            Log.mail.info("UIDVALIDITY of \(mailbox.role?.rawValue ?? "a mailbox", privacy: .public) changed; re-attaching by Message-ID")
            windowFloor = mailbox.syncedSince
            mailbox = try await store.resetUIDValidity(mailbox, to: selection.uidValidity)
            fetchFailures[mailbox.id] = nil
            resync = nil
        }
        let hadMessages = mailbox.lastUID > 0

        // Local changes first: the student's flags win, moves leave this mailbox.
        step = "flags"
        let pendingFlags = try await store.pendingFlags(mailbox.id)
        do {
            try await FlagState.push(pendingFlags, session: session)
        } catch let error as MailTransportError where error.isRefusal {
            // Refused flag changes are dropped (the server's flags win), never retried each pass.
            Log.mail.error("The server refused \(pendingFlags.count, privacy: .public) flag changes")
        }
        try await store.markFlagsPushed(pendingFlags)
        step = "moves"
        try await pushMoves(from: mailbox, session: session, mailboxes: mailboxes)

        // The server's changes since the checkpoint.
        step = "changes"
        if let resync {
            var flags = resync.changedFlags
            for row in pendingFlags { if let uid = row.uid.flatMap({ UInt32(exactly: $0) }) { flags[uid] = nil } }
            try await store.applyServerChanges(mailbox.id, vanished: resync.vanished, flags: flags, highestModSeq: nil)
        } else if hadMessages {
            let stored = try await store.storedUIDs(mailbox.id)
            if let low = stored.min(), let high = stored.max() {
                let existing = Set(try await session.search(.uids(low...high)))
                let vanished = stored.subtracting(existing)
                let flags = try await session.fetchFlags(stored.intersection(existing).sorted())
                try await store.applyServerChanges(mailbox.id, vanished: vanished, flags: flags, highestModSeq: nil)
            }
        }

        // The window, newest first, then new mail, oldest first.
        var since = account.syncSince ?? CalendarDay(clock.now(), in: MailClock.zone).adding(days: -configuration.defaultWindowDays)
        if let windowFloor, windowFloor < since { since = windowFloor }
        var run = FetchRun()
        var windowComplete = mailbox.syncedSince.map { $0 <= since } ?? false
        if !windowComplete {
            step = "window"
            let window = try await session.search(.since(since))
            let stored = try await store.storedUIDs(mailbox.id)
            let missing = window.filter { !stored.contains($0) }.sorted(by: >)
            try await fetch(missing, into: mailbox, account: account, session: session, selection: selection, run: &run)
            // A message that could not be fetched keeps the window open: the next pass tries it again.
            if run.skipped.isEmpty {
                try await store.completeWindow(mailbox.id, since: since, uidNext: selection.uidNext)
                windowComplete = true
            }
        }
        let lastUID = UInt32(clamping: (try await store.mailbox(mailbox.id))?.lastUID ?? 0)
        if lastUID < UInt32.max {
            step = "new mail"
            let stored = try await store.storedUIDs(mailbox.id)
            let fresh = try await session.search(.uids((lastUID + 1)...UInt32.max))
                .filter { $0 > lastUID && !stored.contains($0) }
                .sorted()
            try await fetch(fresh, into: mailbox, account: account, session: session, selection: selection, run: &run)
        }

        // Rows without a UID: find them again by Message-ID; what the server no longer has goes.
        if windowComplete {
            step = "reattach"
            try await reattachDetached(in: mailbox, account: account, session: session, selection: selection, run: &run)
            let deleted = try await store.deleteLeftovers(mailbox.id, before: passStart)
            if deleted > 0 { Log.mail.info("Removed \(deleted, privacy: .public) messages the server no longer has") }
        }

        _ = try await store.finishMailbox(
            mailbox.id, selection: selection, highestModSeq: selection.highestModSeq, syncedSince: nil, at: clock.now()
        )
    }

    private func pushMoves(from mailbox: Mailbox, session: any IMAPSession, mailboxes: [Mailbox.ID: Mailbox]) async throws {
        let moves = try await store.pendingMoves(mailbox.id)
        guard !moves.isEmpty else { return }
        let canMove = await session.capabilities().contains("MOVE")
        let grouped = Dictionary(grouping: moves) { $0.moveToMailboxID }
        for (destinationID, rows) in grouped {
            guard let destinationID, let destination = mailboxes[destinationID] else { continue }
            if destination.id == mailbox.id {
                for row in rows { try await store.recordMove(row.id, to: mailbox.id, uid: row.uid.flatMap { UInt32(exactly: $0) }) }
                continue
            }
            let uids = rows.compactMap { $0.uid.flatMap { UInt32(exactly: $0) } }.sorted()
            let result: IMAPCopyResult?
            do {
                if canMove {
                    result = try await session.move(uids, to: destination.path)
                } else {
                    result = try await session.copy(uids, to: destination.path)
                    try await session.store(uids, flags: [IMAPFlag.deleted], .add)
                    try await session.expunge(uids)
                }
            } catch let error as MailTransportError where error.isRefusal {
                // The messages stay where the server has them (never retried on every pass).
                Log.mail.error("The server refused to move \(rows.count, privacy: .public) messages; they stay where they are")
                try await store.cancelMoves(rows.map(\.id))
                let what = rows.count == 1 ? "A message" : "\(rows.count) messages"
                refusals.append("\(what) couldn’t be moved. \(error.localizedDescription)")
                continue
            }
            let validityMatches = result.map { copy in destination.uidValidity.map { $0 == Int64(copy.uidValidity) } ?? true } ?? false
            for row in rows {
                let source = row.uid.flatMap { UInt32(exactly: $0) }
                let newUID = validityMatches ? source.flatMap { result?.mapping[$0] } : nil
                try await store.recordMove(row.id, to: destination.id, uid: newUID)
            }
            Log.mail.info("Moved \(rows.count, privacy: .public) messages (\(canMove ? "MOVE" : "COPY", privacy: .public))")
        }
    }

    /// Detached rows (no UID) looked up by Message-ID; found ones are fetched and re-attached.
    private func reattachDetached(
        in mailbox: Mailbox, account: MailAccount, session: any IMAPSession, selection: IMAPSelection, run: inout FetchRun
    ) async throws {
        let detached = try await store.detachedRows(mailbox.id)
        guard !detached.isEmpty else { return }
        let stored = try await store.storedUIDs(mailbox.id)
        var found: Set<UInt32> = []
        for rfcID in Set(detached.map(\.rfcMessageID)) where !rfcID.isEmpty {
            let uids = try await session.search(.messageID(rfcID))
            found.formUnion(uids.filter { !stored.contains($0) })
        }
        try await fetch(found.sorted(), into: mailbox, account: account, session: session, selection: selection, run: &run)
    }

    // MARK: - Fetching

    /// One mailbox's fetching in a pass: the batch counter, and the UIDs that failed (not tried
    /// again in this pass; the checkpoint stays below them so a later pass does).
    private struct FetchRun {
        var batchIndex = 0
        var skipped: Set<UInt32> = []
    }

    /// Fetches and stores `uids` in batches, each one transaction with its checkpoint. A message
    /// that fails is skipped and the rest are still stored: one the server refuses at once, on a
    /// lost connection after the batch so far is stored. Messages that failed before come last
    /// and in parts; after `configuration.fetchAttempts` failures their headers are stored.
    private func fetch(
        _ uids: [UInt32], into mailbox: Mailbox, account: MailAccount, session: any IMAPSession, selection: IMAPSelection,
        run: inout FetchRun
    ) async throws {
        let failed = fetchFailures[mailbox.id] ?? [:]
        let wanted = uids.filter { !run.skipped.contains($0) }
        let ordered = wanted.filter { failed[$0] == nil } + wanted.filter { failed[$0] != nil }
        var start = 0
        while start < ordered.count {
            let chunk = Array(ordered[start..<min(start + configuration.batchSize, ordered.count)])
            start += configuration.batchSize
            let summaries: [IMAPSummary]
            do {
                summaries = try await session.fetchSummaries(chunk)
            } catch let error as MailTransportError where error.isRefusal {
                // One message the server refuses fails its whole batch: one at a time instead, so
                // only that message waits (and is left out after `fetchAttempts`).
                summaries = try await summariesOneByOne(chunk, mailbox: mailbox, session: session, run: &run)
            }
            let byUID = Dictionary(summaries.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
            var prepared: [PreparedMessage] = []
            var interruption: MailTransportError?
            messages: for uid in chunk {
                guard let summary = byUID[uid] else { continue }   // expunged meanwhile
                let attempts = fetchFailures[mailbox.id]?[uid] ?? 0
                if attempts >= configuration.fetchAttempts {
                    Log.mail.error("A message failed to download \(attempts, privacy: .public) times; storing its headers only")
                    prepared.append(await headersOnly(summary, session: session))
                    fetchFailures[mailbox.id]?[uid] = nil
                    continue
                }
                do {
                    prepared.append(try await prepare(summary, session: session, whole: attempts == 0))
                    fetchFailures[mailbox.id]?[uid] = nil
                } catch let error as MailTransportError where error.isAuthentication {
                    throw error
                } catch {
                    // This message waits (after `fetchAttempts` its headers are stored); the rest
                    // of the batch is still stored. A local failure (the blob store) or a refusal
                    // costs only this message; a lost connection ends the batch here.
                    fetchFailures[mailbox.id, default: [:]][uid] = attempts + 1
                    run.skipped.insert(uid)
                    Log.mail.error("Downloading a message failed (\(attempts + 1, privacy: .public)): \(Self.kind(error), privacy: .public)")
                    guard let transport = error as? MailTransportError else { continue }
                    if transport.isRefusal { continue }
                    if case .missingCapability = transport { continue }
                    interruption = transport
                    break messages
                }
            }
            let limit = run.skipped.min().map { $0 > 0 ? $0 - 1 : 0 }
            let inserted = try await store.commitBatch(
                prepared, mailbox: mailbox, accountID: account.id, uidValidity: selection.uidValidity, uidNext: selection.uidNext,
                syncedSince: nil, lastUIDLimit: limit, batchIndex: run.batchIndex, faults: faults
            )
            run.batchIndex += 1
            if !inserted.isEmpty {
                Log.mail.info("Stored \(inserted.count, privacy: .public) new messages")
                await onNewMail(inserted)
            }
            if let interruption { throw interruption }
        }
    }

    /// A batch's summaries one message at a time, after the server refused the batch. A message
    /// it refuses alone waits for the next pass; after `fetchAttempts` it is left out, so the mail
    /// after it still arrives.
    private func summariesOneByOne(
        _ chunk: [UInt32], mailbox: Mailbox, session: any IMAPSession, run: inout FetchRun
    ) async throws -> [IMAPSummary] {
        var summaries: [IMAPSummary] = []
        for uid in chunk {
            do {
                summaries += try await session.fetchSummaries([uid])
            } catch let error as MailTransportError where error.isRefusal {
                let attempts = (fetchFailures[mailbox.id]?[uid] ?? 0) + 1
                if attempts >= configuration.fetchAttempts {
                    fetchFailures[mailbox.id]?[uid] = nil
                    Log.mail.error("A message was refused \(attempts, privacy: .public) times; it is left out")
                } else {
                    fetchFailures[mailbox.id, default: [:]][uid] = attempts
                    run.skipped.insert(uid)
                }
            }
        }
        return summaries
    }

    /// Fetches (BODY.PEEK, nothing is marked read) and parses one message; stores the raw
    /// message and the sanitized HTML in the BlobStore. `whole`: one fetch of the raw message
    /// when it is within `wholeMessageLimit`; otherwise (and on a retry) headers, structure and
    /// text parts.
    private func prepare(_ summary: IMAPSummary, session: any IMAPSession, whole: Bool) async throws -> PreparedMessage {
        var parsed: ParsedMail
        var raw: BlobRef?
        if whole, summary.size <= configuration.wholeMessageLimit {
            let data = try await session.fetchRaw(summary.uid)
            parsed = (try? MIMEParser.parse(data)) ?? MIMEParser.assemble(HeaderBlock(), collector: BodyCollector())
            if !data.isEmpty { raw = try services.blobs.put(data, fileExtension: "eml") }
        } else {
            parsed = try await parseLarge(summary.uid, session: session)
        }
        var html: BlobRef?
        if !parsed.sanitizedHTML.isEmpty {
            html = try services.blobs.put(Data(parsed.sanitizedHTML.utf8), fileExtension: "html")
        }
        return PreparedMessage(
            uid: summary.uid, flags: summary.flags, internalDate: summary.internalDate,
            size: summary.size, parsed: parsed, raw: raw, html: html
        )
    }

    /// A message that could not be downloaded: its headers (when the server still gives them),
    /// no text, so it is listed and the mail after it moves on.
    private func headersOnly(_ summary: IMAPSummary, session: any IMAPSession) async -> PreparedMessage {
        let header = try? await session.fetchSection(summary.uid, section: "HEADER")
        let block = header.map { HeaderBlock(bytes: Array($0)[...]) } ?? HeaderBlock()
        return PreparedMessage(
            uid: summary.uid, flags: summary.flags, internalDate: summary.internalDate, size: summary.size,
            parsed: MIMEParser.assemble(block, collector: BodyCollector()), raw: nil, html: nil
        )
    }

    /// A message over `wholeMessageLimit` (or one whose whole fetch failed): headers and text
    /// parts only; attachments are listed from the body structure and fetched by section when
    /// opened.
    private func parseLarge(_ uid: UInt32, session: any IMAPSession) async throws -> ParsedMail {
        let header = try await session.fetchSection(uid, section: "HEADER")
        let structure = try await session.fetchStructure(uid)
        var collector = BodyCollector()
        for part in structure {
            let isText = (part.mimeType == "text/plain" || part.mimeType == "text/html") && part.fileName == nil
                && part.disposition != "attachment"
            if isText {
                let encoded = try await session.fetchSection(uid, section: part.section)
                let bytes = TransferEncoding.decode(Array(encoded)[...], encoding: part.encoding)
                let text = MailText.normalizeLineEndings(Charset.decode(bytes, declared: part.charset))
                if part.mimeType == "text/plain" { collector.plain.append(text) } else { collector.html.append(text) }
            } else {
                collector.attachments.append(ParsedAttachment(
                    part: part.section, fileName: MIMEParser.sanitizedFileName(part.fileName, mimeType: part.mimeType),
                    mimeType: part.mimeType, size: part.size, contentID: MessageIDs.single(part.contentID),
                    isInline: part.disposition == "inline" && part.contentID != nil, encoding: part.encoding ?? "7bit"
                ))
            }
        }
        return MIMEParser.assemble(HeaderBlock(bytes: Array(header)[...]), collector: collector)
    }

    // MARK: - Sent copies and re-parsing

    /// Sent drafts whose copy is not in Sent yet (APPEND failed after the server accepted them).
    private func saveSentCopies(account: MailAccount, session: any IMAPSession, mailboxes: [Mailbox]) async throws {
        guard let sent = mailboxes.first(where: { $0.role == .sent }) else { return }
        let accountID = account.id
        let drafts = try await services.database.read { db in
            try MailDraft
                .where { $0.accountID.eq(accountID) && $0.state.eq(MailDraftState.sent) && $0.sentCopySavedAt.is(nil) && $0.rfcMessageID.neq("") }
                .fetchAll(db)
        }
        for draft in drafts where !refusedSentCopies.contains(draft.id) {
            do {
                try await SentCopy.save(draft, account: account, sent: sent, session: session, services: services, now: clock.now)
            } catch let error as MailTransportError where error.isRefusal {
                // Not again on every pass; the next launch tries once more.
                refusedSentCopies.insert(draft.id)
                Log.mail.error("The server refused a sent message's copy for Sent")
            }
        }
    }

    private func reparseOutdated() async {
        guard let rows = try? await store.outdatedRows(limit: configuration.reparseLimit) else { return }
        for row in rows {
            guard let raw = row.raw, let data = try? services.blobs.data(for: raw), let parsed = try? MIMEParser.parse(data) else { continue }
            let html = parsed.sanitizedHTML.isEmpty ? nil : try? services.blobs.put(Data(parsed.sanitizedHTML.utf8), fileExtension: "html")
            try? await store.updateParsed(row.id, parsed: parsed, html: html)
        }
    }
}

/// Engine errors that are not the server's.
public enum MailSyncError: Error, Hashable, Sendable, LocalizedError {
    case messageNotFound
    case attachmentNotFound

    public var errorDescription: String? {
        switch self {
        case .messageNotFound: "The message is no longer there."
        case .attachmentNotFound: "The attachment is no longer there."
        }
    }
}
