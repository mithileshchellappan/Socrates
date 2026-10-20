import CoreGraphics
import Foundation
import QuickLookThumbnailing
import StudyCore

/// The original file of a kept document as Quick Look and the file tile see it (off the main
/// actor; the file in the BlobStore is never changed).
enum DocumentFiles {
    /// A first-page thumbnail fitting `size` (points) at `scale`; nil when Quick Look has none.
    @concurrent
    static func thumbnail(at url: URL, size: CGSize, scale: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        do {
            return try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
        } catch {
            return nil
        }
    }

    /// Where Quick Look opens a document: a link named as the student's file ("Modulhandbuch.pdf",
    /// so the panel's title is the name, not the blob's hash) in a temporary folder of its own,
    /// removed again when the panel closes (`removePreview`); the blob itself when no link can be
    /// made.
    static func previewURL(for document: StudyDocument, blobs: BlobStore) -> URL? {
        guard let blob = document.blob else { return nil }
        let original = blobs.url(for: blob)
        guard FileManager.default.fileExists(atPath: original.path) else { return nil }
        let name = (document.fileName as NSString).lastPathComponent
        guard !name.isEmpty, !name.hasPrefix(".") else { return original }
        let folder = previewRoot.appending(path: document.id.uuidString, directoryHint: .isDirectory)
        let link = folder.appending(path: name, directoryHint: .notDirectory)
        do {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
            return link
        } catch {
            return original
        }
    }

    /// Removes a preview link made by `previewURL` (never the blob).
    static func removePreview(_ url: URL) {
        guard url.path.hasPrefix(previewRoot.path) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private static var previewRoot: URL {
        FileManager.default.temporaryDirectory.appending(path: "Socrates Documents", directoryHint: .isDirectory)
    }
}
