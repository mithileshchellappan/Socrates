/// The link's generation and how it is found.
///
/// The generation rises only for a change an older peer cannot skip; within one generation every
/// change is additive: message kinds are never reused and an unknown kind is skipped, later JSON
/// fields are optional, and features are decided by the hello's capabilities, never by comparing
/// app versions.
public enum LinkProtocol {
    /// The TLS application protocol (ALPN) both sides offer and require: the generation.
    public static let applicationProtocol = "socrates-link/1"
    /// The Bonjour service type the Mac advertises under a random name per launch (no TXT record:
    /// nothing personal is broadcast).
    public static let serviceType = "_socrates._tcp"
}
