// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Alignment",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "Alignment", targets: ["Alignment"]),
        // Ground truth and scoring for tools (tools/ProcessLecture). The app does not link it.
        .library(name: "AlignmentEvaluation", targets: ["AlignmentEvaluation"])
    ],
    targets: [
        // The aligner itself: pure Swift, no dependencies, no I/O besides SRT parsing of strings.
        .target(name: "Alignment"),
        // Fixture loading, ground truth and scoring for the eval CLI; not a product.
        .target(name: "AlignmentEvaluation", dependencies: ["Alignment"]),
        // `swift run -c release --package-path Packages/Alignment alignment-eval` prints the eval tables.
        .executableTarget(name: "alignment-eval", dependencies: ["Alignment", "AlignmentEvaluation"]),
    ],
    swiftLanguageModes: [.v6]
)
