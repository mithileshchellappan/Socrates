import Alignment

/// Verified slide timelines for the fixtures (from listening to the recordings). The timelines
/// belong to the git-ignored fixtures and are not published: the two below are empty, so an
/// evaluation run scores nothing until a fixture's own timeline is filled in locally.
///
/// Where the truth only knows two slide starts, every slide in between is accepted (a segment
/// "5:00"–"12:00" with 19…23 is "one of 19–23"); text-identical slides are interchangeable.
/// Gaps between segments are unknown and not scored.
public struct GroundTruth: Hashable, Sendable {
    public struct Segment: Hashable, Sendable {
        public var start: Double
        public var end: Double
        public var allowed: Set<AlignmentTarget>
    }

    /// A verified change: at `time` the lecture moves to one of `targets`.
    public struct Boundary: Hashable, Sendable {
        public var time: Double
        public var targets: Set<AlignmentTarget>
        /// "~" in the truth: approximate time.
        public var approximate: Bool
    }

    public var segments: [Segment]
    public var boundaries: [Boundary]
    public var end: Double

    public func allowed(at time: Double) -> Set<AlignmentTarget>? {
        segments.first { $0.start <= time && time < $0.end }?.allowed
    }

    /// Five true slide starts spread over the lecture, as stamps (for the "stamps fix it" evaluation).
    public func stamps(count: Int = 5, delay: Double = 0) -> [AlignmentAnchor] {
        let exact = boundaries.filter { !$0.approximate && $0.targets.count == 1 && $0.targets.first?.page != nil }
        guard !exact.isEmpty else { return [] }
        let picks = (0..<min(count, exact.count)).map { index in
            exact[Int((Double(index) + 0.5) * Double(exact.count) / Double(min(count, exact.count)))]
        }
        return picks.compactMap { boundary in
            boundary.targets.first?.page.map { AlignmentAnchor.stamp($0, at: boundary.time + delay) }
        }
    }
}

/// `m:ss` / `h:mm:ss` → seconds.
func time(_ text: String) -> Double {
    text.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
}

private func slides(_ pages: ClosedRange<Int>) -> Set<AlignmentTarget> {
    Set(pages.map(AlignmentTarget.slide))
}

private func segment(_ start: String, _ end: String, _ allowed: Set<AlignmentTarget>) -> GroundTruth.Segment {
    GroundTruth.Segment(start: time(start), end: time(end), allowed: allowed)
}

private func boundary(_ at: String, _ targets: Set<AlignmentTarget>, approximate: Bool = false) -> GroundTruth.Boundary {
    GroundTruth.Boundary(time: time(at), targets: targets, approximate: approximate)
}

extension GroundTruth {
    /// Fixture lecture A (an invented name; its timeline stays with the private fixture).
    public static let clL1 = GroundTruth(segments: [], boundaries: [], end: 0)

    /// Fixture lecture B (an invented name; its timeline stays with the private fixture).
    public static let dcL2 = GroundTruth(segments: [], boundaries: [], end: 0)

    /// Keeps the helpers above in use for a fixture's own timeline (`segment`, `boundary`, `slides`).
    static func timeline(segments: [(String, String, ClosedRange<Int>)], end: String) -> GroundTruth {
        GroundTruth(
            segments: segments.map { segment($0.0, $0.1, slides($0.2)) },
            boundaries: segments.map { boundary($0.0, slides($0.2)) },
            end: time(end)
        )
    }
}
