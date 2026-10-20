import Foundation
import SQLiteData

// Record type added in schema v15: the student's university profile, one row.

/// The library's university profile (`UniversityProfile`, JSON): at most one row, with the fixed
/// id `rowID`, so every device (and a later sync) has the same row. Missing: the student has told
/// the app nothing yet and `UniversityProfile.standard` applies. Written through `save` (the agent's
/// `set_profile`), which also makes it the current profile.
@Table("university_profile")
public struct UniversityProfileRecord: StudyRecord {
    public let id: UUID
    @Column(as: UniversityProfile.JSONRepresentation.self) public var profile: UniversityProfile
    @Column("updated_at") public var updatedAt: Date

    public init(id: UUID = UniversityProfileRecord.rowID, profile: UniversityProfile, updatedAt: Date = Date()) {
        self.id = id
        self.profile = profile
        self.updatedAt = updatedAt
    }

    /// The one row's id.
    public static let rowID = UUID(uuid: (0x55, 0x4e, 0x49, 0x56, 0x50, 0x52, 0x4f, 0x46, 0x80, 0x00, 0, 0, 0, 0, 0, 0x01))

    /// The library's profile, nil when it has none.
    public static func stored(in db: Database) throws -> UniversityProfile? {
        try UniversityProfileRecord.find(rowID).fetchOne(db)?.profile
    }

    /// The library's profile, else `standard`.
    public static func profile(in db: Database) throws -> UniversityProfile {
        try stored(in: db) ?? .standard
    }

    /// Writes `profile` as the library's inside the caller's transaction; once it commits, the
    /// profile is the current one.
    public static func save(_ profile: UniversityProfile, at date: Date, db: Database) throws {
        let row = UniversityProfileRecord(profile: profile, updatedAt: date)
        try UniversityProfileRecord.upsert { row }.execute(db)
        db.afterNextTransaction { _ in UniversityProfile.install(profile) }
    }

    /// Installs the library's profile as the current one (when the library opens).
    public static func install(from database: any DatabaseReader) {
        do {
            let profile = try database.read { db in try profile(in: db) }
            UniversityProfile.install(profile)
        } catch {
            Log.database.error("University profile does not read: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Carry-over

    /// The Info.plist key a build sets to a university profile as one line of JSON
    /// (`SOCRATES_UNIVERSITY_PROFILE`, from a git-ignored `Config/Local.xcconfig`): the
    /// university values a library set up before the profile was data was used with. Empty in a
    /// build without it.
    public static let carryOverInfoKey = "SocratesUniversityProfile"

    /// The profile this build carries over (`carryOverInfoKey`), nil when it sets none.
    public static func carryOverProfile(bundle: Bundle = .main) -> UniversityProfile? {
        guard let value = bundle.object(forInfoDictionaryKey: carryOverInfoKey) as? String else { return nil }
        let json = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard json.hasPrefix("{") else { return nil }
        do {
            return try JSONDecoder().decode(UniversityProfile.self, from: Data(json.utf8))
        } catch {
            Log.database.error("The build's university profile does not decode: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Once per library: a library that has courses but no profile (set up before the profile
    /// was data) takes `profile`, the build's `carryOverProfile`, so it keeps working with the
    /// values it was used with. A new library (no courses) or one with a profile is left alone, and
    /// so is every library when the build carries nothing over. Dated 1970, so any profile the
    /// student sets later wins. Returns whether it wrote the row.
    @discardableResult
    public static func carryOver(_ profile: UniversityProfile?, into database: any DatabaseWriter) -> Bool {
        guard let profile else { return false }
        do {
            return try database.write { db in
                guard try stored(in: db) == nil, try Course.all.fetchCount(db) > 0 else { return false }
                let row = UniversityProfileRecord(profile: profile, updatedAt: Date(timeIntervalSince1970: 0))
                try UniversityProfileRecord.insert { row }.execute(db)
                return true
            }
        } catch {
            Log.database.error("University profile carry-over failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
