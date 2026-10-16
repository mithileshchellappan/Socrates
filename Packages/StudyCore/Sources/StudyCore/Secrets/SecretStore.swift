import Foundation
import Synchronization

/// Names of secrets. Values only ever live in the Keychain (via `KeychainSecretStore`).
public struct SecretKey: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }

    public static let anthropicAPIKey = SecretKey(rawValue: "anthropic-api-key")

    /// Uni IMAP/SMTP password for `username`.
    public static func uniPassword(username: String) -> SecretKey {
        SecretKey(rawValue: "uni-password.\(username.lowercased())")
    }
}

/// Stores small secrets (API key, uni password).
///
/// Never write secret values to files, logs, fixtures, prompts or the database.
public protocol SecretStore: Sendable {
    func secret(for key: SecretKey) throws -> String?
    func setSecret(_ value: String, for key: SecretKey) throws
    func removeSecret(for key: SecretKey) throws
}

extension SecretStore {
    public func hasSecret(for key: SecretKey) -> Bool {
        ((try? secret(for: key)) ?? nil)?.isEmpty == false
    }
}

/// A process-local secret store for tests and previews.
public final class InMemorySecretStore: SecretStore {
    private let values: Mutex<[SecretKey: String]>

    public init(_ values: [SecretKey: String] = [:]) {
        self.values = Mutex(values)
    }

    public func secret(for key: SecretKey) throws -> String? {
        values.withLock { $0[key] }
    }

    public func setSecret(_ value: String, for key: SecretKey) throws {
        values.withLock { $0[key] = value }
    }

    public func removeSecret(for key: SecretKey) throws {
        _ = values.withLock { $0.removeValue(forKey: key) }
    }
}
