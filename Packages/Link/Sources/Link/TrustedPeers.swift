import CryptoKit
import Foundation
import LinkCore
import StudyCore

/// The devices of the other platform this device trusts: each unretired `link_device` row of that
/// platform, by the fingerprint computed here from its key. A row whose key does not decode as a
/// P-256 public key is left out.
struct TrustedPeers: Sendable, Equatable {
    private var devices: [LinkFingerprint: LinkDeviceID] = [:]

    init() {}

    /// The trusted devices among `rows`: platform `role`, not retired.
    init(rows: [LinkDevice], role: LinkRole) {
        for row in rows where row.platform == role.rawValue && row.retiredAt == nil {
            guard let spki = Data(base64Encoded: row.publicKey),
                  (try? P256.Signing.PublicKey(derRepresentation: spki)) != nil
            else { continue }
            devices[LinkFingerprint(spki: spki)] = LinkDeviceID(rawValue: row.id)
        }
    }

    var isEmpty: Bool { devices.isEmpty }

    /// The device whose key has `fingerprint`; nil: not trusted.
    func device(for fingerprint: LinkFingerprint) -> LinkDeviceID? {
        devices[fingerprint]
    }

    /// Whether `device` is still trusted.
    func contains(_ device: LinkDeviceID) -> Bool {
        devices.values.contains(device)
    }
}
