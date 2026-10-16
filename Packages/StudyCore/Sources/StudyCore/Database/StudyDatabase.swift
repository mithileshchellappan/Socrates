import Foundation
import SQLiteData

/// Opens and migrates the app database.
///
/// The returned `DatabaseWriter` is what the app installs as SQLiteData's `defaultDatabase`
/// (so views can use `@FetchAll` / `@FetchOne`) and what repositories write through.
public enum StudyDatabase {
    /// Opens (creating if needed) the on-disk database in WAL mode and runs migrations.
    public static func open(at url: URL) throws -> any DatabaseWriter {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: url.path(percentEncoded: false), configuration: configuration())
        try Schema.migrator().migrate(pool)
        Log.database.info("Opened database at \(url.path(percentEncoded: false), privacy: .public)")
        return pool
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
