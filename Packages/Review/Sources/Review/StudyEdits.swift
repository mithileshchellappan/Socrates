import Foundation
import StudyCore

/// What the student does to the study pass's rows and their own pins (docs/plan-m4.md §5):
/// Hide an AI or professor item (gone from every surface), Revert Correction on a transcript line,
/// and Add / edit / Delete Pin. Each is one small write over the query DSL.
public struct StudyEdits: Sendable {
    public let store: RecordStore

    public init(store: RecordStore) {
        self.store = store
    }

    /// Hide: `hidden_at` = now on an AI or professor item (never the student's own pin, which is
    /// deleted instead).
    public func hide(_ id: Annotation.ID) async throws {
        let now = store.currentDate
        let hidden: Date? = now
        try await store.database.write { db in
            try Annotation
                .where { $0.id.eq(id) && $0.layer.neq(AnnotationLayer.user) }
                .update {
                    $0.hiddenAt = hidden
                    $0.updatedAt = now
                }
                .execute(db)
        }
    }

    /// Add Pin: the student's pin on a slide at `x`, `y` (0…1 from the slide's top left).
    @discardableResult
    public func addPin(
        lectureID: Lecture.ID, deckID: Deck.ID?, page: Int, x: Double, y: Double, body: String = ""
    ) async throws -> Annotation {
        let pin = Annotation(
            lectureID: lectureID,
            layer: .user,
            kind: .comment,
            deckID: deckID,
            pageNumber: page,
            body: body,
            anchorX: min(1, max(0, x)),
            anchorY: min(1, max(0, y))
        )
        let stamped = store.stamp(pin)
        try await store.database.write { db in
            try Annotation.insert { stamped }.execute(db)
        }
        return stamped
    }

    /// The text of the student's own pin.
    public func setPinBody(_ id: Annotation.ID, body: String) async throws {
        let now = store.currentDate
        try await store.database.write { db in
            try Annotation
                .where { $0.id.eq(id) && $0.layer.eq(AnnotationLayer.user) && $0.kind.eq(AnnotationKind.comment) }
                .update {
                    $0.body = body
                    $0.updatedAt = now
                }
                .execute(db)
        }
    }

    /// Delete Pin: only the student's own.
    public func deletePin(_ id: Annotation.ID) async throws {
        try await store.database.write { db in
            try Annotation
                .where { $0.id.eq(id) && $0.layer.eq(AnnotationLayer.user) && $0.kind.eq(AnnotationKind.comment) }
                .delete()
                .execute(db)
        }
    }

    /// Revert Correction: every active patch of the line's segments gets `reverted_at` (it stays,
    /// so a re-run of the pass keeps it reverted) and `text` is recomputed from `original_text`.
    public func revertCorrections(segmentIDs: [TranscriptSegment.ID]) async throws {
        guard !segmentIDs.isEmpty else { return }
        let now = store.currentDate
        try await store.database.write { db in
            let segments = try TranscriptSegment.where { $0.id.in(segmentIDs) }.fetchAll(db)
            for segment in segments where !segment.activePatches.isEmpty {
                let patches = (segment.patches ?? []).map { patch in
                    var patch = patch
                    if patch.isActive { patch.revertedAt = now }
                    return patch
                }
                var reverted = segment.withPatches(patches)
                reverted.updatedAt = now
                try TranscriptSegment.upsert { reverted }.execute(db)
            }
        }
    }
}
