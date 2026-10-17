import AVFAudio
import Capture
import Foundation

/// A slide change at `time` seconds into a recording.
public struct CaptureStamp: Sendable, Hashable {
    public var time: Double
    public var page: Int

    public init(time: Double, page: Int) {
        self.time = time
        self.page = page
    }
}

/// Writes a lecture package from an existing audio file and a list of slide stamps, exactly as
/// live capture would have: the same segment writer (48 kHz mono 16-bit CAF, 5-minute
/// segments), manifest and event log. Used to replay recordings with known slide timings through
/// the capture import path (end-to-end checks, tests); also the basis for importing a stamped
/// recording from another device.
public enum LecturePackageBuilder {
    @concurrent
    public static func build(
        audio url: URL,
        in directory: URL,
        stamps: [CaptureStamp],
        startPage: Int?,
        courseID: UUID? = nil,
        lectureID: UUID? = nil,
        deck: DeckReference? = nil,
        startedAt: Date = Date(),
        format: RecordingFormat = .standard,
        segmentDuration: Duration = .seconds(300)
    ) async throws -> LecturePackage {
        let package = try LecturePackage.create(in: directory)
        guard let id = package.id else { throw CocoaError(.fileWriteInvalidFileName) }
        let writer = try LecturePackageWriter(package: package, manifest: LectureManifest(
            id: id, courseID: courseID, lectureID: lectureID, deck: deck,
            startedAt: startedAt, hostTimeAtStart: 0, format: format, platform: "macOS"
        ))

        let source = try AVAudioFile(forReading: url)
        let audio = try SegmentedAudioWriter(
            directory: package.audioDirectory,
            format: format,
            segmentFrames: format.frames(in: segmentDuration)
        )
        let chunkFrames = AVAudioFrameCount(max(1, source.processingFormat.sampleRate / 10))
        // Reading at the end of the file throws instead of returning no frames.
        while source.framePosition < source.length {
            let frames = AVAudioFrameCount(min(Int64(chunkFrames), source.length - source.framePosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: frames) else { break }
            try source.read(into: buffer, frameCount: frames)
            guard let chunk = AudioChunk(buffer: buffer, time: nil, run: 1) else { break }
            try audio.append(chunk)
        }
        let segments = try audio.finish()
        let endSample = segments.compactMap(\.endSample).max() ?? 0

        let rate = format.sampleRate
        func event(_ kind: LectureEventKind, at time: Double, page: Int?, from: Int?) -> LectureEvent {
            LectureEvent(
                kind: kind, page: page, fromPage: from,
                sampleTime: min(Int64((time * rate).rounded()), endSample),
                hostTime: UInt64(max(0, time) * 1e9),
                wallClock: startedAt.addingTimeInterval(time)
            )
        }
        var events = [event(.start, at: 0, page: startPage, from: nil)]
        var page = startPage
        for stamp in stamps.sorted(by: { $0.time < $1.time }) {
            let kind: LectureEventKind = page.map { stamp.page == $0 + 1 ? .slide : stamp.page == $0 - 1 ? .back : .jump } ?? .jump
            events.append(event(kind, at: stamp.time, page: stamp.page, from: page))
            page = stamp.page
        }
        let duration = Double(endSample) / rate
        events.append(event(.stop, at: duration, page: page, from: nil))

        try await writer.writeEvents(events, revision: 1)
        try await writer.updateManifest { manifest in
            manifest.segments = segments
            manifest.endedAt = startedAt.addingTimeInterval(duration)
        }
        return package
    }
}
