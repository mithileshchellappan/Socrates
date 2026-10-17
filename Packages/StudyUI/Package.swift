// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StudyUI",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        // Shared SwiftUI pieces every screen uses: course colour, times in SF Mono, jump-to-time and
        // slide chips, provenance marks, and the navigation contract between feature modules and the
        // app (`StudyDestination`, `openDestination`, `studyServices`).
        .library(name: "StudyUI", targets: ["StudyUI"]),
    ],
    dependencies: [
        .package(path: "../StudyCore")
    ],
    targets: [
        .target(
            name: "StudyUI",
            dependencies: [.product(name: "StudyCore", package: "StudyCore")]
        ),

    ],
    swiftLanguageModes: [.v6]
)
