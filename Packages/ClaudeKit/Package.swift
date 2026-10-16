// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClaudeKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ClaudeKit", targets: ["ClaudeKit"])
    ],
    targets: [
        .target(name: "ClaudeKit"),
    ],
    swiftLanguageModes: [.v6]
)
