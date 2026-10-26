import Foundation
import GRDB
import LinkCore
import StudyCore

/// The link's devices in the synced library (`link_device`): this device's own row, and the rows
/// of the other platform it trusts, followed as they change (a phone's row arriving from iCloud, a
/// key retired).
///
/// Each device writes only its own rows: one per key. A device that had to make a new key inserts
/// a new row and retires the row of its previous key, whose id it remembers
/// (`Socrates.Link.deviceID`). Trust is always computed here from the rows' keys.
actor LinkDirectory {
    static let deviceIDKey = "Socrates.Link.deviceID"

    private let services: StudyServices
    /// This device's platform.
    private let role: LinkRole
    /// The platform it trusts.
    private let peerRole: LinkRole
    private(set) var trusted = TrustedPeers()
    private var observation: AnyDatabaseCancellable?
    private var follower: Task<Void, Never>?

    init(services: StudyServices, role: LinkRole) {
        self.services = services
        self.role = role
        peerRole = role == .mac ? .iPhone : .mac
    }

    /// This device's row for the key `spki`: the unretired row of this platform with that key,
    /// else a new one (then the row of the previous key, if any, is retired).
    func register(spki: Data) async throws -> LinkDeviceID {
        let key = spki.base64EncodedString()
        let rows = try await services.records.fetchAll(LinkDevice.self)
        let defaults = UserDefaults.standard
        let remembered = defaults.string(forKey: Self.deviceIDKey).flatMap(UUID.init(uuidString:))
        if let own = rows.first(where: { $0.platform == role.rawValue && $0.publicKey == key && $0.retiredAt == nil }) {
            if own.id != remembered { defaults.set(own.id.uuidString, forKey: Self.deviceIDKey) }
            return LinkDeviceID(rawValue: own.id)
        }
        let row = try await services.records.save(LinkDevice(platform: role.rawValue, publicKey: key))
        if let remembered, remembered != row.id,
           rows.contains(where: { $0.id == remembered && $0.platform == role.rawValue && $0.retiredAt == nil }) {
            try await retire(remembered)
        }
        defaults.set(row.id.uuidString, forKey: Self.deviceIDKey)
        LinkLog.link.notice("Link device \(row.id.uuidString, privacy: .public) registered")
        return LinkDeviceID(rawValue: row.id)
    }

    private func retire(_ id: UUID) async throws {
        let store = services.records
        let stamp = store.currentDate
        try await services.database.write { db in
            try LinkDevice.find(id).update {
                $0.retiredAt = Date?.some(stamp)
                $0.updatedAt = stamp
            }
            .execute(db)
        }
        LinkLog.link.notice("Link device \(id.uuidString, privacy: .public) retired")
    }

    /// Follows `link_device`: `onChange` gets the trusted devices now and after every change of
    /// the table (sync included). Idempotent.
    func follow(onChange: @escaping @Sendable (TrustedPeers) async -> Void) {
        guard observation == nil else { return }
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        observation = DatabaseRegionObservation(
            tracking: SQLRequest<Row>(sql: "SELECT id, platform, public_key, retired_at FROM link_device")
        )
        .start(
            in: services.database,
            onError: { error in
                LinkLog.link.error("Following the link devices failed: \(String(describing: error), privacy: .public)")
            },
            onChange: { _ in continuation.yield() }
        )
        continuation.yield()
        follower = Task { [weak self] in
            for await _ in changes {
                guard let self, let peers = await self.reload() else { continue }
                await onChange(peers)
            }
        }
    }

    /// Stops following and forgets every trusted device (the link stopped, or the iCloud account
    /// changed: trust learned through the old account goes with it).
    func stop() {
        observation?.cancel()
        observation = nil
        follower?.cancel()
        follower = nil
        trusted = TrustedPeers()
    }

    /// The trusted device whose key has `fingerprint`.
    func device(for fingerprint: LinkFingerprint) -> LinkDeviceID? {
        trusted.device(for: fingerprint)
    }

    private func reload() async -> TrustedPeers? {
        do {
            let rows = try await services.records.fetchAll(LinkDevice.self)
            guard observation != nil else { return nil }
            trusted = TrustedPeers(rows: rows, role: peerRole)
            return trusted
        } catch {
            LinkLog.link.error("Reading the link devices failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
