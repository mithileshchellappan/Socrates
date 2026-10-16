import Foundation
import StudyCore

extension TranscribedSegment {
    /// A `transcript_segment` row for this segment.
    ///
    /// `timeOffset` is added to every time, for transcripts made from audio that does not start
    /// at the recording's sample 0.
    public func record(
        recordingID: Recording.ID,
        lectureID: Lecture.ID?,
        timeOffset: Double = 0
    ) -> TranscriptSegment {
        TranscriptSegment(
            recordingID: recordingID,
            lectureID: lectureID,
            startTime: start + timeOffset,
            endTime: end + timeOffset,
            text: text,
            lang: language,
            confidence: confidence,
            words: words.isEmpty ? nil : words.map {
                TranscriptWord(text: $0.text, start: $0.start + timeOffset, end: $0.end + timeOffset, confidence: $0.probability)
            }
        )
    }
}

extension Transcript {
    /// `transcript_segment` rows in time order, ready for `TranscriptRepository.replaceSegments`.
    public func records(recordingID: Recording.ID, lectureID: Lecture.ID?, timeOffset: Double = 0) -> [TranscriptSegment] {
        segments
            .sorted { $0.start < $1.start }
            .map { $0.record(recordingID: recordingID, lectureID: lectureID, timeOffset: timeOffset) }
    }
}

extension TranscriptionAudio {
    /// Audio for a recording's segment files. `files` maps each segment to its local file URL
    /// (from `BlobStore.url(for:)`); segments without a file are skipped.
    public init(recording: Recording, segments: [RecordingSegment], files: (RecordingSegment) -> URL?) {
        let rate = recording.sampleRate > 0 ? recording.sampleRate : 48_000
        self.init(parts: segments
            .sorted { $0.sequence < $1.sequence }
            .compactMap { segment in
                files(segment).map { Part(url: $0, startTime: Double(segment.startSample) / rate) }
            })
    }
}
