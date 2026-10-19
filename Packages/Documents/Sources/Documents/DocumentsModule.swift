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

/// Escaping of the document text and names a model reads as delimited data (`<document>`,
/// `<page>`): `&`, `<`, `>` and `"`, so nothing in a document can close or open an element.
public enum DocumentXML {
    public static func escape(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            default: output.append(character)
            }
        }
        return output
    }
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

    // The readable sentences (plan §4; DESIGN 9 strings).
    public static let noText = DocumentReadError("No text found in this file.")
    public static let unreadable = DocumentReadError("This file could not be read.")
    public static let missing = DocumentReadError("The file is no longer there.")
    public static let tooLarge = DocumentReadError("This file is larger than 200 MB.")
    public static let unsupported = DocumentReadError("This kind of file can’t be kept in Documents.")
    public static let pagesWithoutPreview = DocumentReadError(
        "This Pages file has no preview to read. Export it as PDF in Pages and add that.")
    /// The iPhone reads no Word, RTF or Pages files (documents never sync; the phone has no bank).
    public static let macOnly = DocumentReadError("Word, RTF and Pages files are read on the Mac.")
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
