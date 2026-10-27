import CloudKit
import Foundation
import Observation
import StudyCore
import os

/// iCloud sync of the library (M7, docs/plan-m7.md §4): SQLiteData's `SyncEngine` over the library
/// tables (`Schema.tableNames` except `job`; device-local tables never sync; blobs do not sync in
/// M7). Exists only for a library opened with a CloudKit container
/// (`StudyServices.live(syncContainer:)` sets `services.syncContainer` for the real library of a
/// build signed for iCloud), so no CloudKit call is ever made by a build without the entitlement.
///
/// The app makes it at launch, before anything writes: the engine is built then, so SQLiteData's
/// change triggers note every write from the first one (a row written before they exist would
/// never upload). `start()`, about 2 s later, checks the iCloud account and starts syncing; the
/// phone's agent sheet shows only while it runs. Sync that is off because iCloud was not ready or
/// the start failed starts again within the run (`retry()`): when iCloud reports an account change
/// (`CKAccountChanged`, followed here for the app's life), and when the app calls it (the Mac's
/// wake, the iPhone or iPad app coming to the front).
///
/// Guards (docs/decisions.md, 2026-10-20):
/// - An iCloud sign-out or account switch stops syncing and keeps every row
///   (`AccountChangeGuard`); SQLiteData's default would delete all synced rows on the device.
/// - The Mac copies its library once, before its first sync (`AppPaths.preSyncBackup`, next to it).
/// - Every later start queues again the rows iCloud has not received (`SyncedTables.queueUnsent`)
///   and rows written while no engine noted them (`SyncedTables.queueUntracked`), so a first
///   upload that a quit, a crash or a lost network interrupted resumes where it stopped.
/// - Rows sync deletes on this device are logged by table and count (`SyncDeletionLog`).
@MainActor
@Observable
public final class CloudSync {
    public enum Status: Hashable, Sendable {
        /// Created, not started (or iCloud not checked yet).
        case idle
        case starting
        case running
        /// iCloud is signed out or restricted; nothing syncs until it is back.
        case unavailable(String)
        /// Readable, no secrets.
        case failed(String)
    }

    public let services: StudyServices
    public let container: String
    public private(set) var status: Status = .idle
    /// Rows of this library iCloud has not received yet (`refreshUnsent()`); nil before the first
    /// count. Large during the Mac's first upload, then 0.
    public private(set) var unsentCount: Int?

    /// Sync is on: the agent sheet may relay questions to the Mac.
    public var isRunning: Bool { status == .running }

    /// True once iCloud reported a switch to another account in this run; the next launch reports
    /// it again while the library's sync state belongs to the other account. Never cleared in
    /// process. The recording link stops on it: its trust came from that account's rows. A typed
    /// flag, so nothing reads the localized `status` reason.
    public private(set) var accountSwitched = false

    /// Sending or fetching changes right now (observable through SQLiteData's engine).
    public var isSynchronizing: Bool { isRunning && (engine?.isSynchronizing ?? false) }

    /// Built once (`prepare()`), kept for the app's life; stopped and started again as the account
    /// comes and goes. Its triggers note changes also while it is stopped (sent at the next start).
    @ObservationIgnored private var engine: SyncEngine?
    /// True once the engine is built: its triggers note every write from then on, so rows written
    /// now are queued for upload (`LibraryRestore` waits for it).
    public var hasEngine: Bool { engine != nil }
    /// Logs the rows sync deletes on this device (`SyncDeletionLog`); on the library's writer
    /// from the first engine on, added once.
    private let deletionLog = SyncDeletionLog(tables: Set(SyncedTables.tableNames))
    /// Follows `CKAccountChanged` for this object's life (`retry()` on each).
    @ObservationIgnored private var accountChanges: Task<Void, Never>?
    /// A `retry()` came while a start was asking iCloud: its answer may be stale, so a start that
    /// ends off tries once more.
    @ObservationIgnored private var retryRequested = false

    /// Nil unless the library was opened for a CloudKit container (`services.syncContainer`).
    /// Builds the engine at once (not started; no CloudKit call).
    public init?(services: StudyServices) {
        guard let container = services.syncContainer else { return nil }
        self.services = services
        self.container = container
        do {
            try prepare()
        } catch {
            status = .failed(error.localizedDescription)
            SyncLog.sync.error("Sync engine setup failed: \(String(describing: error), privacy: .public)")
        }
        // iCloud signed in again, re-authenticated or came back: no relaunch needed.
        accountChanges = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
                guard let self else { return }
                await self.retry()
            }
        }
    }

    isolated deinit {
        accountChanges?.cancel()
    }

    /// Checks the iCloud account, then starts the sync engine. A signed-out account or a failure
    /// leaves `status` saying why; calling again (after iCloud came back) retries. A `retry()`
    /// during the start (iCloud came back while it was asked) makes a start that ends off try
    /// again; each extra try needs another such call.
    public func start() async {
        switch status {
        case .starting, .running: return
        case .idle, .unavailable, .failed: break
        }
        repeat {
            retryRequested = false
            await begin()
        } while retryRequested && isOff && !accountSwitched
    }

    /// Off for a reason that may pass: iCloud unavailable or the start failed.
    private var isOff: Bool {
        switch status {
        case .unavailable, .failed: true
        case .idle, .starting, .running: false
        }
    }

    /// One start: the account, the Mac's pre-sync copy, the engine, the rows to queue again.
    private func begin() async {
        status = .starting
        let missing = SyncedTables.missingTables
        guard missing.isEmpty else {
            // A migration added a table the sync does not list: fail loudly instead of leaving
            // its rows on one device.
            status = .failed(String(localized: "Sync doesn’t cover \(missing.joined(separator: ", "))."))
            SyncLog.sync.error("Synced tables are missing: \(missing.joined(separator: ", "), privacy: .public)")
            return
        }
        do {
            let account = try await CKContainer(identifier: container).accountStatus()
            guard account == .available else {
                status = .unavailable(Self.describe(account))
                SyncLog.sync.notice("iCloud not available: \(account.rawValue, privacy: .public)")
                return
            }
            if engine == nil { try prepare() }
            guard let engine else { return }
            let database = services.database
            let hasSynced = try await database.read { db in try SyncedTables.hasSynced(db) }
            #if os(macOS)
            // The only full copy of the library is on the Mac: one copy of it before its first
            // sync, against anything a sync could do to it (a deleted zone deletes its rows).
            if !hasSynced {
                try await Self.backUp(database, to: services.paths.preSyncBackup)
            }
            #endif
            do {
                try await engine.start()
            } catch {
                engine.stop()
                throw error
            }
            // The account changed while the engine started (`accountChanged` said why).
            guard status == .starting else {
                engine.stop()
                return
            }
            status = .running
            SyncLog.sync.info("Sync running")
            // The first start queued every row itself; later starts queue again what never
            // reached iCloud (an upload a quit or a crash interrupted resumes).
            if hasSynced {
                do {
                    let queued = try await database.write { db in
                        try SyncedTables.queueUntracked(db) + SyncedTables.queueUnsent(db)
                    }
                    if queued > 0 { SyncLog.sync.notice("Queued \(queued) rows iCloud has not received") }
                } catch {
                    SyncLog.sync.error("Queueing unsent rows failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            await refreshUnsent()
        } catch {
            status = .failed(error.localizedDescription)
            SyncLog.sync.error("Sync failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Starts sync again when it is off for a reason that may have passed: iCloud was unavailable
    /// (signed out, restricted, re-authentication pending) or the start failed. While a start asks
    /// iCloud, it is noted, and that start tries again if it ends off. Nothing while it runs,
    /// before the launch's own `start()`, or once iCloud switched to another account in this run
    /// (the library's sync state belongs to the account it synced with; the next launch checks
    /// again). `CKAccountChanged` calls it; the app calls it when the Mac wakes and when the
    /// iPhone or iPad app comes to the front.
    public func retry() async {
        guard !accountSwitched else { return }
        switch status {
        case .unavailable, .failed:
            SyncLog.sync.info("Starting sync again")
            await start()
        case .starting:
            retryRequested = true
        case .idle, .running:
            return
        }
    }

    /// Stops syncing (changes made meanwhile go up at the next start).
    public func stop() {
        engine?.stop()
        status = .idle
    }

    /// Counts the rows iCloud has not received yet (`unsentCount`); nothing while sync is off.
    public func refreshUnsent() async {
        guard isRunning else { return }
        do {
            unsentCount = try await services.database.read { db in try SyncedTables.unsentCount(db) }
        } catch {
            SyncLog.sync.error("Counting unsent rows failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Builds the engine over the library (installs SQLiteData's triggers; not started). The
    /// first engine also adds the deletion log to the library's writer.
    private func prepare() throws {
        let guardDelegate = AccountChangeGuard { [weak self] change in
            await self?.accountChanged(change)
        }
        let isFirstEngine = engine == nil
        engine = try SyncedTables.engine(for: services.database, container: container, delegate: guardDelegate)
        if isFirstEngine {
            services.database.add(transactionObserver: deletionLog, extent: .databaseLifetime)
        }
    }

    /// An iCloud sign-out or a switch to another account: syncing stops and every row stays
    /// (SQLiteData's default would delete all synced rows here, also those iCloud never got).
    /// After a sign-out, signing in again starts it again (`retry()`); after a switch, the next
    /// launch checks the account again. The library's sync state belongs to the account it synced
    /// with, so another account stops it again.
    private func accountChanged(_ change: CKSyncEngine.Event.AccountChange.ChangeType) {
        switch change {
        case .signOut:
            halt(String(localized: "Not signed in to iCloud"))
        case .switchAccounts:
            accountSwitched = true
            halt(String(localized: "Another iCloud account"))
        case .signIn:
            break
        @unknown default:
            break
        }
    }

    private func halt(_ reason: String) {
        engine?.stop()
        unsentCount = nil
        status = .unavailable(reason)
        SyncLog.sync.notice("Sync stopped: the iCloud account changed")
    }

    /// `VACUUM INTO` a new file, written as `<url>.partial` and then renamed, so the copy is whole
    /// or absent (a copy a quit interrupted is made again); an existing copy is kept: one copy,
    /// from before the first sync.
    private static func backUp(_ database: any DatabaseWriter, to url: URL) async throws {
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        let partial = url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".partial")
        LibraryCopy.removeDatabaseFiles(at: partial)
        try await database.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [partial.path(percentEncoded: false)])
        }
        try FileManager.default.moveItem(at: partial, to: url)
        SyncLog.sync.notice("Copied the library before its first sync")
    }

    private static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .noAccount: String(localized: "Not signed in to iCloud")
        case .restricted: String(localized: "iCloud is restricted")
        case .temporarilyUnavailable: String(localized: "iCloud is unavailable")
        default: String(localized: "iCloud status unknown")
        }
    }
}

/// SQLiteData's delegate for account changes. Without one, a sign-out or an account switch runs
/// `deleteLocalData()`: every row of every synced table on this device deleted. This one only
/// reports the change (`CloudSync` stops syncing and keeps the rows).
final class AccountChangeGuard: SyncEngineDelegate {
    let onChange: @Sendable (CKSyncEngine.Event.AccountChange.ChangeType) async -> Void

    init(onChange: @escaping @Sendable (CKSyncEngine.Event.AccountChange.ChangeType) async -> Void) {
        self.onChange = onChange
    }

    func syncEngine(_ syncEngine: SyncEngine, accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType) async {
        await onChange(changeType)
    }
}

enum SyncLog {
    static let sync = Log.logger(category: "sync")
    /// `LibraryBackup`: the daily copies, their pruning and row-count drops.
    static let backup = Log.logger(category: "sync.backup")
    /// `LibraryRestore`: rows put back from the pre-sync copy, and the replans after it.
    static let restore = Log.logger(category: "sync.restore")
    /// `SyncDeletionLog`: deletes sync makes on this device.
    static let deletes = Log.logger(category: "sync.deletes")
}
