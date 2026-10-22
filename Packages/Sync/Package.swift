// swift-tools-version: 6.2
import PackageDescription

// M7 workstream A (docs/plan-m7.md §4, §5.1): iCloud sync of the library (SQLiteData's
// `SyncEngine` over the library tables), behind `CloudSyncConfiguration`: it runs only in a build
// signed with the iCloud entitlement. No UI.
let package = Package(
    name: "Sync",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "Sync", targets: ["Sync"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        // `TransactionObserver`, `Row` and the backup API (SQLiteData re-exports only a few GRDB types).
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.6.0"),
    ],
    targets: [
        .target(
            name: "Sync",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
