import Accelerate
import Foundation

/// Energy-based voice activity detection with an adaptive noise floor.
///
/// Lecture recordings (phone at the back of the room, laptop mic) have a steady but
/// recording-dependent noise floor, so the threshold is relative: a frame is speech when its level
/// rises `enterThreshold` dB above the local floor (a low percentile of the surrounding
/// `floorWindow` seconds) and stays speech until it drops below `exitThreshold` dB above it.
///
/// Used to plan chunks, skip silent ones and find speech the decoder dropped. It is deliberately
/// generous: a false positive only costs a re-decode that yields nothing.
public struct SpeechActivityDetector: Hashable, Sendable {
    public var sampleRate: Double
    /// Analysis frame length in seconds.
    public var frameDuration: Double
    /// Percentile (0…1) of frame levels taken as the noise floor.
    public var floorPercentile: Double
    /// Seconds of context used to estimate the local floor.
    public var floorWindow: Double
    /// dB above the floor that starts speech.
    public var enterThreshold: Float
    /// dB above the floor below which speech ends.
    public var exitThreshold: Float
    /// Frames quieter than this (dBFS) are never speech.
    public var absoluteFloor: Float
    /// Pauses shorter than this (seconds) do not split speech.
    public var mergeGap: Double
    /// Speech shorter than this (seconds) is dropped as a click or cough.
    public var minimumSpeech: Double
    /// Seconds added before and after each region.
    public var padding: Double

    public init(
        sampleRate: Double = 16_000,
        frameDuration: Double = 0.02,
        floorPercentile: Double = 0.15,
        floorWindow: Double = 30,
        enterThreshold: Float = 9,
        exitThreshold: Float = 5,
        absoluteFloor: Float = -65,
        mergeGap: Double = 0.3,
        minimumSpeech: Double = 0.2,
        padding: Double = 0.1
    ) {
        self.sampleRate = sampleRate
        self.frameDuration = frameDuration
        self.floorPercentile = floorPercentile
        self.floorWindow = floorWindow
        self.enterThreshold = enterThreshold
        self.exitThreshold = exitThreshold
        self.absoluteFloor = absoluteFloor
        self.mergeGap = mergeGap
        self.minimumSpeech = minimumSpeech
        self.padding = padding
    }

    /// Level of digital silence (exact zeros, e.g. between recording parts or in a pause).
    static let silenceLevel: Float = -120
    /// dB the local floor may sit above the whole recording's floor.
    static let maximumFloorRise: Float = 10

    var frameLength: Int { max(Int((frameDuration * sampleRate).rounded()), 1) }

    /// RMS level of each frame in dBFS.
    public func frameLevels(_ samples: [Float]) -> [Float] {
        let length = frameLength
        let count = (samples.count + length - 1) / length
        guard count > 0 else { return [] }
        var levels = [Float](repeating: Self.silenceLevel, count: count)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for frame in 0..<count {
                let start = frame * length
                let n = min(length, samples.count - start)
                var rms: Float = 0
                vDSP_rmsqv(base + start, 1, &rms, vDSP_Length(n))
                levels[frame] = rms > 0 ? max(20 * log10(rms), Self.silenceLevel) : Self.silenceLevel
            }
        }
        return levels
    }

    /// RMS level of each frame of a timeline in dBFS: the values its zero-padded array gives. A
    /// frame wholly inside a gap is digital silence and is never read; every other frame is
    /// copied into one scratch frame (zeros where it reaches into a gap) and measured there, at the
    /// alignment a dense array's frame has.
    public func frameLevels(_ timeline: SampleTimeline) -> [Float] {
        let length = frameLength
        let total = timeline.count
        let count = (total + length - 1) / length
        guard count > 0 else { return [] }
        var levels = [Float](repeating: Self.silenceLevel, count: count)
        var scratch = [Float](repeating: 0, count: length)
        scratch.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for frame in 0..<count {
                let start = frame * length
                let range = start..<min(start + length, total)
                guard timeline.intersects(range) else { continue }
                timeline.copy(range, into: buffer)
                var rms: Float = 0
                vDSP_rmsqv(base, 1, &rms, vDSP_Length(range.count))
                levels[frame] = rms > 0 ? max(20 * log10(rms), Self.silenceLevel) : Self.silenceLevel
            }
        }
        return levels
    }

    /// Speech regions in seconds, sorted and non-overlapping.
    public func speechRegions(in samples: [Float]) -> [TimeRange] {
        let total = Double(samples.count) / sampleRate
        return speechRegions(levels: frameLevels(samples), duration: total)
    }

    /// Speech regions of a timeline in seconds from its sample 0 (gaps are silence).
    public func speechRegions(in timeline: SampleTimeline) -> [TimeRange] {
        let total = Double(timeline.count) / sampleRate
        return speechRegions(levels: frameLevels(timeline), duration: total)
    }

    /// Speech regions from precomputed frame levels.
    public func speechRegions(levels: [Float], duration: Double) -> [TimeRange] {
        guard !levels.isEmpty else { return [] }
        let floors = localFloors(levels)
        var regions: [TimeRange] = []
        var speechStart: Int?
        for (index, level) in levels.enumerated() {
            let floor = floors[index]
            let gate = max(floor, absoluteFloor - enterThreshold)
            if let start = speechStart {
                if level < gate + exitThreshold || level < absoluteFloor {
                    regions.append(range(frames: start..<index))
                    speechStart = nil
                }
            } else if level >= gate + enterThreshold, level >= absoluteFloor {
                speechStart = index
            }
        }
        if let start = speechStart {
            regions.append(range(frames: start..<levels.count))
        }
        let merged = TimeRanges.union(regions, joiningGap: mergeGap)
            .filter { $0.duration >= minimumSpeech }
            .map { TimeRange(start: max($0.start - padding, 0), end: min($0.end + padding, duration)) }
        return TimeRanges.union(merged)
    }

    private func range(frames: Range<Int>) -> TimeRange {
        TimeRange(start: Double(frames.lowerBound) * frameDuration, end: Double(frames.upperBound) * frameDuration)
    }

    /// Noise floor per frame: the `floorPercentile` of non-silent levels in a window around it,
    /// evaluated every ~5 s and held in between.
    func localFloors(_ levels: [Float]) -> [Float] {
        let blockFrames = max(Int(5 / frameDuration), 1)
        let halfWindow = max(Int(floorWindow / frameDuration / 2), blockFrames)
        let audible = levels.filter { $0 > Self.silenceLevel + 1 }
        let globalFloor = percentile(audible) ?? Self.silenceLevel
        var floors = [Float](repeating: globalFloor, count: levels.count)
        var blockStart = 0
        while blockStart < levels.count {
            let blockEnd = min(blockStart + blockFrames, levels.count)
            let center = (blockStart + blockEnd) / 2
            let window = levels[max(center - halfWindow, 0)..<min(center + halfWindow, levels.count)]
            // Continuous speech with reverb can lift a local percentile to speech level; never
            // let the local floor rise more than `maximumFloorRise` above the recording's floor.
            let local = min(
                percentile(window.filter { $0 > Self.silenceLevel + 1 }) ?? globalFloor,
                globalFloor + Self.maximumFloorRise
            )
            for index in blockStart..<blockEnd { floors[index] = local }
            blockStart = blockEnd
        }
        return floors
    }

    private func percentile(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(max(Int(Double(sorted.count - 1) * floorPercentile), 0), sorted.count - 1)
        return sorted[index]
    }
}
