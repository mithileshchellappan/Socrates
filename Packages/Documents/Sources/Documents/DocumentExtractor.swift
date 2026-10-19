import Foundation
import StudyCore
import UniformTypeIdentifiers

/// Reads a document's text per page (docs/plan-docs.md §4 "Text"): PDF with PDFKit (Vision OCR for
/// pages with almost no text), Word / OpenDocument / RTF with `NSAttributedString` (Mac), Pages
/// through the preview PDF inside the file, plain text and Markdown, images by Vision OCR. One
/// page in memory at a time; called off the main actor.
///
/// Contract skeleton (md architect): workstream A builds it.
public enum DocumentExtractor {
    /// Characters per part when flowing text (Word, RTF, text) is cut into "pages".
    public static let partLength = 4_000

    /// The text of the file at `url` (a BlobStore file or a dropped file), or a `DocumentReadError`
    /// with the readable sentence.
    public static func extract(fileAt url: URL, type: UTType) async throws -> ExtractedDocument {
        _ = (url, type)
        throw DocumentReadError("This file can’t be read yet.")
    }
}
