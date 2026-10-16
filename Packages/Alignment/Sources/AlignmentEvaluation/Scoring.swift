import Alignment

/// Accuracy of a slide timeline against ``GroundTruth``.
public struct Score: Hashable, Sendable {
    /// 30 s windows whose midpoint lies in a known truth segment.
    public var windows: Int
    /// …of which the predicted target at the midpoint is allowed (OFF counts as a target).
    public var correctWindows: Int
    /// Seconds (1 s grid) in known truth segments and how many were correct.
    public var seconds: Int
    public var correctSeconds: Int
    /// Per verified boundary: |predicted − true| in seconds, nil when the target was never entered within 3 minutes.
    public var boundaryErrors: [Double?]

    public var windowAccuracy: Double { windows == 0 ? 0 : Double(correctWindows) / Double(windows) }
    public var timeAccuracy: Double { seconds == 0 ? 0 : Double(correctSeconds) / Double(seconds) }

    public var matchedBoundaryErrors: [Double] { boundaryErrors.compactMap { $0 } }

    public var medianBoundaryError: Double? {
        let sorted = matchedBoundaryErrors.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            : sorted[sorted.count / 2]
    }

    public func boundaries(within seconds: Double) -> Int {
        matchedBoundaryErrors.filter { $0 <= seconds }.count
    }
}

public enum Scorer {
    public static let windowDuration = 30.0
    public static let boundarySearchRadius = 180.0

    /// Scores a timeline given as spans (sorted, contiguous; times past the last span take its target).
    public static func score(spans: [AlignedSpan], truth: GroundTruth) -> Score {
        let target: (Double) -> AlignmentTarget = { time in
            guard let last = spans.last else { return .off }
            if time >= last.start { return last.target }
            return spans.first { $0.start <= time && time < $0.end }?.target ?? .off
        }

        var windows = 0
        var correctWindows = 0
        var start = 0.0
        while start < truth.end {
            let middle = start + windowDuration / 2
            if middle < truth.end, let allowed = truth.allowed(at: middle) {
                windows += 1
                if allowed.contains(target(middle)) { correctWindows += 1 }
            }
            start += windowDuration
        }

        var seconds = 0
        var correctSeconds = 0
        var second = 0.5
        while second < truth.end {
            if let allowed = truth.allowed(at: second) {
                seconds += 1
                if allowed.contains(target(second)) { correctSeconds += 1 }
            }
            second += 1
        }

        let errors: [Double?] = truth.boundaries.map { boundary in
            var best: Double?
            for (index, span) in spans.enumerated() where boundary.targets.contains(span.target) {
                if index > 0, boundary.targets.contains(spans[index - 1].target) { continue }
                let error = abs(span.start - boundary.time)
                if error <= boundarySearchRadius, error < (best ?? .infinity) { best = error }
            }
            return best
        }

        return Score(
            windows: windows,
            correctWindows: correctWindows,
            seconds: seconds,
            correctSeconds: correctSeconds,
            boundaryErrors: errors
        )
    }
}
