import Foundation

/// The first message each side sends, within `LinkPolicy.helloTimeout` of the connection: who it
/// is and what it speaks. Checked against the TLS session: `device` must be the `link_device` row
/// whose key the peer presented, and `role` that row's platform; anything else is closed with
/// `Goodbye.Reason.untrusted`.
public struct Hello: Codable, Hashable, Sendable {
    public var role: LinkRole
    public var device: LinkDeviceID
    /// New at every launch: tells a relaunched phone (whose snapshot sequence may start over) from
    /// a reconnect of the same run.
    public var instance: UUID
    /// The app's version and build ("1.4 (212)"), for the log only: features are decided by
    /// `capabilities`.
    public var app: String
    /// `RecorderContractVersion.current` of the sender: `control` needs equal versions.
    public var recorderContract: Int
    public var capabilities: Set<LinkCapability>

    public init(
        role: LinkRole,
        device: LinkDeviceID,
        instance: UUID,
        app: String,
        recorderContract: Int,
        capabilities: Set<LinkCapability>
    ) {
        self.role = role
        self.device = device
        self.instance = instance
        self.app = app
        self.recorderContract = recorderContract
        self.capabilities = capabilities
    }

    /// Whether the remote's control is on between `self` and `other`: both list it and both speak
    /// the same recorder contract.
    public func allowsControl(with other: Hello) -> Bool {
        capabilities.contains(.control) && other.capabilities.contains(.control)
            && recorderContract == other.recorderContract
    }

    /// Whether recordings are copied between `self` and `other`.
    public func allowsFiles(with other: Hello) -> Bool {
        capabilities.contains(.files) && other.capabilities.contains(.files)
    }
}
