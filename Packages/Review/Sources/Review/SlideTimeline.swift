import Foundation
import StudyCore

/// Which slide was on screen when, over one recording's clock: the aligner's timed spans (slide
/// visits and off-slide stretches) in time order.
///
/// Times before the first span belong to the first span, times in a gap to the span before it
/// (the slide stays up until the next one), as in `LectureOutline`.
public struct SlideTimeline: Sendable, Hashable {
    /// One slide visit, or an off-slide stretch (`page == nil`).
    public struct Span: Sendable, Hashable, Identifiable {
        public var id: UUID
        /// Nil for an off-slide stretch (admin talk, Q&A, a break).
        public var page: Int?
        public var start: Double
        public var end: Double
        public var source: SpanSource
        public var confidence: Double

        public init(id: UUID = UUID(), page: Int?, start: Double, end: Double, source: SpanSource = .auto, confidence: Double = 1) {
            self.id = id
            self.page = page
            self.start = start
            self.end = end
            self.source = source
            self.confidence = confidence
        }

        public var isOffSlide: Bool { page == nil }
    }

    /// Spans in time order.
    public let spans: [Span]
    private let starts: [Double]

    public init(spans: [Span]) {
        let sorted = spans.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        self.spans = sorted
        starts = sorted.map(\.start)
    }

    /// The timed rows of `lecture_deck_span` (coarse page ranges without times are ignored).
    public init(_ rows: [LectureDeckSpan]) {
        self.init(spans: rows.compactMap { row in
            guard let start = row.startTime else { return nil }
            return Span(
                id: row.id, page: row.firstPage, start: start, end: row.endTime ?? start,
                source: row.source, confidence: row.confidence
            )
        })
    }

    public static let empty = SlideTimeline(spans: [])

    public var isEmpty: Bool { spans.isEmpty }

    // MARK: - Lookups

    /// Index of the span at `time`: the last one starting at or before it (0 before the first).
    public func index(at time: Double) -> Int? {
        guard !starts.isEmpty else { return nil }
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= time { low = middle } else { high = middle - 1 }
        }
        return low
    }

    public func span(at time: Double) -> Span? {
        index(at: time).map { spans[$0] }
    }

    /// The page discussed at `time`; nil off the slides or without spans.
    public func page(at time: Double) -> Int? {
        span(at: time)?.page
    }

    /// The slide to show at `time`: the page discussed then, else (off the slides) the last page
    /// discussed before, else the first one after.
    public func displayPage(at time: Double) -> Int? {
        guard let index = index(at: time) else { return nil }
        if let page = spans[index].page { return page }
        if let before = spans[..<index].last(where: { $0.page != nil }) { return before.page }
        return spans[(index + 1)...].first { $0.page != nil }?.page
    }

    /// Every visit of `page`, in time order.
    public func visits(of page: Int) -> [Span] {
        spans.filter { $0.page == page }
    }

    /// The first time `page` was discussed.
    public func firstVisit(of page: Int) -> Span? {
        spans.first { $0.page == page }
    }

    /// Off-slide stretches in time order.
    public var offStretches: [Span] {
        spans.filter(\.isOffSlide)
    }

    /// Pages discussed at least once.
    public var discussedPages: Set<Int> {
        Set(spans.compactMap(\.page))
    }

    /// The last slide visit of the lecture (the last discussed slide).
    public var lastDiscussed: Span? {
        spans.last { $0.page != nil }
    }

    /// Where the slide on screen changes (scrubber ticks): the start of every span after the first
    /// whose page differs from the previous span's.
    public var boundaries: [Double] {
        zip(spans, spans.dropFirst()).compactMap { previous, next in
            previous.page == next.page ? nil : next.start
        }
    }

    // MARK: - Transcript

    /// Groups transcript lines by the span containing each line's midpoint (one section per span,
    /// empty sections included). Without spans, one untitled section holds everything.
    public func sections(of segments: [TranscriptSegment]) -> [TranscriptSection] {
        let segments = segments.sorted { $0.startTime < $1.startTime }
        guard !spans.isEmpty else {
            guard let first = segments.first else { return [] }
            return [TranscriptSection(
                id: TranscriptSection.unalignedID, span: nil, start: first.startTime,
                end: segments.map(\.endTime).max() ?? first.endTime, segments: segments
            )]
        }
        var grouped = Array(repeating: [TranscriptSegment](), count: spans.count)
        for segment in segments {
            let middle = (segment.startTime + segment.endTime) / 2
            if let index = index(at: middle) { grouped[index].append(segment) }
        }
        return spans.indices.map { index in
            TranscriptSection(
                id: spans[index].id, span: spans[index], start: spans[index].start,
                end: spans[index].end, segments: grouped[index]
            )
        }
    }
}

/// The transcript lines of one slide visit or off-slide stretch.
public struct TranscriptSection: Sendable, Hashable, Identifiable {
    /// The id of the one section of a transcript that has no spans yet.
    public static let unalignedID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    public var id: UUID
    /// Nil before alignment.
    public var span: SlideTimeline.Span?
    public var start: Double
    public var end: Double
    public var segments: [TranscriptSegment]

    public init(id: UUID, span: SlideTimeline.Span?, start: Double, end: Double, segments: [TranscriptSegment]) {
        self.id = id
        self.span = span
        self.start = start
        self.end = end
        self.segments = segments
    }

    public var page: Int? { span?.page }
    /// An aligned stretch on no slide.
    public var isOffSlide: Bool { span?.isOffSlide ?? false }
    /// The span starts at a manual "slide starts here" marker.
    public var startsAtMarker: Bool { span?.source == .manual }
}
