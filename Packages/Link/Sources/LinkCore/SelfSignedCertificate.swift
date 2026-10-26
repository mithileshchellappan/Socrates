import Foundation

/// The certificate each side presents on the link: X.509 v3, self-signed with the device's
/// P-256 key, common name "Socrates" (nothing personal), valid from 2025-01-01 to 9999-12-31
/// (RFC 5280's "no expiration"), signed with ecdsa-with-SHA256, no extensions. Nobody evaluates
/// it as a chain: the peer pins the SHA-256 of its public key. It is rebuilt from the key at every
/// launch.
public enum SelfSignedCertificate {
    /// The common name of subject and issuer.
    public static let commonName = "Socrates"

    /// The certificate's DER. `spki` is the public key's SubjectPublicKeyInfo DER,
    /// `serialNumber` positive big-endian bytes (16 random ones with the high bit cleared), and
    /// `sign` returns the DER ECDSA signature of the bytes it is given, made with the private key
    /// (`SecKeyCreateSignature`, `.ecdsaSignatureMessageX962SHA256`).
    public static func der(spki: Data, serialNumber: Data, sign: (Data) throws -> Data) rethrows -> Data {
        let algorithm = DER.sequence([DER.objectIdentifier([1, 2, 840, 10045, 4, 3, 2])])
        let name = DER.sequence([
            DER.set([DER.sequence([DER.objectIdentifier([2, 5, 4, 3]), DER.utf8String(commonName)])])
        ])
        let validity = DER.sequence([
            DER.utcTime("250101000000Z"),
            DER.generalizedTime("99991231235959Z"),
        ])
        let toBeSigned = DER.sequence([
            DER.explicit(0, DER.integer(2)),
            DER.integer(serialNumber),
            algorithm,
            name,
            validity,
            name,
            spki,
        ])
        let signature = try sign(toBeSigned)
        return DER.sequence([toBeSigned, algorithm, DER.bitString(signature)])
    }
}
