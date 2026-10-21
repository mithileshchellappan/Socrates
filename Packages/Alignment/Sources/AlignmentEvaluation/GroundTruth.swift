import Alignment
import Foundation

/// A verified slide timeline for a fixture lecture, read from the fixture's git-ignored
/// `truth.json` (see ``LectureFixture/load(directory:)``).
///
/// Where the truth only knows two slide starts, every slide in between is accepted (a segment
/// "5:00"–"12:00" with "19-23" is "one of 19–23"); text-identical slides are listed together.
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

extension GroundTruth {
    /// `truth.json`: `{"name": "…", "transcript": "<srt in the folder>", "end": "m:ss",
    /// "segments": [["m:ss", "m:ss", "13-14,off"], …], "boundaries": [["m:ss", "15"], ["m:ss", "off", "~"], …]}`
    /// ("~" marks an approximate boundary).
    struct File: Decodable {
        var name: String
        var transcript: String
        var end: String
        var segments: [[String]]
        var boundaries: [[String]]
    }

    init(_ file: File, source: String) throws {
        segments = try file.segments.map { row in
            guard row.count == 3 else { throw FixtureError.malformed(source) }
            return Segment(start: time(row[0]), end: time(row[1]), allowed: try Self.targets(row[2], source: source))
        }
        boundaries = try file.boundaries.map { row in
            guard row.count == 2 || row.count == 3 && row[2] == "~" else { throw FixtureError.malformed(source) }
            return Boundary(time: time(row[0]), targets: try Self.targets(row[1], source: source), approximate: row.count == 3)
        }
        end = time(file.end)
    }

    /// "13-14,off" → slides 13 and 14, or off.
    static func targets(_ text: String, source: String) throws -> Set<AlignmentTarget> {
        var targets: Set<AlignmentTarget> = []
        for item in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if item == "off" {
                targets.insert(.off)
                continue
            }
            let bounds = item.split(separator: "-").compactMap { Int($0) }
            guard (1...2).contains(bounds.count), bounds.count == item.split(separator: "-").count,
                  let first = bounds.first, let last = bounds.last, first <= last else {
                throw FixtureError.malformed(source)
            }
            targets.formUnion((first...last).map(AlignmentTarget.slide))
        }
        guard !targets.isEmpty else { throw FixtureError.malformed(source) }
        return targets
    }
}
