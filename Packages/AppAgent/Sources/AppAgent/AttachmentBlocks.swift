import Agent
import ClaudeKit
import CoreGraphics
import Documents
import Filing
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
    enum Failure: Error, CustomStringConvertible, LocalizedError {
        case unreadable(String)
        case tooMany
        /// A PDF sent whole over the document limits (slides are filed instead).
        case pdfTooLarge(String)
        /// md: a Word, RTF or Pages file whose text could not be read (the extractor's sentence).
        case refused(String, String)

        var description: String {
            switch self {
            case .unreadable(let name): "\(name) could not be read."
            case .refused(let name, let sentence): "\(name): \(sentence)"
            case .tooMany: "At most \(AgentAttachment.maximumPerMessage) files per message."
            case .pdfTooLarge(let name):
                "\(name) is too long to read whole (at most \(AgentAttachment.maximumPDFPages) pages and \(AgentAttachment.maximumPDFBytes / 1_048_576) MB)."
            }
        }

        var errorDescription: String? { description }
    }

    /// `<filed filing="…" change="1a2b3c4d" file="Lecture3.pdf" placed="DC · L3 · Virtualization">reason</filed>`:
    /// stands in the user turn for slides the agent filed instead of sending them (data).
    static func filed(_ filed: AdvisedFiling, fileName: String, reason: String) -> ContentBlock {
        var head = AgentAttachment.filedBlockOpening
        if let filing = filed.outcome.filing { head += " filing=\"\(filing.id.uuidString.lowercased())\"" }
        if let change = filed.change { head += " change=\"\(change.id.uuidString.lowercased().prefix(8))\"" }
        head += " file=\"\(AgentXML.escape(fileName))\" placed=\"\(AgentXML.escape(filed.placed))\""
        return .text(TextBlock(text: head + ">" + AgentXML.escape(reason) + "</filed>"))
    }

    /// md: every attachment as it goes to Claude (`AppAgent.send`): a Word, OpenDocument, RTF or
    /// Pages file (`.document`) as its extracted text in a text document block titled with the
    /// file name (≤ `documentCharacters`, then "…"; refused with the extractor's readable
    /// sentence), a PDF over the send limits (not slides: those were filed) as `<attached_file>`
    /// with its first pages' text (≤ `attachedFileCharacters`, so `keep_document` can still keep
    /// it), the rest as `blocks`.
    static func contentBlocks(_ attachments: [AgentAttachment], blobs: BlobStore) async throws -> [ContentBlock] {
        guard attachments.count <= AgentAttachment.maximumPerMessage else { throw Failure.tooMany }
        var result: [ContentBlock] = []
        for attachment in attachments {
            switch attachment.kind {
            case .document:
                result.append(try await documentText(attachment, blobs: blobs))
            case .pdf where sentAsText(attachment):
                guard blobs.contains(attachment.blob),
                      let leading = await DocumentExtractor.leadingText(ofPDFAt: blobs.url(for: attachment.blob), characters: attachedFileCharacters)
                else { throw Failure.unreadable(attachment.fileName) }
                let head = "<attached_file name=\"\(AgentXML.escape(attachment.fileName))\" pages=\"\(leading.pageCount)\">"
                result.append(.text(TextBlock(text: head + "\n" + AgentXML.escape(leading.text) + "\n</attached_file>")))
            default:
                result += try blocks([attachment], blobs: blobs)
            }
        }
        return result
    }

    /// Whether `contentBlocks` sends the attachment as its extracted text (a `.document`, or a PDF
    /// over the send limits as `<attached_file>`): document text, untrusted (`AppAgent.send`).
    static func sentAsText(_ attachment: AgentAttachment) -> Bool {
        attachment.kind == .document
            || (attachment.kind == .pdf
                && (attachment.byteCount > AgentAttachment.maximumPDFBytes || (attachment.pageCount ?? 0) > AgentAttachment.maximumPDFPages))
    }

    /// The most text of a Word, RTF or Pages attachment sent, and of a long PDF's first pages.
    static let documentCharacters = 100_000
    static let attachedFileCharacters = 8_000

    /// A `.document` attachment's text (Documents' extractor, off the main actor), in a text
    /// document block titled with the file name.
    static func documentText(_ attachment: AgentAttachment, blobs: BlobStore) async throws -> ContentBlock {
        guard blobs.contains(attachment.blob) else { throw Failure.unreadable(attachment.fileName) }
        let type = UTType(attachment.contentType) ?? UTType(filenameExtension: (attachment.fileName as NSString).pathExtension) ?? .data
        let extracted: ExtractedDocument
        do {
            extracted = try await DocumentExtractor.extract(fileAt: blobs.url(for: attachment.blob), type: type)
        } catch let error as DocumentReadError {
            throw Failure.refused(attachment.fileName, error.sentence)
        } catch {
            throw Failure.unreadable(attachment.fileName)
        }
        var text = extracted.pages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        if text.count > documentCharacters { text = String(text.prefix(documentCharacters)) + "…" }
        return .document(DocumentBlock(source: .text(text), title: attachment.fileName))
    }

    static func blocks(_ attachments: [AgentAttachment], blobs: BlobStore) throws -> [ContentBlock] {
        guard attachments.count <= AgentAttachment.maximumPerMessage else { throw Failure.tooMany }
        return try attachments.map { attachment in
            if attachment.kind == .pdf,
               attachment.byteCount > AgentAttachment.maximumPDFBytes || (attachment.pageCount ?? 0) > AgentAttachment.maximumPDFPages {
                throw Failure.pdfTooLarge(attachment.fileName)
            }
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
            case .document:
                // Read by `contentBlocks` (its extracted text); never sent as bytes.
                throw Failure.unreadable(attachment.fileName)
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
