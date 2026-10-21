import Foundation
import StudyCore

/// mt: passages of a course's materials picked on device (docs/plan-materials.md §3.4–3.5), for
/// StudyPass (the `cover` unit's candidates, the notes' and Ask's book passages) through
/// StudyCore's `MaterialPassages`, so StudyPass gains no Search dependency. Hybrid: the engine's
/// keyword lists fused with its semantic neighbours, over the `.materials` scope (the course's
/// file materials through `course_material`, a material and page ranges when asked).
public struct MaterialRetriever: MaterialPassages {
    public let engine: SearchEngine
    /// How long the keyword lists wait for the semantic list (a background caller can wait).
    public let semanticWait: Duration

    public init(engine: SearchEngine, semanticWait: Duration = .seconds(5)) {
        self.engine = engine
        self.semanticWait = semanticWait
    }

    public func search(_ query: MaterialPassageQuery) async throws -> [MaterialPassageHit] {
        let search = SearchQuery(
            query.text, scope: .materials, courseID: query.courseID, limit: max(1, query.limit), materialID: query.materialID,
            pages: query.pages
        )
        guard !search.isEmpty else { return [] }
        let results = try await engine.search(search, semanticWait: semanticWait)
        var hits: [MaterialPassageHit] = []
        for (rank, hit) in results.hits.enumerated() {
            guard let materialID = hit.materialID, let documentID = hit.documentID, let page = hit.page else { continue }
            // Reciprocal rank: the engine's order is its fused ranking.
            hits.append(MaterialPassageHit(
                materialID: materialID, documentID: documentID, page: page, text: hit.text, score: 1 / Double(rank + 1)
            ))
        }
        return hits
    }
}
