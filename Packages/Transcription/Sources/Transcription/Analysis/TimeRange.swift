import Foundation

/// A half-open range of seconds on the recording clock.
public struct TimeRange: Hashable, Sendable, Codable, CustomStringConvertible {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = max(end, start)
    }

    public var duration: Double { end - start }
    public var midpoint: Double { (start + end) / 2 }

    public func overlap(with other: TimeRange) -> Double {
        max(0, min(end, other.end) - max(start, other.start))
    }

    public func contains(_ time: Double) -> Bool { time >= start && time < end }

    public func expanded(by amount: Double) -> TimeRange {
        TimeRange(start: start - amount, end: end + amount)
    }

    public func clamped(to bounds: TimeRange) -> TimeRange {
        TimeRange(start: min(max(start, bounds.start), bounds.end), end: min(max(end, bounds.start), bounds.end))
    }

    /// "m:ss–m:ss" (h:mm:ss past an hour).
    public var description: String { "\(Self.clock(start))–\(Self.clock(end))" }

    public static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        let mm = minutes < 10 ? "0\(minutes)" : "\(minutes)"
        let ss = secs < 10 ? "0\(secs)" : "\(secs)"
        return hours > 0 ? "\(hours):\(mm):\(ss)" : "\(minutes):\(ss)"
    }
}

/// Set operations on lists of time ranges.
public enum TimeRanges {
    /// Sorted, non-overlapping union. Ranges closer than `joiningGap` are merged.
    public static func union(_ ranges: [TimeRange], joiningGap: Double = 0) -> [TimeRange] {
        let sorted = ranges.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        var merged: [TimeRange] = []
        for range in sorted {
            if let last = merged.last, range.start <= last.end + joiningGap {
                merged[merged.count - 1].end = max(last.end, range.end)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Parts of `ranges` not covered by `removing`.
    public static func subtract(_ removing: [TimeRange], from ranges: [TimeRange]) -> [TimeRange] {
        let cuts = union(removing)
        var result: [TimeRange] = []
        for range in union(ranges) {
            var cursor = range.start
            for cut in cuts where cut.end > cursor && cut.start < range.end {
                if cut.start > cursor {
                    result.append(TimeRange(start: cursor, end: cut.start))
                }
                cursor = max(cursor, cut.end)
                if cursor >= range.end { break }
            }
            if cursor < range.end {
                result.append(TimeRange(start: cursor, end: range.end))
            }
        }
        return result
    }

    /// Total seconds of `ranges` (assumed non-overlapping) inside `window`.
    public static func seconds(of ranges: [TimeRange], within window: TimeRange) -> Double {
        ranges.reduce(0) { $0 + $1.overlap(with: window) }
    }

    public static func totalDuration(_ ranges: [TimeRange]) -> Double {
        union(ranges).reduce(0) { $0 + $1.duration }
    }
}
