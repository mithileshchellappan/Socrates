import CoreTransferable
import Foundation

/// A capture to share as a bundle (the iPhone's Share / AirDrop to the Mac, M7). The bundle is
/// written when the student picks where it goes, into its own folder under
/// `CaptureBundle.temporaryDirectory`; nothing is kept with the capture, and old bundles are
/// removed at the next share (and at launch, `CaptureBundle.removeTemporaryBundles(olderThan: 0)`).
public struct CaptureBundleItem: Transferable, Sendable {
    public var package: LecturePackage
    /// The bundle's name without its extension ("DC Lecture 2").
    public var title: String

    public init(package: LecturePackage, title: String) {
        self.package = package
        self.title = title
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: CaptureBundle.contentType) { item in
            SentTransferredFile(try await item.writeTemporaryBundle(), allowAccessingOriginalFile: true)
        }
    }

    /// Writes the bundle off the main actor (a 90-minute recording is about 520 MB).
    @concurrent
    nonisolated func writeTemporaryBundle() async throws -> URL {
        CaptureBundle.removeTemporaryBundles(olderThan: 3600)
        let folder = CaptureBundle.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: CaptureBundle.fileName(for: title), directoryHint: .notDirectory)
        return try CaptureBundle.write(package: package, to: url)
    }
}
