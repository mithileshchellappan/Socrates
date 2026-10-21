import Foundation
import GRDB
import StudyCore

/// mt: which chunks are a course's materials (docs/plan-materials.md §3.1). A material's chunks
/// carry no `course_id` (one file can serve two courses, and a course delete must not cascade
/// them): the course filter joins `course_material.document_id`. A material whose file the
/// student keeps among their own documents too has chunks of kind `document`; the `.materials`
/// scope finds those as well, only through a `course_material` row.
enum MaterialScope {
    /// A condition on the `search_chunk` row aliased `alias` that holds for the chunks of the
    /// query's materials: documents some material uses (of `query.courseID` when set), only
    /// `query.materialID`'s when set, only `query.pages` when given.
    static func condition(_ query: SearchQuery, alias c: String) -> (sql: String, arguments: StatementArguments) {
        var parts = ["\(c).document_id IS NOT NULL"]
        var arguments: StatementArguments = []
        var linked = "SELECT m.document_id FROM course_material m WHERE m.document_id IS NOT NULL"
        if let courseID = query.courseID {
            linked += " AND m.course_id = ?"
            arguments += [courseID.uuidString.lowercased()]
        }
        if let materialID = query.materialID {
            linked += " AND m.id = ?"
            arguments += [materialID.uuidString.lowercased()]
        }
        parts.append("\(c).document_id IN (\(linked))")
        if !query.pages.isEmpty {
            let ranges = query.pages.prefix(24)
            parts.append("(" + ranges.map { _ in "\(c).page_number BETWEEN ? AND ?" }.joined(separator: " OR ") + ")")
            for range in ranges { arguments += [range.lowerBound, range.upperBound] }
        }
        return ("(" + parts.joined(separator: " AND ") + ")", arguments)
    }

    /// Whether the query needs the material condition: the `.materials` scope always (personal
    /// documents count only through a material), any scope with materials and a course, a
    /// material or pages.
    static func applies(to query: SearchQuery) -> Bool {
        query.scope == .materials
            || (query.scope.kinds.contains(.material) && (query.courseID != nil || query.materialID != nil || !query.pages.isEmpty))
    }

    /// Whether a chunk of `kind` is filtered by the material condition (not by course or lecture).
    static func governs(_ kind: String, scope: SearchQuery.Scope) -> Bool {
        kind == SearchChunkKind.material.rawValue || (scope == .materials && kind == SearchChunkKind.document.rawValue)
    }

    /// The ids of the chunks the condition allows (the semantic index's filter).
    static func chunkIDs(_ query: SearchQuery, in db: Database) throws -> Set<Int64> {
        let condition = condition(query, alias: "c")
        let kinds = query.scope == .materials ? "'material', 'document'" : "'material'"
        let ids = try Int64.fetchAll(
            db, sql: "SELECT c.id FROM search_chunk c WHERE c.kind IN (\(kinds)) AND \(condition.sql)", arguments: condition.arguments
        )
        return Set(ids)
    }
}
