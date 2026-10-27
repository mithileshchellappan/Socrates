import ClaudeKit
import Foundation
import StudyCore

/// A file a stored turn sends by reference (docs/decisions.md, 2026-10-27): an image or document
/// block whose source names the bytes that were sent, kept in the BlobStore, instead of carrying
/// them as base64 or text. A turn with a photo, a PDF or large text files stays far under iCloud's
/// 1 MB record and reaches the phone. Stored as `{"type": "blob", "media_type": …, "sha256": …,
/// "relative_path": …}`, a source the API does not know: a turn sent without its bytes is refused,
/// never misread.
///
/// `AgentRuntime` builds the source again from those bytes before every request
/// (`MessageParam.sendable(blobs:)`): base64 as ClaudeKit's `.image` and `.pdf` make it
/// (`Data.base64EncodedString()`), and for `plainText` the `text` source of the bytes read as
/// UTF-8, as the sender read them. Claude receives what a turn holding the base64 or the text
/// carried, byte for byte.
extension BlockSource {
    /// The media type of a text file or a document's text sent by reference: sent as a `text`
    /// source.
    public static let plainText = "text/plain"

    /// The source of a block that sends `blob`'s bytes, of `mediaType` ("image/jpeg",
    /// "application/pdf", `plainText`). The sender keeps the blob named in the turn's
    /// `agent_turn.context`, so `BlobUsage` never removes it.
    public static func blob(_ blob: BlobRef, mediaType: String) -> BlockSource {
        .other([
            "type": "blob",
            "media_type": .string(mediaType),
            "sha256": .string(blob.sha256),
            "relative_path": .string(blob.relativePath),
        ])
    }

    /// The blob this source names, and its media type; nil for any other source.
    var storedBlob: (blob: BlobRef, mediaType: String)? {
        guard case .other(let object) = self, object["type"]?.stringValue == "blob",
              let mediaType = object["media_type"]?.stringValue,
              let sha256 = object["sha256"]?.stringValue,
              let relativePath = object["relative_path"]?.stringValue
        else { return nil }
        return (BlobRef(sha256: sha256, relativePath: relativePath), mediaType)
    }

    /// The source as sent: a stored blob's bytes as base64, or as a `text` source for
    /// `plainText`; any other source as it is. Throws `BlobStoreError.missing` when the file is
    /// gone.
    func sendable(blobs: BlobStore) throws -> BlockSource {
        guard let stored = storedBlob else { return self }
        let data = try blobs.data(for: stored.blob)
        guard stored.mediaType == Self.plainText else { return .base64(mediaType: stored.mediaType, data: data.base64EncodedString()) }
        // The sender checked the bytes are UTF-8; they are content-addressed, so they still are.
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return .text(text)
    }
}

extension MessageParam {
    /// The turn as sent: its image and document blocks that store their file by reference carry
    /// the bytes (or the text) again (`BlockSource.blob`); a turn without one is returned as it is.
    func sendable(blobs: BlobStore) throws -> MessageParam {
        guard case .blocks(let blocks) = content, blocks.contains(where: \.storesBlob) else { return self }
        var sent = self
        sent.content = .blocks(try blocks.map { block in
            switch block {
            case .image(var image):
                image.source = try image.source.sendable(blobs: blobs)
                return .image(image)
            case .document(var document):
                document.source = try document.source.sendable(blobs: blobs)
                return .document(document)
            default:
                return block
            }
        })
        return sent
    }
}

private extension ContentBlock {
    var storesBlob: Bool {
        switch self {
        case .image(let image): image.source.storedBlob != nil
        case .document(let document): document.source.storedBlob != nil
        default: false
        }
    }
}
