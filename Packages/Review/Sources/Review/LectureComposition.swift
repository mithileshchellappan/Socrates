import AVFoundation
import Foundation
import StudyCore

/// One audio file placed on a recording's clock.
public struct PlaybackSource: Sendable, Hashable {
    public var url: URL
    /// Seconds on the recording clock where the file's first sample plays.
    public var start: Double

    public init(url: URL, start: Double) {
        self.url = url
        self.start = start
    }

    /// The recording's segment files that are in the BlobStore, each at `startSample / sampleRate`.
    /// Segments still being written (no blob yet) are left out.
    public static func sources(segments: [RecordingSegment], sampleRate: Double, blobs: BlobStore) -> [PlaybackSource] {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        return segments
            .sorted { $0.sequence < $1.sequence }
            .compactMap { segment in
                guard let blob = segment.blob else { return nil }
                return PlaybackSource(url: blobs.url(for: blob), start: Double(segment.startSample) / rate)
            }
    }
}

public enum LectureCompositionError: Error, Equatable, Sendable {
    case noAudioTrack
}

/// Builds the one clock a recording plays on: an `AVMutableComposition` with a single audio track
/// holding each segment file at its start time. Gaps between files (an input switch, an
/// interruption) stay empty and play as silence, so every second of the composition is the same
/// second of the recording clock that stamps, spans and transcript use. The composition ends with
/// the last file (AVFoundation drops trailing empty time); there is nothing to hear after it.
public enum LectureComposition {
    /// Timescale for placing files: one tick per sample at the recording rates in use.
    static let timescale: CMTimeScale = 48_000

    public static func make(_ sources: [PlaybackSource]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw LectureCompositionError.noAudioTrack
        }
        var end = CMTime.zero
        for source in sources.sorted(by: { $0.start < $1.start }) {
            let asset = AVURLAsset(url: source.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let fileTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                ReviewLog.logger.error("No audio track in \(source.url.lastPathComponent, privacy: .public)")
                continue
            }
            var range = try await fileTrack.load(.timeRange)
            var start = CMTime(seconds: max(0, source.start), preferredTimescale: timescale)
            if start < end {
                // Overlapping files (should not happen): keep the clock, drop the overlap.
                let overlap = end - start
                guard overlap < range.duration else { continue }
                range = CMTimeRange(start: range.start + overlap, duration: range.duration - overlap)
                start = end
            }
            if start > end {
                track.insertEmptyTimeRange(CMTimeRange(start: end, end: start))
            }
            try track.insertTimeRange(range, of: fileTrack, at: start)
            end = start + range.duration
        }
        return composition
    }
}
