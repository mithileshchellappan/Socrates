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
        .package(path: "../StudyCore")
    ],
    targets: [
        .target(
            name: "Sync",
            dependencies: [.product(name: "StudyCore", package: "StudyCore")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
