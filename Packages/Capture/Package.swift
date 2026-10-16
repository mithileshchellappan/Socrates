// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Capture",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "Capture", targets: ["Capture"])
    ],
    targets: [
        .target(name: "Capture"),
    ],
    swiftLanguageModes: [.v6]
)
