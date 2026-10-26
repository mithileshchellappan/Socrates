import CryptoKit
import Foundation
import LinkCore
import StudyCore

/// The devices of the other platform this device trusts: each unretired `link_device` row of that
/// platform, by the fingerprint computed here from its key. A row whose key does not decode as a
/// P-256 public key is left out.
///
/// One key may stand in more than one unretired row: a reinstalled phone keeps its Keychain key
/// and inserts its row before iCloud has brought the earlier row with the same key back. Every
/// such row is trusted, and a peer's hello may name any of them.
struct TrustedPeers: Sendable, Equatable {
    private var devices: [LinkFingerprint: Set<LinkDeviceID>] = [:]

    init() {}

    /// The trusted devices among `rows`: platform `role`, not retired.
    init(rows: [LinkDevice], role: LinkRole) {
        for row in rows where row.platform == role.rawValue && row.retiredAt == nil {
            guard let spki = Data(base64Encoded: row.publicKey),
                  (try? P256.Signing.PublicKey(derRepresentation: spki)) != nil
            else { continue }
            devices[LinkFingerprint(spki: spki), default: []].insert(LinkDeviceID(rawValue: row.id))
        }
    }

    var isEmpty: Bool { devices.isEmpty }

    /// The devices whose key has `fingerprint`; empty: not trusted.
    func devices(for fingerprint: LinkFingerprint) -> Set<LinkDeviceID> {
        devices[fingerprint] ?? []
    }

    /// Whether `device` is still trusted.
    func contains(_ device: LinkDeviceID) -> Bool {
        devices.values.contains { $0.contains(device) }
    }
}
