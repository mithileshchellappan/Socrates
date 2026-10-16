// Value types the aligner consumes and produces. Times are seconds on the recording clock
// (sample 0 = 0.0); page numbers are 1-based deck pages, matching StudyCore's schema.

/// One deck page and its extracted text (`DeckPage.pageNumber` / `DeckPage.text`).
public struct SlideText: Hashable, Sendable {
    public var page: Int
    public var text: String

    public init(page: Int, text: String) {
        self.page = page
        self.text = text
    }
}

/// A word with timings inside a transcript line (`TranscriptWord`).
public struct TimedWord: Hashable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// One transcript line (`TranscriptSegment`). `words` is optional; without it, tokens are spread
/// evenly over the line and pauses come from gaps between lines.
public struct TranscriptLine: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [TimedWord]

    public init(start: Double, end: Double, text: String, words: [TimedWord] = []) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

/// What the lecture is about at a point in time: a deck page, or nothing on the slides
/// (admin, Q&A, demos, breaks).
public enum AlignmentTarget: Hashable, Sendable, CustomStringConvertible {
    case slide(Int)
    case off

    public var page: Int? {
        if case .slide(let page) = self { page } else { nil }
    }

    public var description: String {
        switch self {
        case .slide(let page): "slide \(page)"
        case .off: "off"
        }
    }
}

/// Where a span's start comes from. Maps 1:1 onto StudyCore's `SpanSource` (auto/stamp/manual).
public enum SpanOrigin: String, Hashable, Sendable, CaseIterable {
    case automatic
    case stamp
    case manual
}

/// A hard constraint: "`target` starts at `time`".
///
/// `.stamp` anchors come from live capture (`SlideEvent` kind show; time = sampleTime / sampleRate) and are
/// snapped back to the nearest pause or sentence start first, because people press late.
/// `.manual` anchors ("slide starts here") are used as given.
public struct AlignmentAnchor: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case stamp
        case manual
    }

    public var time: Double
    public var target: AlignmentTarget
    public var kind: Kind

    public init(time: Double, target: AlignmentTarget, kind: Kind) {
        self.time = time
        self.target = target
        self.kind = kind
    }

    public static func stamp(_ page: Int, at time: Double) -> Self {
        Self(time: time, target: .slide(page), kind: .stamp)
    }

    public static func manual(_ target: AlignmentTarget, at time: Double) -> Self {
        Self(time: time, target: target, kind: .manual)
    }
}

/// An anchor after validation and snapping, as the decoder used it.
public struct ResolvedAnchor: Hashable, Sendable {
    public var anchor: AlignmentAnchor
    /// The constrained start time (snapped for stamps, clamped to the recording).
    public var time: Double
    /// Decoder step that carries the constraint.
    public var step: Int

    public init(anchor: AlignmentAnchor, time: Double, step: Int) {
        self.anchor = anchor
        self.time = time
        self.step = step
    }
}

/// One contiguous stretch of the recording assigned to one target.
public struct AlignedSpan: Hashable, Sendable {
    public var target: AlignmentTarget
    public var start: Double
    public var end: Double
    /// 0…1. Anchored spans are 1; automatic spans compare the chosen target's evidence with the best alternative.
    public var confidence: Double
    public var origin: SpanOrigin

    public init(target: AlignmentTarget, start: Double, end: Double, confidence: Double, origin: SpanOrigin) {
        self.target = target
        self.start = start
        self.end = end
        self.confidence = confidence
        self.origin = origin
    }

    public var duration: Double { end - start }
}

/// Per-window evidence: what each slide (and OFF) scored for the transcript around one decoder step.
public struct WindowScores: Hashable, Sendable {
    public var start: Double
    public var end: Double
    /// TF-IDF cosine similarity per slide, indexed like ``AlignmentResult/pages``.
    public var slideScores: [Float]
    /// Emission of the OFF state for this window (constant times evidence).
    public var offScore: Float
    /// 0…1: how much transcript there is around this window (0 = silence).
    public var evidence: Float
    /// What the decoder chose for this window.
    public var target: AlignmentTarget

    public init(start: Double, end: Double, slideScores: [Float], offScore: Float, evidence: Float, target: AlignmentTarget) {
        self.start = start
        self.end = end
        self.slideScores = slideScores
        self.offScore = offScore
        self.evidence = evidence
        self.target = target
    }

    /// Best-scoring slide page for this window, ignoring the decoder.
    public func bestPage(pages: [Int]) -> Int? {
        guard let index = slideScores.indices.max(by: { slideScores[$0] < slideScores[$1] }) else { return nil }
        return pages[index]
    }
}

/// Per-window scores for every decoder step, stored flat and materialized on access.
public struct WindowTable: RandomAccessCollection, Hashable, Sendable {
    public let stepDuration: Double
    public let duration: Double
    let slideCount: Int
    /// Row-major `count × slideCount`.
    let similarity: [Float]
    let offScores: [Float]
    let evidence: [Float]
    let targets: [AlignmentTarget]

    public var startIndex: Int { 0 }
    public var endIndex: Int { targets.count }

    public subscript(position: Int) -> WindowScores {
        let row = position * slideCount
        return WindowScores(
            start: Double(position) * stepDuration,
            end: Swift.min(duration, Double(position + 1) * stepDuration),
            slideScores: Array(similarity[row..<(row + slideCount)]),
            offScore: offScores[position],
            evidence: evidence[position],
            target: targets[position]
        )
    }

    /// Cosine similarity of window `position` to the slide at `slideIndex` without materializing the row.
    public func score(window position: Int, slideIndex: Int) -> Float {
        similarity[position * slideCount + slideIndex]
    }
}

/// The aligner's output.
public struct AlignmentResult: Hashable, Sendable {
    /// Page numbers in deck order; ``WindowScores/slideScores`` use the same indexing.
    public var pages: [Int]
    /// Contiguous, non-overlapping spans covering `[0, duration]`.
    public var spans: [AlignedSpan]
    /// One entry per decoder step.
    public var windows: WindowTable
    /// Anchors that constrained this run (after snapping); dropped anchors are absent.
    public var anchors: [ResolvedAnchor]
    public var duration: Double

    public init(pages: [Int], spans: [AlignedSpan], windows: WindowTable, anchors: [ResolvedAnchor], duration: Double) {
        self.pages = pages
        self.spans = spans
        self.windows = windows
        self.anchors = anchors
        self.duration = duration
    }

    /// The target at `time` (the span containing it; the last span for times past the end).
    public func target(at time: Double) -> AlignmentTarget {
        span(at: time)?.target ?? .off
    }

    public func span(at time: Double) -> AlignedSpan? {
        guard !spans.isEmpty else { return nil }
        var low = 0
        var high = spans.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if spans[mid].start <= time { low = mid } else { high = mid - 1 }
        }
        return spans[low]
    }

    /// Slide spans only (OFF stretches removed), e.g. for `lecture_deck_span` rows.
    public var slideSpans: [AlignedSpan] {
        spans.filter { $0.target != .off }
    }
}
