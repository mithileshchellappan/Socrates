import Foundation
import StudyCore
import UniformTypeIdentifiers
#if os(macOS)
// Word, OpenDocument and RTF reading (`NSAttributedString` document types) is AppKit's on the Mac;
// the internal import keeps it out of Documents' interface. Nothing here draws.
internal import AppKit
#endif

// The Mac-only readers (docs/plan-docs.md §4 "Text"): Word .docx/.doc, OpenDocument text and RTF
// through `NSAttributedString`, Pages through the preview PDF inside the file. The iPhone never
// reads documents (they never sync); there these throw `DocumentReadError.macOnly`.
extension DocumentExtractor {
    /// Word, OpenDocument text or RTF as flowing text, cut into parts at paragraph ends. A
    /// paragraph set large (≥ 14 pt) or bold, short and not ending like a sentence counts as a
    /// heading.
    static func readAttributed(at url: URL, type: UTType) throws -> RawText {
        #if os(macOS)
        let documentType: NSAttributedString.DocumentType
        if type.conforms(to: .rtfd) {
            documentType = .rtfd
        } else if type.conforms(to: .rtf) {
            documentType = .rtf
        } else if type.identifier == "com.microsoft.word.doc" || UTType("com.microsoft.word.doc").map(type.conforms(to:)) == true {
            documentType = .docFormat
        } else if UTType("org.oasis-open.opendocument.text").map(type.conforms(to:)) == true {
            documentType = .openDocument
        } else {
            documentType = .officeOpenXML
        }
        let string: NSAttributedString
        do {
            string = try NSAttributedString(url: url, options: [.documentType: documentType], documentAttributes: nil)
        } catch {
            DocumentsModule.log.error("Reading a \(documentType.rawValue, privacy: .public) file failed: \(String(describing: error), privacy: .private)")
            throw DocumentReadError.unreadable
        }
        let text = string.string
        var lines: [Line] = []
        var location = 0
        for paragraph in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\u{2029}" || $0 == "\u{000C}" }) {
            let length = paragraph.utf16.count
            var isHeading = false
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, trimmed.count <= 120, location < string.length, let last = trimmed.last, !".,;:".contains(last) {
                if let font = string.attribute(.font, at: location, effectiveRange: nil) as? NSFont {
                    isHeading = font.pointSize >= 14 || font.fontDescriptor.symbolicTraits.contains(.bold)
                }
            }
            lines.append(Line(text: clean(String(paragraph)), isHeading: isHeading))
            location += length + 1
        }
        return RawText(pages: parts(of: lines))
        #else
        throw DocumentReadError.macOnly
        #endif
    }

    /// A Pages document: its `QuickLook/Preview.pdf` (in the package, or in the single-file zip)
    /// read as a PDF; without one, the readable refusal.
    static func readPages(at url: URL) async throws -> RawText {
        #if os(macOS)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
            throw DocumentReadError.missing
        }
        if isDirectory.boolValue {
            let preview = url.appending(path: "QuickLook/Preview.pdf")
            guard fileManager.fileExists(atPath: preview.path(percentEncoded: false)) else { throw DocumentReadError.pagesWithoutPreview }
            return try await readPDF(at: preview)
        }
        let directory = fileManager.temporaryDirectory.appending(path: "StudyPortal-pages-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: directory) }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DocumentReadError.unreadable
        }
        let preview = directory.appending(path: "QuickLook/Preview.pdf")
        guard await unzip(url, entry: "QuickLook/Preview.pdf", into: directory),
              fileManager.fileExists(atPath: preview.path(percentEncoded: false))
        else { throw DocumentReadError.pagesWithoutPreview }
        return try await readPDF(at: preview)
        #else
        throw DocumentReadError.macOnly
        #endif
    }

    #if os(macOS)
    /// Extracts one entry of a zip file with `/usr/bin/unzip`; false when it is not there.
    static func unzip(_ archive: URL, entry: String, into directory: URL) async -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/unzip")
        process.arguments = ["-qq", "-o", archive.path(percentEncoded: false), entry, "-d", directory.path(percentEncoded: false)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { ended in continuation.resume(returning: ended.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                DocumentsModule.log.error("unzip did not start: \(String(describing: error), privacy: .public)")
                continuation.resume(returning: false)
            }
        }
    }

    /// A Pages package (a folder) as one file the BlobStore can keep: the single-file Pages format
    /// (a zip of the package's contents, as Pages itself writes it) at `destination`.
    static func zipPackage(_ package: URL, to destination: URL) async -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", package.path(percentEncoded: false), destination.path(percentEncoded: false)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { ended in continuation.resume(returning: ended.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                DocumentsModule.log.error("ditto did not start: \(String(describing: error), privacy: .public)")
                continuation.resume(returning: false)
            }
        }
    }
    #endif
}
