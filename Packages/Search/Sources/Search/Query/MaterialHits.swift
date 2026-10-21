import Foundation
import GRDB
import StudyCore

/// mt: search hits on course materials (docs/plan-materials.md §2.5 "Search"): the material
/// (title, kind), the section holding the page ("§6.2") and the printed page ("p. 214"); a
/// link's hit carries its URL.
enum MaterialHits {
    struct Found {
        var material: CourseMaterial
        var sections: [MaterialSection]
    }

    /// Per document, the material it is of: the query's material, else one of the query's course,
    /// else the first on its shelf (primary first). Documents no material uses are left out.
    static func materials(of documents: [StudyDocument.ID], query: SearchQuery, in db: Database) throws -> [StudyDocument.ID: Found] {
        guard !documents.isEmpty else { return [:] }
        let references = documents.map { StudyDocument.ID?.some($0) }
        let rows = try CourseMaterial.where { $0.documentID.in(references) }.fetchAll(db).sorted(by: CourseMaterial.shelfOrder)
        var chosen: [StudyDocument.ID: CourseMaterial] = [:]
        for material in rows {
            guard let documentID = material.documentID else { continue }
            if let materialID = query.materialID, material.id != materialID { continue }
            if let courseID = query.courseID, material.courseID != courseID { continue }
            if chosen[documentID] == nil { chosen[documentID] = material }
        }
        let ids = Array(Set(chosen.values.map(\.id)))
        let sections = try MaterialSection.where { $0.materialID.in(ids) }.order { ($0.sortOrder.asc(), $0.firstPage.asc()) }.fetchAll(db)
        let byMaterial = Dictionary(grouping: sections, by: \.materialID)
        return chosen.mapValues { Found(material: $0, sections: byMaterial[$0.id] ?? []) }
    }

    static func hit(
        _ meta: Retrieval.Chunk, material: CourseMaterial, sections: [MaterialSection], all: Bool, snippet: AttributedString
    ) -> SearchHit {
        var hit = SearchHit(
            id: meta.id, kind: .material, courseID: material.courseID, page: meta.page, snippet: snippet, matchesAllTerms: all,
            target: .material(material.id, page: meta.page), title: material.title, documentID: meta.documentID
        )
        hit.materialID = material.id
        hit.text = meta.text
        if material.kind.isLink {
            hit.url = material.url
        } else if let page = meta.page {
            hit.materialSection = MaterialSection.holding(page: page, in: sections)?.citeLabel
            hit.printedPage = material.pageLabel(pdfPage: page)
        }
        return hit
    }
}
