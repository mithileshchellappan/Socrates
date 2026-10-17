import Foundation
import Search
import StudyCore
import StudyUI

extension SearchHit {
    /// Where ↩ (or a click) opens the hit: a transcript line plays from its second, a slide opens
    /// at its first visit, a note at its slide and moment; a slide no lecture showed opens its course.
    public var destination: StudyDestination? {
        switch target {
        case .lecture(let id, let page, let time, let plays, let recording):
            .lecture(id, ReviewTarget(page: page, time: time, plays: plays, recordingID: recording))
        case .course(let id):
            .course(id)
        case .mail(let id):
            .mail(id)
        case nil:
            nil
        }
    }

    /// Where Space (or the time chip) goes: the same place, playing; nil without a moment.
    public var playDestination: StudyDestination? {
        guard let time, case .lecture(let id, let page, _, _, let recording) = target else { return nil }
        return .lecture(id, ReviewTarget(page: page, time: time, plays: true, recordingID: recording))
    }
}
