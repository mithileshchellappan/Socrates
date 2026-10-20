import Foundation
import SQLiteData

/// The shared services the app wires up at launch and hands to feature modules.
public struct StudyServices: Sendable {
    public let paths: AppPaths
    public let database: any DatabaseWriter
    public let blobs: BlobStore
    public let secrets: any SecretStore
    /// M7: the CloudKit container this library was opened for (SQLiteData's metadatabase is
    /// attached), or nil: this library never syncs. Only `live(syncContainer:)` sets it, and only
    /// for the student's real library.
    public let syncContainer: String?

    public init(
        paths: AppPaths, database: any DatabaseWriter, blobs: BlobStore, secrets: any SecretStore,
        syncContainer: String? = nil
    ) {
        self.paths = paths
        self.database = database
        self.blobs = blobs
        self.secrets = secrets
        self.syncContainer = syncContainer
    }

    /// Real directories, on-disk database (migrated) and the Keychain.
    ///
    /// `syncContainer` (M7): the CloudKit container when this build syncs
    /// (`CloudSyncConfiguration.containerIdentifier()`); nil opens the database as before. Only
    /// the real library syncs: with a data-root override (`SOCRATES_DATA_ROOT`: a scratch,
    /// demo or parity library) the container is dropped, so such a library never uploads its rows
    /// into the student's iCloud data nor sends its deletes there (`syncContainer` stays nil and
    /// so does `CloudSync`). On iOS a syncing build opens `syncedDatabase`: SQLiteData's first
    /// sync uploads every row already in the file, and the phone's pre-sync library (seeded
    /// courses with their own ids) would duplicate the Mac's. Its captures are files
    /// (`phoneCaptures`), so nothing is left behind. Only the real library takes the build's
    /// university profile (`StudyDatabase.open(carryOver:)`).
    public static func live(syncContainer: String? = nil) throws -> StudyServices {
        let paths = try AppPaths.live()
        try paths.createDirectories()
        let isRealLibrary = try paths.root == AppPaths.live(environment: [:]).root
        let container = isRealLibrary ? syncContainer : nil
        #if os(iOS)
        let file = container == nil ? paths.database : paths.syncedDatabase
        let isNewReplica = container != nil && !FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
        #else
        let file = paths.database
        #endif
        let database = try StudyDatabase.open(at: file, syncContainer: container, carryOver: isRealLibrary)
        #if os(iOS)
        if isNewReplica {
            try StudyDatabase.removeSeededSemester(from: database)
        }
        #endif
        return StudyServices(
            paths: paths,
            database: database,
            blobs: BlobStore(root: paths.blobs),
            secrets: KeychainSecretStore(),
            syncContainer: container
        )
    }

    /// In-memory database, temporary directories, no Keychain. For tests and previews.
    public static func inMemory() throws -> StudyServices {
        let root = URL.temporaryDirectory.appending(path: "Socrates-\(UUID().uuidString)", directoryHint: .isDirectory)
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
