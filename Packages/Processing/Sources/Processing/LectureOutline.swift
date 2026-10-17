import Capture
import Foundation
import StudyCore

/// A lecture's transcript grouped by the slide on screen: one section per timed span (slide visit
/// or off-slide stretch), in time order. Before alignment there is one untitled section.
public struct LectureOutline: Sendable, Hashable {
    public struct Section: Sendable, Hashable, Identifiable {
        public var id: UUID
        /// Nil for an off-slide stretch or an unaligned transcript.
        public var page: Int?
        /// Short slide title from the deck page text; empty when unknown.
        public var title: String
        public var start: Double
        public var end: Double
        public var source: SpanSource?
        public var confidence: Double?
        public var segments: [TranscriptSegment]

        public var isOffSlide: Bool { page == nil && source != nil }
    }

    public var sections: [Section]

    public init(sections: [Section]) {
        self.sections = sections
    }

    /// Groups `segments` by the span containing each segment's midpoint. Spans without times
    /// (coarse page ranges) are ignored.
    public init(segments: [TranscriptSegment], spans: [LectureDeckSpan], pages: [DeckPage]) {
        let segments = segments.sorted { $0.startTime < $1.startTime }
        let timed = spans
            .filter(\.isTimed)
            .sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
        guard !timed.isEmpty else {
            let start = segments.first?.startTime ?? 0
            let end = segments.map(\.endTime).max() ?? start
            sections = segments.isEmpty ? [] : [Section(
                id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
                page: nil, title: "", start: start, end: end, source: nil, confidence: nil, segments: segments
            )]
            return
        }
        let titles = Dictionary(
            pages.map { ($0.pageNumber, DeckText.title(fromPageText: $0.text)) },
            uniquingKeysWith: { first, _ in first }
        )
        var sections = timed.map { span in
            Section(
                id: span.id,
                page: span.firstPage,
                title: span.firstPage.flatMap { titles[$0] } ?? "",
                start: span.startTime ?? 0,
                end: span.endTime ?? span.startTime ?? 0,
                source: span.source,
                confidence: span.confidence,
                segments: []
            )
        }
        let starts = sections.map(\.start)
        for segment in segments {
            let middle = (segment.startTime + segment.endTime) / 2
            sections[Self.index(of: middle, in: starts)].segments.append(segment)
        }
        self.sections = sections
    }

    /// Index of the last start ≤ `time` (0 for times before the first start).
    static func index(of time: Double, in starts: [Double]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= time { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Segment counts per language code, most frequent first.
    public var languageCounts: [(language: String, count: Int)] {
        var counts: [String: Int] = [:]
        for section in sections {
            for segment in section.segments { counts[segment.lang, default: 0] += 1 }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }
}
