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
    ///
    /// `syncContainer` (M7): the CloudKit container when this build syncs
    /// (`CloudSyncConfiguration.containerIdentifier()`); nil opens the database as before. On iOS
    /// a syncing build opens `syncedDatabase`: SQLiteData's first sync uploads every row already
    /// in the file, and the phone's pre-sync library (seeded courses with their own ids) would
    /// duplicate the Mac's. Its captures are files (`phoneCaptures`), so nothing is left behind.
    /// Only the real library (no `STUDYPORTAL_DATA_ROOT` override) takes the build's university
    /// profile (`StudyDatabase.open(carryOver:)`).
    public static func live(syncContainer: String? = nil) throws -> StudyServices {
        let paths = try AppPaths.live()
        try paths.createDirectories()
        let isRealLibrary = try paths.root == AppPaths.live(environment: [:]).root
        #if os(iOS)
        let file = syncContainer == nil ? paths.database : paths.syncedDatabase
        #else
        let file = paths.database
        #endif
        return StudyServices(
            paths: paths,
            database: try StudyDatabase.open(at: file, syncContainer: syncContainer, carryOver: isRealLibrary),
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
