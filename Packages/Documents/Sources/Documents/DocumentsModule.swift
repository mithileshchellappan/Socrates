import Foundation
import os
import StudyCore
import UniformTypeIdentifiers

/// The document bank (md, docs/plan-docs.md). Logs through `DocumentsModule.log`; never logs a
/// document's text, title or file name at `.public`.
public enum DocumentsModule {
    public static let moduleName = "Documents"

    static let log = Log.logger(category: "documents")
}

/// Why a document could not be read: one readable sentence for the row's `error` and the screen
/// ("This Pages file has no preview to read. Export it as PDF in Pages and add that."), never a
/// Swift, PDFKit or Vision message (those go to the log).
public struct DocumentReadError: Error, Hashable, Sendable, LocalizedError, CustomStringConvertible {
    public var sentence: String

    public init(_ sentence: String) {
        self.sentence = sentence
    }

    public var errorDescription: String? { sentence }
    public var description: String { sentence }
}

/// One page of text as the extractor read it (`StudyDocumentPage` once stored).
public struct ExtractedPage: Hashable, Sendable {
    /// 1-based: a PDF's page, 1 for an image, a part of ≤ 4,000 characters of flowing text.
    public var pageNumber: Int
    /// The PDF page label when it differs from the number.
    public var label: String
    /// The section heading that starts on this page, when one was found.
    public var heading: String?
    public var text: String
    /// Read by Vision OCR.
    public var isOCR: Bool

    public init(pageNumber: Int, label: String = "", heading: String? = nil, text: String, isOCR: Bool = false) {
        self.pageNumber = pageNumber
        self.label = label
        self.heading = heading
        self.text = text
        self.isOCR = isOCR
    }
}

/// A document's text as the extractor read it.
public struct ExtractedDocument: Hashable, Sendable {
    public var pages: [ExtractedPage]
    /// The PDF's outline (empty for other files: the summary may find sections).
    public var outline: [DocumentSection]
    /// BCP 47 ("de", "en"), "" when unknown.
    public var language: String
    /// SHA-256 (hex) of the pages' text joined with "\n\n" (`document.text_sha256`).
    public var textSHA256: String

    public init(pages: [ExtractedPage], outline: [DocumentSection] = [], language: String = "", textSHA256: String) {
        self.pages = pages
        self.outline = outline
        self.language = language
        self.textSHA256 = textSHA256
    }
}
