import CryptoKit
import Foundation

/// The SHA-256 of a public key's SubjectPublicKeyInfo DER: what the link pins. Always computed by
/// the reader from the key it holds (the peer's TLS leaf, a `link_device` row's key), never read
/// from anywhere.
public struct LinkFingerprint: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: Data

    public init(rawValue: Data) {
        self.rawValue = rawValue
    }

    /// The fingerprint of `spki` (the DER of a SubjectPublicKeyInfo).
    public init(spki: Data) {
        rawValue = Data(SHA256.hash(data: spki))
    }

    /// Lowercase hex, for the log.
    public var description: String {
        rawValue.map { String(format: "%02x", $0) }.joined()
    }
}
