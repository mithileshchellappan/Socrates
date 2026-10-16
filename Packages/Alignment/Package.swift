// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Alignment",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "Alignment", targets: ["Alignment"])
    ],
    targets: [
        .target(name: "Alignment"),
    ],
    swiftLanguageModes: [.v6]
)
