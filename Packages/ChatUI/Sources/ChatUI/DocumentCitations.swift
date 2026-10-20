import Foundation
import StudyCore
import StudyUI
import SwiftUI

// md (docs/plan-docs.md §5.2): a kept document's marker in an answer, `[[doc 3f2a9c1e p12]]` (a
// page) or `[[doc 3f2a9c1e]]` (the document), becomes a chip only after it is checked against the
// `document` rows: the key names exactly one document and the page is one of its pages. The chip
// is web's shape with `doc.on.doc` for the globe: "p. 12" (without a page: the title, clipped to
// 24), its help the title; it opens the Documents screen with the document at that page. Anything
// else is dropped and logged with its rule (`CitationCheck.Drop`). The iPhone has no documents
// (they never sync), so there every document marker is dropped.

/// A kept document as its markers are checked.
struct DocumentCitationRow: Equatable, Sendable {
    var id: StudyDocument.ID
    var title: String
    var pageCount: Int
}

enum DocumentCitations {
    /// The chip's glyph (the Documents row's; never notes' `doc.text`).
    static let glyph = "doc.on.doc"
    /// A chip without a page shows the title up to this many characters.
    static let titleLimit = 24

    /// The kept documents by key (`ChatCitation.key`); a key two documents share names neither.
    static func rows(_ db: Database) throws -> [String: [DocumentCitationRow]] {
        var rows: [String: [DocumentCitationRow]] = [:]
        for document in try StudyDocument.all.fetchAll(db) {
            rows[document.key, default: []].append(DocumentCitationRow(id: document.id, title: document.title, pageCount: document.pageCount))
        }
        return rows
    }

    /// The marker's check: exactly one document has the key; a page lies within its pages.
    static func check(key: String, page: Int?, rows: CitationRows) -> Result<CheckedCitation, CitationCheck.DropError> {
        guard rows.isLoaded else { return .failure(CitationCheck.DropError(.notLoaded)) }
        let matches = rows.documents[key] ?? []
        guard !matches.isEmpty else { return .failure(CitationCheck.DropError(.unknownDocument)) }
        guard matches.count == 1, let document = matches.first else { return .failure(CitationCheck.DropError(.ambiguousDocument)) }
        if let page, page < 1 || page > document.pageCount {
            return .failure(CitationCheck.DropError(.pageOutsideDocument))
        }
        return .success(.document(id: document.id, page: page, title: document.title))
    }

    /// "p. 12"; without a page the title, clipped to 24 characters ("Modulhandbuch M.Sc. Inf…").
    static func label(page: Int?, title: String) -> String {
        if let page { return "p.\u{00A0}\(page)" }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > titleLimit else { return trimmed }
        return String(trimmed.prefix(titleLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "socrates-cite://doc/<document>/12" ("-" without a page).
    static func link(id: StudyDocument.ID, page: Int?) -> URL? {
        URL(string: "\(AnswerText.linkScheme)://doc/\(id.uuidString.lowercased())/\(page.map(String.init) ?? "-")")
    }

    /// Where a document chip's link goes: the Documents screen with it selected, at its page.
    static func destination(linkParts parts: [String]) -> StudyDestination? {
        guard parts.count == 2, let id = UUID(uuidString: parts[0]) else { return nil }
        return .documents(id, page: Int(parts[1]))
    }

    /// The help over a run of text with document chips: their titles (a chip is a run of one
    /// `Text`, which has no help of its own).
    static func help(_ answer: AnswerText) -> String? {
        var titles: [String] = []
        for chip in answer.chips {
            guard case .document(_, _, let title) = chip.citation, !titles.contains(title) else { continue }
            titles.append(title)
        }
        return titles.isEmpty ? nil : titles.joined(separator: "\n")
    }
}

extension View {
    /// The titles of `answer`'s document chips as help (nothing without one).
    @ViewBuilder
    func documentChipHelp(_ answer: AnswerText) -> some View {
        if let help = DocumentCitations.help(answer) {
            self.help(Text(verbatim: help))
        } else {
            self
        }
    }
}
