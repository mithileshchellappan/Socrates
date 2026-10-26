import CryptoKit
import Foundation
import LinkCore
import Security

/// This device's key on the link: the private key in the Keychain, its public half
/// (SubjectPublicKeyInfo DER, what the `link_device` row carries) and the certificate it presents.
/// Not Sendable: the key and the TLS identity made from it stay inside the actor that loaded it;
/// only `spki` and `fingerprint` (values) leave it.
final class LinkIdentity {
    let key: SecKey
    /// The public key's SubjectPublicKeyInfo DER (91 bytes for P-256).
    let spki: Data
    let fingerprint: LinkFingerprint

    /// Nil when `key` is not a P-256 private key.
    init?(key: SecKey) {
        guard let publicKey = SecKeyCopyPublicKey(key) else { return nil }
        var error: Unmanaged<CFError>?
        guard let external = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            error?.release()
            return nil
        }
        guard let signingKey = try? P256.Signing.PublicKey(x963Representation: external) else { return nil }
        self.key = key
        spki = signingKey.derRepresentation
        fingerprint = LinkFingerprint(spki: spki)
    }

    enum IdentityError: Error {
        case signature(String)
        case certificate
        case identity
    }

    /// The TLS identity: a self-signed certificate made from the key now (a new serial number each
    /// time), paired with the key.
    func secIdentity() throws -> sec_identity_t {
        var generator = SystemRandomNumberGenerator()
        var serial = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        // Positive and never zero: the high bit cleared, the next one set.
        serial[0] = (serial[0] & 0x3F) | 0x40
        let der = try SelfSignedCertificate.der(spki: spki, serialNumber: Data(serial)) { toBeSigned in
            try sign(toBeSigned)
        }
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw IdentityError.certificate }
        guard let identity = SecIdentityCreate(nil, certificate, key), let secIdentity = sec_identity_create(identity) else {
            throw IdentityError.identity
        }
        return secIdentity
    }

    private func sign(_ data: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, data as CFData, &error) as Data? else {
            let reason = error.map { String(describing: $0.takeRetainedValue()) } ?? "no signature"
            throw IdentityError.signature(reason)
        }
        return signature
    }
}
