import Foundation
import SQLiteData

/// The shared services the app wires up at launch and hands to feature modules.
public struct StudyServices: Sendable {
    public let paths: AppPaths
    public let database: any DatabaseWriter
    public let blobs: BlobStore
    public let secrets: any SecretStore

    public init(paths: AppPaths, database: any DatabaseWriter, blobs: BlobStore, secrets: any SecretStore) {
        self.paths = paths
        self.database = database
        self.blobs = blobs
        self.secrets = secrets
    }

    /// Real directories, on-disk database (migrated) and the Keychain.
    public static func live() throws -> StudyServices {
        let paths = try AppPaths.live()
        try paths.createDirectories()
        return StudyServices(
            paths: paths,
            database: try StudyDatabase.open(at: paths.database),
            blobs: BlobStore(root: paths.blobs),
            secrets: KeychainSecretStore()
        )
    }

    /// In-memory database, temporary directories, no Keychain. For tests and previews.
    public static func inMemory() throws -> StudyServices {
        let root = URL.temporaryDirectory.appending(path: "StudyPortal-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = AppPaths(root: root)
        return StudyServices(
            paths: paths,
            database: try StudyDatabase.inMemory(),
            blobs: BlobStore(root: paths.blobs),
            secrets: InMemorySecretStore()
        )
    }

    public var records: RecordStore { RecordStore(database: database) }
}
