import Foundation
import Security

/// Whether this launch has a key for the link.
enum LinkIdentityState {
    case ready(LinkIdentity)
    /// The Keychain did not give a key (no entitlement in an ad-hoc build, a locked phone before
    /// its first unlock, any other refusal): the link stays off for this launch. For the log.
    case unavailable(String)
}

/// The link's one P-256 key per install, kept in the data-protection Keychain as a key item: this
/// device only, readable after the first unlock (a phone locked in the middle of a lecture must
/// still reconnect), never synced. Never through `KeychainSecretStore`, which falls back to the
/// login keychain and moves copies over; this key does neither.
///
/// A new key is made only when the Keychain answers "not found". Any other answer leaves the link
/// off for the launch, so a passing refusal never replaces the key the other device trusts.
struct LinkIdentityStore: Sendable {
    /// The key item's application tag.
    static let tag = Data("socrates.link.identity".utf8)
    static let label = "Socrates"

    func load() -> LinkIdentityState {
        var query = Self.keyAttributes
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let item, CFGetTypeID(item) == SecKeyGetTypeID() else {
                return .unavailable("The Keychain answered with something other than a key.")
            }
            guard let identity = LinkIdentity(key: unsafeDowncast(item, to: SecKey.self)) else {
                return .unavailable("The link key is not a P-256 key.")
            }
            return .ready(identity)
        case errSecItemNotFound:
            return create()
        default:
            return .unavailable("Reading the link key failed (\(status)).")
        }
    }

    private func create() -> LinkIdentityState {
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: Self.tag,
            kSecAttrLabel as String: Self.label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        privateAttributes[kSecAttrSynchronizable as String] = false
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecUseDataProtectionKeychain as String: true,
            kSecPrivateKeyAttrs as String: privateAttributes,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let reason = error.map { String(describing: $0.takeRetainedValue()) } ?? "no key"
            return .unavailable("Making the link key failed: \(reason)")
        }
        guard let identity = LinkIdentity(key: key) else {
            return .unavailable("The new link key is not a P-256 key.")
        }
        return .ready(identity)
    }

    /// The item's address, in every query: the data-protection Keychain, this device only.
    private static var keyAttributes: [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag as String: tag,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
