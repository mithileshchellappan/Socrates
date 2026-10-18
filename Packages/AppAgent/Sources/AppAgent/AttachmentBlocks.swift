import ClaudeKit
import CoreGraphics
import Foundation
import ImageIO
import StudyCore
import UniformTypeIdentifiers

/// The student's files as content blocks (docs/plan-agent.md §4 "Attachments"), placed before
/// their words so the stored turn replays verbatim: images as image blocks (PNG, JPEG, GIF and
/// WebP as they are when the long edge is ≤ 1,568 px, anything else, HEIC included, re-encoded as
/// JPEG at that size), PDFs as document blocks (titled with the file name), text and code as a
/// `text`-source document titled with the file name. At most `AgentAttachment.maximumPerMessage`.
enum AttachmentBlocks {
    enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        case tooMany

        var description: String {
            switch self {
            case .unreadable(let name): "\(name) could not be read."
            case .tooMany: "At most \(AgentAttachment.maximumPerMessage) files per message."
            }
        }
    }

    static func blocks(_ attachments: [AgentAttachment], blobs: BlobStore) throws -> [ContentBlock] {
        guard attachments.count <= AgentAttachment.maximumPerMessage else { throw Failure.tooMany }
        return try attachments.map { attachment in
            let data: Data
            do {
                data = try blobs.data(for: attachment.blob)
            } catch {
                throw Failure.unreadable(attachment.fileName)
            }
            switch attachment.kind {
            case .image:
                guard let (bytes, mediaType) = image(data, contentType: attachment.contentType) else { throw Failure.unreadable(attachment.fileName) }
                return .image(bytes, mediaType: mediaType)
            case .pdf:
                return .pdf(data, title: attachment.fileName)
            case .text:
                guard let text = String(data: data, encoding: .utf8) else { throw Failure.unreadable(attachment.fileName) }
                return .document(DocumentBlock(source: .text(text), title: attachment.fileName))
            }
        }
    }

    /// The image as sent: the original when the API takes its type and its long edge fits, else a
    /// JPEG with the long edge at most `AgentAttachment.imageLongEdge` (ImageIO thumbnail, never
    /// decoded at full size on the main actor: callers run off it).
    static func image(_ data: Data, contentType: String) -> (Data, String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longEdge = max(width, height)
        let type = UTType(contentType)
        let passThrough: [(UTType, String)] = [(.png, "image/png"), (.jpeg, "image/jpeg"), (.gif, "image/gif"), (.webP, "image/webp")]
        if longEdge > 0, longEdge <= AgentAttachment.imageLongEdge, let type,
           let match = passThrough.first(where: { type.conforms(to: $0.0) }) {
            return (data, match.1)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: AgentAttachment.imageLongEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, "image/jpeg")
    }
}
