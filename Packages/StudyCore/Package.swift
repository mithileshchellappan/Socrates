// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StudyCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "StudyCore", targets: ["StudyCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.12.1")
    ],
    targets: [
        .target(
            name: "StudyCore",
            dependencies: [.product(name: "SQLiteData", package: "sqlite-data")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
