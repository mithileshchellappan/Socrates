import Foundation
import Observation
import StudyCore

/// iCloud sync of the library (M7, docs/plan-m7.md §4): SQLiteData's `SyncEngine` over the library
/// tables (`Schema.tableNames` except `job`; device-local tables never sync; blobs do not sync in
/// M7). Exists only in a build configured for CloudKit (`CloudSyncConfiguration`), whose database
/// was opened with that container (`StudyServices.live(syncContainer:)`). The app starts it at
/// launch on the Mac and the iPhone; the phone's agent sheet shows only while it runs.
///
/// Skeleton landed with the plan: it never starts. Workstream A builds it.
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

    /// Nil unless this build has a CloudKit container (`CloudSyncConfiguration.containerIdentifier()`).
    public init?(services: StudyServices, container: String? = CloudSyncConfiguration.containerIdentifier()) {
        guard let container else { return nil }
        self.services = services
        self.container = container
    }

    /// Checks the iCloud account and starts the sync engine.
    public func start() async {}
}
