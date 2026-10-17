import Foundation

/// Supplies the Anthropic API key for each request. At runtime this reads the Keychain
/// (`SecretStore` with `SecretKey.anthropicAPIKey`); the key is only ever placed in the `x-api-key`
/// header and is never logged, stored, or included in errors.
public protocol APIKeyProvider: Sendable {
    /// The key, or nil when none is configured.
    func apiKey() async throws -> String?
}

/// Adapts a closure, e.g. `ClosureAPIKeyProvider { try services.secrets.secret(for: .anthropicAPIKey) }`.
public struct ClosureAPIKeyProvider: APIKeyProvider {
    private let read: @Sendable () async throws -> String?

    public init(_ read: @escaping @Sendable () async throws -> String?) {
        self.read = read
    }

    public func apiKey() async throws -> String? {
        try await read()
    }
}

/// A fixed key (tests). Never use a literal key in app code.
public struct StaticAPIKeyProvider: APIKeyProvider {
    private let key: String?

    public init(_ key: String?) { self.key = key }

    public func apiKey() async throws -> String? { key }
}
