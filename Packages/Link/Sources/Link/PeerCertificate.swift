import CryptoKit
import Foundation
import LinkCore
import Security

/// What a TLS session says about the peer: the fingerprint of its leaf certificate's key and the
/// application protocol it agreed to. The chain is never evaluated; the link pins the key.
enum PeerCertificate {
    /// The fingerprint of the leaf's key in `trust`, the object the certificate validator is given.
    static func fingerprint(trust: sec_trust_t) -> LinkFingerprint? {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        return fingerprint(certificate: leaf)
    }

    /// The fingerprint of the peer's leaf in a finished session; nil when the session has no peer
    /// certificate (a resumed session, which the link closes).
    static func fingerprint(metadata: sec_protocol_metadata_t) -> LinkFingerprint? {
        var leaf: SecCertificate?
        let accessible = sec_protocol_metadata_access_peer_certificate_chain(metadata) { certificate in
            if leaf == nil {
                leaf = sec_certificate_copy_ref(certificate).takeRetainedValue()
            }
        }
        guard accessible, let leaf else { return nil }
        return fingerprint(certificate: leaf)
    }

    /// The application protocol (ALPN) the session agreed to.
    static func negotiatedProtocol(metadata: sec_protocol_metadata_t) -> String? {
        guard let pointer = sec_protocol_metadata_copy_negotiated_protocol(metadata) else { return nil }
        defer { free(UnsafeMutableRawPointer(mutating: pointer)) }
        return String(cString: pointer)
    }

    /// The SHA-256 of the certificate key's SubjectPublicKeyInfo; nil for anything but a P-256 key.
    static func fingerprint(certificate: SecCertificate) -> LinkFingerprint? {
        guard let key = SecCertificateCopyKey(certificate) else { return nil }
        var error: Unmanaged<CFError>?
        guard let external = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            error?.release()
            return nil
        }
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: external) else { return nil }
        return LinkFingerprint(spki: publicKey.derRepresentation)
    }
}
