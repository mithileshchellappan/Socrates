import Foundation
import StudyCore
import StudyUI
import SwiftUI

// mt (docs/plan-materials.md §3.3): a course material's marker in an answer, `[[mat 3f2a9c1e
// p231]]` (a PDF page) or `[[mat 7b20c4d1]]` (the material, e.g. a link), becomes a chip only
// after it is checked against the `course_material` rows: the key names exactly one material and
// the page lies within it. The chip is web's shape with `book` for the globe: "§6.2 · p. 214"
// (the section holding the page, the printed page), "p. 214" without a section, a link's
// repository or host clipped to 24; its help the title; it opens the material (the reader at the
// page; a link in the browser). Anything else is dropped and logged with its rule.

/// A course material as its markers are checked: enough to label a page.
struct MaterialCitationRow: Equatable, Sendable {
    var material: CourseMaterial
    var sections: [MaterialSection]
}

enum MaterialCitations {
    /// The chip's glyph.
    static let glyph = "book"
    /// A link's chip shows its repository or host up to this many characters.
    static let hostLimit = 24

    /// The materials by key (`CourseMaterial.key`); a key two materials share names neither.
    static func rows(_ db: Database) throws -> [String: [MaterialCitationRow]] {
        let materials = try CourseMaterial.all.fetchAll(db)
        guard !materials.isEmpty else { return [:] }
        var sections: [CourseMaterial.ID: [MaterialSection]] = [:]
        for section in try MaterialSection.all.fetchAll(db) {
            sections[section.materialID, default: []].append(section)
        }
        var rows: [String: [MaterialCitationRow]] = [:]
        for material in materials {
            rows[material.key, default: []].append(MaterialCitationRow(material: material, sections: sections[material.id] ?? []))
        }
        return rows
    }

    /// The marker's check: exactly one material has the key; a page lies within its pages (a
    /// material without pages, a link, takes no page).
    static func check(key: String, page: Int?, rows: CitationRows) -> Result<CheckedCitation, CitationCheck.DropError> {
        guard rows.isLoaded else { return .failure(CitationCheck.DropError(.notLoaded)) }
        let matches = rows.materials[key.lowercased()] ?? []
        guard matches.count == 1, let row = matches.first else { return .failure(CitationCheck.DropError(.unknownMaterial)) }
        if let page, page < 1 || page > row.material.pageCount {
            return .failure(CitationCheck.DropError(.unknownMaterial))
        }
        return .success(.material(id: row.material.id, page: page, label: label(row, page: page), title: row.material.title))
    }

    /// "§6.2 · p. 214", "p. 214", or a link's "example-org/dc-labs" / host, clipped to 24.
    static func label(_ row: MaterialCitationRow, page: Int?) -> String {
        if let page {
            return MaterialText.citeLabel(section: MaterialSection.holding(page: page, in: row.sections), material: row.material, pdfPage: page)
        }
        let name = MaterialText.host(row.material) ?? row.material.title
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = trimmed.count > hostLimit ? String(trimmed.prefix(hostLimit - 1)) + "…" : trimmed
        return clipped.replacingOccurrences(of: "-", with: "\u{2011}")
    }

    /// "socrates-cite://mat/<material>/231" ("-" without a page).
    static func link(id: CourseMaterial.ID, page: Int?) -> URL? {
        URL(string: "\(AnswerText.linkScheme)://mat/\(id.uuidString.lowercased())/\(page.map(String.init) ?? "-")")
    }

    /// Where a material chip's link goes: the material at its page.
    static func destination(linkParts parts: [String]) -> StudyDestination? {
        guard parts.count == 2, let id = UUID(uuidString: parts[0]) else { return nil }
        return .material(id, page: Int(parts[1]))
    }

    /// The titles of an answer's material chips (their help).
    static func titles(_ answer: AnswerText) -> [String] {
        var titles: [String] = []
        for chip in answer.chips {
            guard case .material(_, _, _, let title) = chip.citation, !titles.contains(title) else { continue }
            titles.append(title)
        }
        return titles
    }
}
