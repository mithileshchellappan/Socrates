import Foundation
import StudyCore

/// What the study pass wrote for a lecture (and the student's own pins), sorted for the review
/// screen: the inspector's blocks, the pins on the slide and in the transcript, the scrubber's
/// marks (docs/plan-m4.md §2, §5). Built from the lecture's `annotation` rows that are not
/// hidden; one reader serves every surface.
public struct StudyItems: Equatable, Sendable {
    /// The lecture's summary (ai · summary without a page).
    public var lectureSummary: Annotation?
    /// Each slide's summary (ai · summary with a page), the first one per page.
    public var slideSummaries: [Int: Annotation] = [:]
    /// professor · exam_hint, in time order.
    public var examHints: [Annotation] = []
    /// professor · exam_hint and highlight, in time order.
    public var professorItems: [Annotation] = []
    /// ai · not_on_slides, in time order.
    public var saidInClass: [Annotation] = []
    /// ai · further_reading, by slide.
    public var furtherReading: [Annotation] = []
    /// user · comment: the student's own pins.
    public var pins: [Annotation] = []

    public static let empty = StudyItems([])

    /// `annotations` of one lecture; hidden rows and kinds Review does not show (topics, ink,
    /// M1 corrections) are left out.
    public init(_ annotations: [Annotation]) {
        for annotation in annotations where annotation.hiddenAt == nil {
            switch (annotation.layer, annotation.kind) {
            case (.ai, .summary):
                if let page = annotation.pageNumber {
                    if slideSummaries[page] == nil { slideSummaries[page] = annotation }
                } else if lectureSummary == nil {
                    lectureSummary = annotation
                }
            case (.professor, let kind) where kind.isProfessorItem:
                professorItems.append(annotation)
                if kind == .examHint { examHints.append(annotation) }
            case (.ai, .notOnSlides):
                saidInClass.append(annotation)
            case (.ai, .furtherReading):
                furtherReading.append(annotation)
            case (.user, .comment):
                pins.append(annotation)
            default:
                break
            }
        }
        examHints.sort(by: Self.inTimeOrder)
        professorItems.sort(by: Self.inTimeOrder)
        saidInClass.sort(by: Self.inTimeOrder)
        furtherReading.sort { ($0.pageNumber ?? .max, $0.createdAt) < ($1.pageNumber ?? .max, $1.createdAt) }
    }

    public var isEmpty: Bool {
        lectureSummary == nil && slideSummaries.isEmpty && professorItems.isEmpty && saidInClass.isEmpty
            && furtherReading.isEmpty && pins.isEmpty
    }

    /// The lecture-wide blocks (exam hints, only said in class) have something to show.
    public var hasLectureWideItems: Bool {
        !examHints.isEmpty || !saidInClass.isEmpty
    }

    public func furtherReading(page: Int) -> [Annotation] {
        furtherReading.filter { $0.pageNumber == page }
    }

    /// The professor's items on a slide, in time order.
    public func professorItems(page: Int) -> [Annotation] {
        professorItems.filter { $0.pageNumber == page }
    }

    public func pins(page: Int) -> [Annotation] {
        pins.filter { $0.pageNumber == page }
    }

    /// Said in class under the category subheadlines, in `SaidInClassCategory.displayOrder`
    /// (unknown categories last, then items without one), each in time order.
    public var saidInClassByCategory: [(category: SaidInClassCategory?, items: [Annotation])] {
        var groups: [(category: SaidInClassCategory?, items: [Annotation])] = []
        let known = SaidInClassCategory.displayOrder
        for category in known {
            let items = saidInClass.filter { $0.category == category }
            if !items.isEmpty { groups.append((category, items)) }
        }
        var others: [SaidInClassCategory] = []
        for item in saidInClass {
            if let category = item.category, !known.contains(category), !others.contains(category) {
                others.append(category)
            }
        }
        for category in others {
            groups.append((category, saidInClass.filter { $0.category == category }))
        }
        let uncategorized = saidInClass.filter { $0.category == nil }
        if !uncategorized.isEmpty { groups.append((nil, uncategorized)) }
        return groups
    }

    /// The professor item a transcript line of `recordingID` ends with: the first one whose
    /// quote starts in the line (its segment, else its time).
    public func professorItem(
        recordingID: Recording.ID?, segmentIDs: [TranscriptSegment.ID], start: Double, end: Double
    ) -> Annotation? {
        professorItems.first { item in
            if let segment = item.transcriptSegmentID { return segmentIDs.contains(segment) }
            guard item.recordingID == nil || item.recordingID == recordingID, let time = item.startTime else { return false }
            return time >= start - 0.25 && time < end
        }
    }

    /// The items with a moment on `recordingID`'s clock (or on no recording in particular).
    public func onRecording(_ items: [Annotation], _ recordingID: Recording.ID?) -> [Annotation] {
        items.filter { $0.startTime != nil && ($0.recordingID == nil || $0.recordingID == recordingID) }
    }

    static func inTimeOrder(_ lhs: Annotation, _ rhs: Annotation) -> Bool {
        (lhs.startTime ?? .infinity, lhs.createdAt) < (rhs.startTime ?? .infinity, rhs.createdAt)
    }
}

/// Moments on the scrubber (exam hints, said in class, flags): marks closer than 0.5 % of the
/// track's width merge into the first of them.
public enum ScrubberMoments {
    /// Marks closer than this fraction of the recording merge.
    public static let mergeFraction = 0.005

    public static func merged(_ times: [Double], duration: Double) -> [Double] {
        guard duration > 0 else { return times.sorted() }
        var merged: [Double] = []
        for time in times.sorted() {
            if let last = merged.last, (time - last) / duration < mergeFraction { continue }
            merged.append(time)
        }
        return merged
    }
}
