import Foundation
import Security
import Synchronization

/// Which macOS keychain implementation an item lives in.
public enum KeychainBackend: String, Hashable, Sendable {
    /// The iOS-style data-protection keychain. On macOS it needs a provisioning-backed
    /// application identifier; ad-hoc ("Sign to Run Locally") builds get
    /// `errSecMissingEntitlement` (-34018).
    case dataProtection
    /// The macOS file-based login keychain. Works for any signing, but access is tied to the
    /// app's code signature, so a re-signed ad-hoc build may show a one-time keychain prompt.
    case fileBased
}

public enum KeychainError: Error, Hashable, Sendable {
    /// `errSecMissingEntitlement` (-34018): this backend is unavailable to this build.
    case missingEntitlement
    case unexpectedStatus(Int32)
    case invalidData
}

extension KeychainError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingEntitlement: "The Keychain is not available to this build."
        case .unexpectedStatus(let status): "The Keychain refused the change (\(status))."
        case .invalidData: "The Keychain item could not be read."
        }
    }
}

/// Address of a generic-password item.
public struct KeychainItem: Hashable, Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

/// Raw keychain primitives, so the backend-selection strategy can be tested without touching
/// the real keychain.
public protocol KeychainOperations: Sendable {
    /// Returns nil when the item does not exist.
    func read(_ item: KeychainItem, backend: KeychainBackend) throws -> Data?
    /// Adds or updates.
    func write(_ data: Data, to item: KeychainItem, backend: KeychainBackend) throws
    /// No-op when the item does not exist.
    func delete(_ item: KeychainItem, backend: KeychainBackend) throws
}

/// `SecretStore` backed by the Keychain.
///
/// Strategy: use the data-protection keychain when the build is entitled to it (always on iOS;
/// on macOS when signed with a development/distribution profile). On macOS, if it reports
/// `errSecMissingEntitlement`, fall back to the login keychain and remember that for the
/// process. When a later, provisioned build finds the data-protection keychain empty, it moves
/// an existing login-keychain item over. Items are never synchronized to iCloud.
public final class KeychainSecretStore: SecretStore {
    public let service: String
    private let operations: any KeychainOperations
    private let candidates: [KeychainBackend]
    private let resolved = Mutex<KeychainBackend?>(nil)

    public static var platformCandidates: [KeychainBackend] {
        #if os(macOS)
        [.dataProtection, .fileBased]
        #else
        [.dataProtection]
        #endif
    }

    public init(
        service: String = Log.subsystem,
        operations: any KeychainOperations = SystemKeychain(),
        candidates: [KeychainBackend] = KeychainSecretStore.platformCandidates
    ) {
        self.service = service
        self.operations = operations
        self.candidates = candidates
    }

    /// The backend in use, once the first operation has resolved it.
    public var activeBackend: KeychainBackend? {
        resolved.withLock { $0 }
    }

    public func secret(for key: SecretKey) throws -> String? {
        let item = item(for: key)
        // A read that finds nothing does not settle the backend: an ad-hoc build reads
        // "not found" (-25300) from the data-protection keychain and only fails on writes.
        let (data, backend) = try perform(settles: false) { backend in
            (try operations.read(item, backend: backend), backend)
        }
        if let data {
            settle(on: backend)
            return try decode(data)
        }
        guard backend == .dataProtection, candidates.contains(.fileBased),
            let legacy = try? operations.read(item, backend: .fileBased)
        else { return nil }
        do {
            try operations.write(legacy, to: item, backend: .dataProtection)
            try? operations.delete(item, backend: .fileBased)
            settle(on: .dataProtection)
            // The key name can hold the uni login name; keep it out of the readable log.
            Log.keychain.info("Moved \(key.rawValue, privacy: .private(mask: .hash)) to the data-protection keychain")
        } catch KeychainError.missingEntitlement {
            settle(on: .fileBased)
        }
        return try decode(legacy)
    }

    public func setSecret(_ value: String, for key: SecretKey) throws {
        let item = item(for: key)
        try perform { backend in
            try operations.write(Data(value.utf8), to: item, backend: backend)
        }
    }

    public func removeSecret(for key: SecretKey) throws {
        let item = item(for: key)
        try perform { backend in
            try operations.delete(item, backend: backend)
        }
        if activeBackend == .dataProtection, candidates.contains(.fileBased) {
            try? operations.delete(item, backend: .fileBased)
        }
    }

    // MARK: - Private

    private func item(for key: SecretKey) -> KeychainItem {
        KeychainItem(service: service, account: key.rawValue)
    }

    private func decode(_ data: Data) throws -> String {
        guard let string = String(data: data, encoding: .utf8) else { throw KeychainError.invalidData }
        return string
    }

    /// Runs `body` on the settled backend, or tries candidates in order until one is entitled.
    /// A backend that turns out to be unentitled later (a write after an empty read) is skipped.
    private func perform<Result>(
        settles: Bool = true,
        _ body: (KeychainBackend) throws -> Result
    ) throws -> Result {
        let start = activeBackend.flatMap { candidates.firstIndex(of: $0) } ?? candidates.startIndex
        for backend in candidates[start...] {
            do {
                let result = try body(backend)
                if settles { settle(on: backend) }
                return result
            } catch KeychainError.missingEntitlement {
                Log.keychain.info("\(backend.rawValue, privacy: .public) keychain unavailable (missing entitlement)")
                continue
            }
        }
        throw KeychainError.missingEntitlement
    }

    private func settle(on backend: KeychainBackend) {
        let changed = resolved.withLock { current in
            defer { current = backend }
            return current != backend
        }
        if changed { Log.keychain.info("Using \(backend.rawValue, privacy: .public) keychain") }
    }
}

/// The real Security-framework keychain.
public struct SystemKeychain: KeychainOperations {
    public init() {}

    public func read(_ item: KeychainItem, backend: KeychainBackend) throws -> Data? {
        var query = baseQuery(item, backend: backend)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.invalidData }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(for: status)
        }
    }

    public func write(_ data: Data, to item: KeychainItem, backend: KeychainBackend) throws {
        let query = baseQuery(item, backend: backend)
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, update)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Socrates (\(item.account))"
            if backend == .dataProtection {
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Self.error(for: addStatus) }
        default:
            throw Self.error(for: status)
        }
    }

    public func delete(_ item: KeychainItem, backend: KeychainBackend) throws {
        let status = SecItemDelete(baseQuery(item, backend: backend) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(for: status)
        }
    }

    private func baseQuery(_ item: KeychainItem, backend: KeychainBackend) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecAttrSynchronizable as String: false,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = backend == .dataProtection
        #endif
        return query
    }

    private static func error(for status: OSStatus) -> KeychainError {
        status == errSecMissingEntitlement ? .missingEntitlement : .unexpectedStatus(status)
    }
}
