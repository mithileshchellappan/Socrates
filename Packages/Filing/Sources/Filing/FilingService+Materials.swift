import Foundation
import StudyCore

// mt (docs/plan-materials.md §2.4): what smart import needs for books and papers dropped on a
// course (FilingUI hands them to the material library instead of filing them as slides).
extension FilingService {
    /// The course a drop place belongs to: the course itself, a lecture's, a session's.
    public func courseID(of destination: FilingDestination) async -> Course.ID? {
        switch destination {
        case .course(let id):
            return id
        case .lecture(let id):
            return try? await services.records.fetch(Lecture.self, id: id)?.courseID
        case .session(let id):
            return try? await services.records.fetch(LectureSession.self, id: id)?.courseID
        }
    }
}
