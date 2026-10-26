import Foundation

/// A recording's 16 kHz mono samples on its clock, kept as runs of continuous audio
/// (`AudioTimeline.runs`): a pause or an interruption between two runs is never stored. Every
/// read gives zeros where no run lies, exactly what a zero-padded array gave, so the speech
/// detection, the chunk plan and the decoded windows (and with them the transcript and its times)
/// are the same as before, sample for sample.
struct SampleTimeline: Sendable {
    /// Continuous samples from `start` (a sample index on the recording clock).
    struct Run: Sendable {
        var start: Int
        var samples: [Float]

        init(start: Int, samples: [Float]) {
            self.start = start
            self.samples = samples
        }

        var end: Int { start + samples.count }
    }

    /// Sorted by `start`, never overlapping, none empty.
    let runs: [Run]
    /// The end of the clock: one past the last sample (a zero-padded array's length).
    let count: Int

    /// Dense samples from sample 0 (one run).
    init(_ samples: [Float]) {
        runs = samples.isEmpty ? [] : [Run(start: 0, samples: samples)]
        count = samples.count
    }

    /// Runs as `AudioTimeline.runs` builds them; `count` is at least the last run's end.
    init(runs: [Run], count: Int) {
        let kept = runs.filter { !$0.samples.isEmpty }
        self.runs = kept
        self.count = max(count, kept.last?.end ?? 0)
    }

    var isEmpty: Bool { count == 0 }

    /// The samples of `range` as one array (zeros where no run lies).
    func samples(in range: Range<Int>) -> [Float] {
        var buffer = [Float](repeating: 0, count: range.count)
        buffer.withUnsafeMutableBufferPointer { copy(range, into: $0) }
        return buffer
    }

    /// Writes the samples of `range` to the start of `buffer` (at least `range.count` long): zeros
    /// where no run lies.
    func copy(_ range: Range<Int>, into buffer: UnsafeMutableBufferPointer<Float>) {
        guard !range.isEmpty, let base = buffer.baseAddress else { return }
        base.update(repeating: 0, count: range.count)
        var index = firstRun(endingAfter: range.lowerBound)
        while index < runs.count, runs[index].start < range.upperBound {
            let run = runs[index]
            let lower = max(range.lowerBound, run.start)
            let upper = min(range.upperBound, run.end)
            if upper > lower {
                run.samples.withUnsafeBufferPointer { source in
                    guard let from = source.baseAddress else { return }
                    (base + (lower - range.lowerBound)).update(from: from + (lower - run.start), count: upper - lower)
                }
            }
            index += 1
        }
    }

    /// Whether any run holds a sample of `range` (false: the range lies wholly in a gap or past
    /// the last run).
    func intersects(_ range: Range<Int>) -> Bool {
        let index = firstRun(endingAfter: range.lowerBound)
        return index < runs.count && runs[index].start < range.upperBound
    }

    /// All samples from 0 as one array, gaps as zeros (the bench's single files: their one run as
    /// it is).
    var contiguous: [Float] {
        if runs.count == 1, let run = runs.first, run.start == 0, run.samples.count == count { return run.samples }
        return samples(in: 0..<count)
    }

    /// The first run whose end lies after `sample` (binary search; `runs.count` when none).
    private func firstRun(endingAfter sample: Int) -> Int {
        var low = 0
        var high = runs.count
        while low < high {
            let middle = (low + high) / 2
            if runs[middle].end <= sample { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
