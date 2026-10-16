import AVFAudio
import Foundation

public enum AudioWriterError: Error, Equatable, Sendable {
    case unsupportedFormat
    case conversionUnavailable(sourceSampleRate: Double)
}

/// Writes mono audio into consecutive files of at most `segmentFrames` frames each
/// (`seg-0001.caf`, `seg-0002.caf`, …), placing every file on the recording clock.
///
/// - A full segment is closed and the next one starts at exactly the following frame.
/// - A chunk from a new engine run (input reconfigured) closes the open segment; the next one
///   starts where real time had got to according to `clock`, never before the previous end.
/// - Input at another sample rate is converted to `format.sampleRate`.
/// - After each chunk the clock is anchored to "this chunk's first frame was captured at its
///   host time", so stamps map onto the audio actually written.
///
/// Not thread-safe; owned by one actor or task. No microphone involved, so it is unit-tested
/// with synthetic buffers.
public final class SegmentedAudioWriter {
    public let directory: URL
    public let format: RecordingFormat
    public let segmentFrames: Int64
    public let clock: RecordingClock?
    /// Recorded on segments opened from now on.
    public var deviceName: String?
    /// All segments so far; the last one has `frameCount == nil` while open.
    public private(set) var segments: [AudioSegmentInfo] = []

    private let processingFormat: AVAudioFormat
    private let firstSequence: Int
    private var file: AVAudioFile?
    private var framesInSegment: Int64 = 0
    private var currentRun: Int?
    private var converter: PCMConverter?
    private var nextReason: AudioSegmentInfo.StartReason = .start

    public init(
        directory: URL,
        format: RecordingFormat = .standard,
        segmentFrames: Int64,
        clock: RecordingClock? = nil,
        firstSequence: Int = 1
    ) throws {
        guard let processingFormat = format.processingFormat, segmentFrames > 0 else {
            throw AudioWriterError.unsupportedFormat
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.format = format
        self.segmentFrames = segmentFrames
        self.clock = clock
        self.processingFormat = processingFormat
        self.firstSequence = firstSequence
    }

    /// True while a segment file is open.
    public var isSegmentOpen: Bool { file != nil }

    /// First frame after everything written so far.
    public var endSample: Int64 {
        guard let last = segments.last else { return 0 }
        return last.startSample + (last.frameCount ?? framesInSegment)
    }

    /// Writes `chunk`. Returns true when a segment was opened or closed (persist the manifest).
    @discardableResult
    public func append(_ chunk: AudioChunk) throws -> Bool {
        var changed = false
        if currentRun != chunk.run {
            if currentRun != nil {
                changed = try flushAndClose(drainConverter: false) || changed
                nextReason = .discontinuity
            }
            currentRun = chunk.run
            converter = nil
        }
        let samples = try convert(chunk)
        changed = try write(samples, hostTime: chunk.hostTime) || changed
        return changed
    }

    /// Closes the open segment (draining any conversion tail). Returns all segments.
    @discardableResult
    public func finish() throws -> [AudioSegmentInfo] {
        try flushAndClose(drainConverter: true)
        return segments
    }

    // MARK: - Private

    private func convert(_ chunk: AudioChunk) throws -> [Float] {
        guard chunk.sampleRate != format.sampleRate else { return chunk.samples }
        if converter?.sourceSampleRate != chunk.sampleRate {
            guard let fresh = PCMConverter(sourceSampleRate: chunk.sampleRate, targetFormat: processingFormat) else {
                throw AudioWriterError.conversionUnavailable(sourceSampleRate: chunk.sampleRate)
            }
            converter = fresh
        }
        return converter?.convertToSamples(chunk.samples) ?? []
    }

    /// Writes samples, rolling over at segment boundaries. Returns true if segments changed.
    private func write(_ samples: [Float], hostTime: UInt64?) throws -> Bool {
        guard !samples.isEmpty else { return false }
        var changed = false
        var offset = 0
        var chunkStartSample: Int64?
        while offset < samples.count {
            if file == nil {
                try openSegment(hostTime: hostTime)
                changed = true
            }
            if chunkStartSample == nil { chunkStartSample = endSample }
            let room = Int(segmentFrames - framesInSegment)
            let count = min(room, samples.count - offset)
            try writeToFile(samples[offset..<(offset + count)])
            framesInSegment += Int64(count)
            offset += count
            if framesInSegment >= segmentFrames {
                try closeSegment()
                nextReason = .rollover
                changed = true
            }
        }
        if let chunkStartSample, let hostTime {
            clock?.setAnchor(.init(sampleTime: chunkStartSample, hostTime: hostTime))
        }
        return changed
    }

    private func openSegment(hostTime: UInt64?) throws {
        let previousEnd = endSample
        let startSample: Int64
        switch nextReason {
        case .start, .rollover:
            startSample = previousEnd
        case .discontinuity:
            let byClock = hostTime.flatMap { clock?.sampleTime(atHostTime: $0) } ?? previousEnd
            startSample = max(previousEnd, byClock)
        }
        let sequence = (segments.last?.sequence ?? (firstSequence - 1)) + 1
        let name = LecturePackage.segmentFileName(sequence: sequence, fileExtension: format.fileExtension)
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        file = try AVAudioFile(
            forWriting: url, settings: format.fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        framesInSegment = 0
        segments.append(AudioSegmentInfo(
            sequence: sequence,
            file: "\(LecturePackage.audioFolder)/\(name)",
            startSample: startSample,
            hostTime: hostTime,
            startReason: segments.isEmpty ? .start : nextReason,
            device: deviceName
        ))
        CaptureLog.capture.info(
            "Opened \(name, privacy: .public) at sample \(startSample) (\(self.nextReason.rawValue, privacy: .public))"
        )
    }

    private func writeToFile(_ samples: ArraySlice<Float>) throws {
        guard let file,
              let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = buffer.floatChannelData?[0]
        else { throw AudioWriterError.unsupportedFormat }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { destination.update(from: base, count: source.count) }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    @discardableResult
    private func flushAndClose(drainConverter: Bool) throws -> Bool {
        if drainConverter, let converter, file != nil {
            let tail = converter.convertToSamples([], endOfStream: true)
            _ = try write(tail, hostTime: nil)
        }
        return try closeSegment()
    }

    @discardableResult
    private func closeSegment() throws -> Bool {
        guard let file else { return false }
        file.close()
        self.file = nil
        if let index = segments.indices.last {
            segments[index].frameCount = framesInSegment
            CaptureLog.capture.info(
                "Closed \(self.segments[index].file, privacy: .public) with \(self.framesInSegment) frames"
            )
        }
        framesInSegment = 0
        return true
    }
}
