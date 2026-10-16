// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Transcription",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "Transcription", targets: ["Transcription"])
    ],
    targets: [
        .target(name: "Transcription"),
    ],
    swiftLanguageModes: [.v6]
)
