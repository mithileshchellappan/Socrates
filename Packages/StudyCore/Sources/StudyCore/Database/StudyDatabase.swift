import Foundation
import SQLiteData

/// Opens and migrates the app database.
///
/// The returned `DatabaseWriter` is what the app installs as SQLiteData's `defaultDatabase`
/// (so views can use `@FetchAll` / `@FetchOne`) and what repositories write through.
public enum StudyDatabase {
    /// Opens (creating if needed) the on-disk database in WAL mode and runs migrations.
    ///
    /// `syncContainer` (M7): the CloudKit container of a build configured for iCloud sync
    /// (`CloudSyncConfiguration.containerIdentifier()`); SQLiteData's sync metadatabase is then
    /// attached on every connection, as its `SyncEngine` requires. Nil (every build without the
    /// iCloud entitlement): nothing is attached and the database opens exactly as before.
    ///
    /// `carryOver` (oss): true only for the student's real library (`StudyServices.live` without
    /// a data-root override), which then takes the build's university profile once
    /// (`UniversityProfileRecord.carryOver`). Demo, parity and snapshot libraries never do, so they
    /// show what any build shows.
    public static func open(at url: URL, syncContainer: String? = nil, carryOver: Bool = false) throws -> any DatabaseWriter {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var configuration = configuration()
        if let syncContainer {
            configuration.prepareDatabase { db in
                try db.attachMetadatabase(containerIdentifier: syncContainer)
            }
        }
        let pool = try DatabasePool(path: url.path(percentEncoded: false), configuration: configuration)
        try Schema.migrator().migrate(pool)
        // The real library, set up before the profile was data, keeps the values it was used
        // with, once (only builds that carry a profile over, `UniversityProfileRecord.carryOverInfoKey`).
        if carryOver {
            UniversityProfileRecord.carryOver(UniversityProfileRecord.carryOverProfile(), into: pool)
        }
        // The student's university (time zone, prompts, the coach's rules) for everything that
        // reads `UniversityProfile.current`.
        UniversityProfileRecord.install(from: pool)
        Log.database.info("Opened database at \(url.path(percentEncoded: false), privacy: .public)")
        return pool
    }

    /// M7: a new synced library on the iPhone drops the semester the migrations seeded (fixed id
    /// `Semester.seededID`, never edited: placeholder values) before it first syncs. A row with a
    /// fixed id that never synced takes the server's values wholesale, and the first device to
    /// upload one wins: had the phone uploaded its placeholder first, the Mac's real semester
    /// (name, dates, breaks, time zone) would have been overwritten. Without it the Mac's row
    /// comes down, and `Semester.placeholder` covers the gap meanwhile. Runs before any sync
    /// trigger exists, so nothing is sent.
    public static func removeSeededSemester(from database: any DatabaseWriter) throws {
        try database.write { db in
            try db.execute(
                sql: #"DELETE FROM "semester" WHERE "id" = ? AND "updated_at" = '1970-01-01 00:00:00.000'"#,
                arguments: [Semester.seededID.uuidString.lowercased()]
            )
        }
    }

    /// A migrated in-memory database for tests and previews.
    public static func inMemory() throws -> any DatabaseWriter {
        let queue = try DatabaseQueue(configuration: configuration())
        try Schema.migrator().migrate(queue)
        return queue
    }

    public static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.label = "StudyPortal"
        return configuration
    }
}
