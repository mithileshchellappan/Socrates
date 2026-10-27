import Foundation
import SQLiteData

// Record type added in schema v19: the devices of the recording link (docs/decisions.md,
// 2026-10-26).

/// One key of one device of the student's own: the public half of the P-256 key the device
/// presents on the direct link between the iPhone and the Mac (Packages/Link). The rows sync
/// through the student's iCloud library, so the student's devices trust each other without
/// pairing; the private key never leaves its device's Keychain.
///
/// - Each device writes only its own rows.
/// - One row per key. A device that had to make a new key inserts a new row and sets
///   `retiredAt` on its previous one (the device remembers that row's id).
/// - Trust is the SHA-256 of the decoded `publicKey` bytes, computed by the reader. No
///   fingerprint is stored, and none would be trusted.
/// - `platform` is a string, so a newer build's other platforms still decode; a reader trusts
///   only the platforms it knows.
@Table("link_device")
public struct LinkDevice: StudyRecord {
    public let id: UUID
    /// "mac" or "iphone": the link's `LinkRole` (Packages/Link), its one definition.
    public var platform: String
    /// Base64 of the public key's SubjectPublicKeyInfo DER (about 91 bytes for P-256). TEXT, never
    /// a BLOB: sync would carry a BLOB column as a CloudKit asset.
    @Column("public_key") public var publicKey: String
    @Column("created_at") public var createdAt: Date
    /// Set by the device that replaced this key; a retired row is never trusted.
    @Column("retired_at") public var retiredAt: Date?
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        platform: String,
        publicKey: String,
        createdAt: Date = Date(),
        retiredAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.platform = platform
        self.publicKey = publicKey
        self.createdAt = createdAt
        self.retiredAt = retiredAt
        self.updatedAt = updatedAt
    }
}
