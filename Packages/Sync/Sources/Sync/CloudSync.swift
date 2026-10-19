import CloudKit
import Foundation
import Observation
import StudyCore
import os

/// iCloud sync of the library (M7, docs/plan-m7.md §4): SQLiteData's `SyncEngine` over the library
/// tables (`Schema.tableNames` except `job`; device-local tables never sync; blobs do not sync in
/// M7). Exists only in a build configured for CloudKit (`CloudSyncConfiguration`), whose database
/// was opened with that container (`StudyServices.live(syncContainer:)`), so no CloudKit call is
/// ever made by a build without the entitlement. The app starts it at launch on the Mac and the
/// iPhone; the phone's agent sheet shows only while it runs.
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

    /// Sync is on: the agent sheet may relay questions to the Mac.
    public var isRunning: Bool { status == .running }

    @ObservationIgnored private var engine: SyncEngine?

    /// Nil unless this build has a CloudKit container (`CloudSyncConfiguration.containerIdentifier()`).
    public init?(services: StudyServices, container: String? = CloudSyncConfiguration.containerIdentifier()) {
        guard let container else { return nil }
        self.services = services
        self.container = container
    }

    /// Checks the iCloud account, then starts the sync engine. A signed-out account or a failure
    /// leaves `status` saying why; calling again (after iCloud came back) retries.
    public func start() async {
        switch status {
        case .starting, .running: return
        case .idle, .unavailable, .failed: break
        }
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
            let engine = try SyncedTables.engine(for: services.database, container: container)
            try await engine.start()
            self.engine = engine
            status = .running
            SyncLog.sync.info("Sync running")
        } catch {
            engine = nil
            status = .failed(error.localizedDescription)
            SyncLog.sync.error("Sync failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Stops syncing (changes made meanwhile go up at the next start).
    public func stop() {
        engine?.stop()
        engine = nil
        status = .idle
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

enum SyncLog {
    static let sync = Log.logger(category: "sync")
}
