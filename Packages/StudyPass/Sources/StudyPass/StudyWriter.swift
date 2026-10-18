import Foundation
import StudyCore

/// The pass's writes. A unit's rows, its patches and its `done` state go in one transaction after
/// verification, so a usage limit, a cancelled call or a quit mid-call leaves it `pending` with
/// nothing half-written (plan §3 "Pause and resume").
struct StudyWriter: Sendable {
    let database: any DatabaseWriter
    let store: RecordStore

    /// Writes a unit's verified result: its old rows go, the new ones (with `study_unit_id`) come,
    /// the block's lines get their patches, the unit is `done`. Nothing is written (false) when
    /// the unit is gone or its inputs changed while the call ran.
    func finish(_ unitID: StudyUnit.ID, expectedHash: String, result: UnitResult, apiCallID: APICall.ID?, now: Date) async throws -> Bool {
        let store = store
        let annotations = result.annotations.map { annotation in
            var annotation = annotation
            annotation.studyUnitID = unitID
            annotation.createdAt = now
            return store.stamp(annotation)
        }
        return try await database.write { db in
            guard var unit = try StudyUnit.find(unitID).fetchOne(db), unit.inputHash == expectedHash else { return false }
            try Annotation.where { $0.studyUnitID.eq(unitID) }.delete().execute(db)
            for annotation in annotations {
                try Annotation.upsert { annotation }.execute(db)
            }
            for (segmentID, proposed) in result.patches ?? [:] {
                guard let segment = try TranscriptSegment.find(segmentID).fetchOne(db) else { continue }
                let merged = Self.merge(proposed, into: segment)
                guard merged != (segment.patches ?? []) else { continue }
                let saved = store.stamp(segment.withPatches(merged))
                try TranscriptSegment.upsert { saved }.execute(db)
            }
            unit.state = .done
            unit.apiCallID = apiCallID
            unit.finishedAt = now
            unit.error = nil
            let stamped = store.stamp(unit)
            try StudyUnit.upsert { stamped }.execute(db)
            return true
        }
    }

    /// A line's patches after a read unit ran: the student's own (no call id) stay; the pass's
    /// reverted patches whose `from` still matches at their offset stay reverted (a re-run never
    /// brings them back); the rest of the pass's patches are replaced by `proposed`, minus any
    /// that overlap what stays.
    static func merge(_ proposed: [TranscriptPatch], into segment: TranscriptSegment) -> [TranscriptPatch] {
        let old = segment.patches ?? []
        var kept = old.filter { patch in
            patch.apiCallID == nil || (patch.revertedAt != nil && matches(patch, in: segment.originalText))
        }
        for patch in proposed where !kept.contains(where: { overlaps($0, patch) }) {
            kept.append(patch)
        }
        return kept.sorted { $0.offset < $1.offset }
    }

    static func matches(_ patch: TranscriptPatch, in original: String) -> Bool {
        guard patch.offset >= 0,
              let start = original.index(original.startIndex, offsetBy: patch.offset, limitedBy: original.endIndex),
              let end = original.index(start, offsetBy: patch.from.count, limitedBy: original.endIndex)
        else { return false }
        return original[start..<end] == patch.from
    }

    static func overlaps(_ first: TranscriptPatch, _ second: TranscriptPatch) -> Bool {
        first.offset < second.offset + max(second.from.count, 1) && second.offset < first.offset + max(first.from.count, 1)
    }

    /// A failed attempt (service trouble never comes here): `failed` after the third, else it
    /// stays `pending`. The error is readable and holds no transcript text.
    func countFailure(_ unitID: StudyUnit.ID, error: String, apiCallID: APICall.ID?) async throws {
        let store = store
        try await database.write { db in
            guard var unit = try StudyUnit.find(unitID).fetchOne(db) else { return }
            unit.attempts += 1
            unit.error = String(error.prefix(300))
            unit.apiCallID = apiCallID ?? unit.apiCallID
            if unit.attempts >= StudyUnit.maximumAttempts {
                unit.state = .failed
                unit.finishedAt = store.currentDate
            }
            let stamped = store.stamp(unit)
            try StudyUnit.upsert { stamped }.execute(db)
        }
    }

    /// The lecture went over its budget: every unit still pending is `failed` "Over budget".
    func failPending(lectureID: Lecture.ID, error: String) async throws -> Int {
        let store = store
        return try await database.write { db in
            let pending = try StudyUnit
                .where { $0.lectureID.eq(lectureID) && $0.state.eq(ExtractionState.pending) }
                .fetchAll(db)
            for var unit in pending {
                unit.state = .failed
                unit.error = error
                unit.finishedAt = store.currentDate
                let stamped = store.stamp(unit)
                try StudyUnit.upsert { stamped }.execute(db)
            }
            return pending.count
        }
    }

    /// Notional dollars the lecture's study calls cost so far (`api_call.cost_usd`, purpose
    /// `study.*`).
    func spent(lectureID: Lecture.ID) async throws -> Double {
        try await database.read { db in
            try APICall
                .where { $0.lectureID.eq(lectureID) && $0.purpose.like(StudyStage.callPurposePrefix + "%") }
                .select { $0.costUSD.sum() }
                .fetchOne(db)?
                .flatMap { $0 } ?? 0
        }
    }
}
