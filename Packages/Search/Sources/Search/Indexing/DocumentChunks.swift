import Foundation
import StudyCore

// md (docs/plan-docs.md §4 "Search"): the student's kept documents in search.

extension ChunkBuilder {
    /// The longest window of a document page (characters).
    static let documentWindow = 600

    /// A kept document's pages cut into windows of at most `documentWindow` characters at
    /// paragraph or sentence ends, each a chunk of kind `document` with its page (`page_number`),
    /// `source_id` = `document_id` = the document, and never a `course_id` (a course delete must
    /// not cascade them, nor a re-cut fail on a course that is gone; the document's courses are
    /// `document.course_ids`).
    func documentChunks(document: StudyDocument, pages: [StudyDocumentPage], version: Date, now: Date) -> [ChunkRow] {
        let known = document.language.prefix(2).lowercased()
        let stated = known == "de" || known == "en"
        var drafts: [ChunkRow] = []
        for page in pages.sorted(by: { $0.pageNumber < $1.pageNumber }) {
            for text in Self.windows(of: page.text) {
                let language = stated ? known : lemmatizer.language(of: text, fallback: "en")
                drafts.append(ChunkRow(
                    kind: .document,
                    sourceID: document.id,
                    pageNumber: page.pageNumber,
                    documentID: document.id,
                    lang: language,
                    text: text,
                    lemmaText: lemmatizer.lemmaText(of: text, language: language),
                    sourceUpdatedAt: version,
                    updatedAt: now
                ))
            }
        }
        return drafts
    }

    /// A page's text as windows of at most `documentWindow` characters: whole paragraphs while
    /// they fit, a longer paragraph by its sentences, a longer sentence at spaces. Whitespace runs
    /// read as one space (a snippet is one paragraph).
    static func windows(of text: String) -> [String] {
        let limit = documentWindow
        var pieces: [String] = []
        for paragraph in text.split(whereSeparator: \.isNewline) {
            let flat = paragraph.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !flat.isEmpty else { continue }
            if flat.count <= limit {
                pieces.append(flat)
                continue
            }
            var sentence = ""
            for character in flat {
                sentence.append(character)
                if ".!?;".contains(character) {
                    pieces += hardCut(sentence.trimmingCharacters(in: .whitespaces), limit: limit)
                    sentence = ""
                }
            }
            pieces += hardCut(sentence.trimmingCharacters(in: .whitespaces), limit: limit)
        }
        var windows: [String] = []
        var current = ""
        for piece in pieces where !piece.isEmpty {
            if current.isEmpty {
                current = piece
            } else if current.count + 1 + piece.count <= limit {
                current += " " + piece
            } else {
                windows.append(current)
                current = piece
            }
        }
        if !current.isEmpty { windows.append(current) }
        return windows
    }

    /// `text` in parts of at most `limit` characters, cut at spaces where it can.
    static func hardCut(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return text.isEmpty ? [] : [text] }
        var parts: [String] = []
        var rest = Substring(text)
        while rest.count > limit {
            let window = rest.prefix(limit)
            var cut = window.endIndex
            if let space = window.lastIndex(where: \.isWhitespace), window.distance(from: window.startIndex, to: space) > limit / 2 {
                cut = space
            }
            parts.append(String(rest[rest.startIndex..<cut]).trimmingCharacters(in: .whitespaces))
            rest = rest[cut...].drop(while: \.isWhitespace)
        }
        if !rest.isEmpty { parts.append(String(rest)) }
        return parts.filter { !$0.isEmpty }
    }
}
